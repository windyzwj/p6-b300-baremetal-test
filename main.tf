###############################################################################
# p6-b300.48xlarge 裸机验证 Terraform（Launch Template 模式）
#
# 用途：在 EKS 集群创建之前，先开一台 GPU 裸机做硬件验证：
#   - GPU 是否正常（nvidia-smi 列出 8 张 B300）
#   - EFA-only 网卡（B300=16 张, p5=32 张）是否全部识别
#   - NCCL+EFA 通信是否正常
#   - 驱动 / CUDA / EFA Installer / libfabric 版本是否匹配 B300
#
# 关键设计（参考 AWS terraform-aws-eks-blueprints / eks-efa-examples）：
#   1. 用 aws_launch_template 的 network_interfaces 块声明所有网卡
#      AWS 在 RunInstances 时同步创建 ENI，绕过 source_dest_check 等单独管理 ENI 的坑
#      实例销毁时 ENI 自动清理，无需 lifecycle 管理
#   2. EFA Security Group 必须 self-referencing
#   3. 必须用 placement_group / capacity_block / ODCR 锁定容量
#   4. aws-ofi-nccl 不在 host 装，由训练/推理容器镜像自带
###############################################################################

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.50"
    }
  }
}

provider "aws" {
  region = var.region
}

###############################################################################
# Variables
###############################################################################

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "vpc_id" {
  description = "目标 VPC ID"
  type        = string
}

variable "subnet_id" {
  description = "私有子网 ID（capacity_block / odcr 模式必须在锁定的 AZ）"
  type        = string
}

variable "key_name" {
  description = "EC2 Key Pair 名称（堡垒机能用同一把 key 跳进来）"
  type        = string
}

variable "bastion_sg_id" {
  description = "堡垒机 SG ID，用于在 EFA SG 上放行 22 端口入向"
  type        = string
}

variable "capacity_reservation_id" {
  description = <<-EOT
    Capacity Reservation ID（cr-xxxxxxxxx）
    odcr 和 capacity_block 模式都用同一个字段。spot / on_demand 留空字符串
  EOT
  type        = string
  default     = ""
}

variable "placement_group_name" {
  description = <<-EOT
    Placement Group 名称。CB/ODCR 购买时已绑定 PG，这里填对应的 PG name。
    留空则不指定（AWS 会自动关联 CR 绑定的 PG）。
  EOT
  type        = string
  default     = ""
}

variable "ami_choice" {
  description = "AMI 选择：dlami / eks / custom（自定义 AMI ID）"
  type        = string
  default     = "dlami"
  validation {
    condition     = contains(["dlami", "eks", "custom"], var.ami_choice)
    error_message = "ami_choice 必须是 dlami、eks 或 custom"
  }
}

variable "custom_ami_id" {
  description = "自定义 AMI ID（仅 ami_choice = custom 时生效）"
  type        = string
  default     = ""
}

variable "root_volume_size" {
  description = "根盘大小（GB）"
  type        = number
  default     = 300
}

variable "purchase_mode" {
  description = "购买模式：spot / on_demand / odcr / capacity_block"
  type        = string
  default     = "spot"
  validation {
    condition     = contains(["spot", "on_demand", "odcr", "capacity_block"], var.purchase_mode)
    error_message = "purchase_mode 必须是 spot / on_demand / odcr / capacity_block"
  }
}

variable "instance_type" {
  description = "实例类型，例如 g5.8xlarge / p5.48xlarge / p6-b300.48xlarge"
  type        = string
  default     = "g5.8xlarge"
}

variable "spot_max_price" {
  description = "Spot 出价上限（美元/小时），留空 = 按市价"
  type        = string
  default     = ""
}

variable "efa_card_count_override" {
  description = "手动指定 EFA-only 网卡数。-1 = 按 instance_type 自动判断"
  type        = number
  default     = -1
}

variable "install_efa_userspace" {
  description = <<-EOT
    是否在 user-data 里安装 EFA userspace（libfabric-aws + openmpi5-aws）。
    EKS NVIDIA AMI 默认只装了 EFA 内核模块（efa.ko），没有用户态工具。
    要跑 NCCL 多机或诊断 EFA，必须装 userspace。
    注意：aws-ofi-nccl 不在 host 装，由训练容器镜像自带。
    纯私网（无 NAT）客户应设 false，改用预装 AMI。
  EOT
  type        = bool
  default     = true
}

variable "efa_installer_version" {
  description = <<-EOT
    EFA Installer 版本，例如 "1.48.0"。
    留空 = "latest"（每次启动拉最新，不可重现但跟版本）
    锁定具体版本 = 可重现的 reboot 行为。
    B300 至少需要 1.47+。
  EOT
  type        = string
  default     = "1.48.0"
}

variable "existing_sg_id" {
  description = "已有的 EFA Security Group ID。留空则新建。同 VPC 多台机器复用同一个 SG 时填这个。"
  type        = string
  default     = ""
}

variable "existing_instance_profile_name" {
  description = "已有的 IAM Instance Profile 名。留空则新建。同账号多台机器复用同一个 Role 时填这个。"
  type        = string
  default     = ""
}

variable "name_prefix" {
  description = "资源名前缀"
  type        = string
  default     = "p6-b300-test"
}

variable "ssh_ingress_cidrs" {
  description = <<-EOT
    额外放行 SSH 22 端口入向的公网 IP 段（在堡垒机 SG 之外）。
    例如 ["1.2.3.4/32"]（只放行你自己的公网 IP）。
    手动给实例挂 EIP 时配合使用；留空 [] 则只接受堡垒机 SG 的 22 入向。
  EOT
  type        = list(string)
  default     = []
}

variable "allocate_eip" {
  description = <<-EOT
    是否自动创建并关联 EIP 到 primary ENI。
    公有子网 + 多网卡场景需要开启（多网卡不支持 auto-assign public IP）。
    私有子网（有 NAT）不需要。
  EOT
  type        = bool
  default     = false
}

variable "eks_version" {
  description = "EKS 版本号，用于查询 EKS optimized NVIDIA AMI"
  type        = string
  default     = "1.35"
}

###############################################################################
# AMI 选择
###############################################################################

data "aws_ami" "dlami" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["Deep Learning Base OSS Nvidia Driver GPU AMI (Amazon Linux 2023)*"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

data "aws_ssm_parameter" "eks_nvidia_ami" {
  name = "/aws/service/eks/optimized-ami/${var.eks_version}/amazon-linux-2023/x86_64/nvidia/recommended/image_id"
}

###############################################################################
# 校验
###############################################################################

check "reservation_id_required" {
  assert {
    condition = !(
      contains(["odcr", "capacity_block"], var.purchase_mode) &&
      var.capacity_reservation_id == ""
    )
    error_message = "purchase_mode = \"odcr\" 或 \"capacity_block\" 时必须填 capacity_reservation_id"
  }
}


###############################################################################
# Locals
###############################################################################

locals {
  ami_id = (
    var.ami_choice == "custom" ? var.custom_ami_id :
    var.ami_choice == "dlami" ? data.aws_ami.dlami.id :
    nonsensitive(data.aws_ssm_parameter.eks_nvidia_ami.value)
  )

  # EFA-only 网卡数
  efa_card_count_auto = (
    contains(["p6-b300.48xlarge", "p6-b200.48xlarge"], var.instance_type) ? 16 :
    contains(["p5.48xlarge", "p5en.48xlarge"], var.instance_type) ? 32 :
    0
  )
  efa_card_count = var.efa_card_count_override >= 0 ? var.efa_card_count_override : local.efa_card_count_auto

  # 网卡总数 = primary (1) + EFA-only
  total_nic_count = 1 + local.efa_card_count

  # 网卡布局：构造 [{network_card_index, interface_type}, ...]
  # network_card_index = 0     → primary ENA（普通 ENI 类型）
  # network_card_index = 1..N  → EFA-only
  network_interfaces_config = [
    for i in range(local.total_nic_count) : {
      network_card_index = i
      interface_type     = i == 0 ? null : "efa-only"
      device_index       = 0 # 每张网卡都只挂 1 个 ENI，device_index 永远是 0
    }
  ]
}

###############################################################################
# Security Group（条件创建：existing_sg_id 有值则复用，否则新建）
###############################################################################

resource "aws_security_group" "efa" {
  count       = var.existing_sg_id == "" ? 1 : 0
  name        = "${var.name_prefix}-efa-sg"
  description = "EFA-enabled SG for GPU bare metal test"
  vpc_id      = var.vpc_id

  ingress {
    description     = "SSH from bastion"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [var.bastion_sg_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name_prefix}-efa-sg"
  }
}

# 额外放行公网 IP 段 SSH（仅新建 SG 时）
resource "aws_security_group_rule" "ssh_from_public" {
  count             = var.existing_sg_id == "" && length(var.ssh_ingress_cidrs) > 0 ? 1 : 0
  type              = "ingress"
  from_port         = 22
  to_port           = 22
  protocol          = "tcp"
  cidr_blocks       = var.ssh_ingress_cidrs
  security_group_id = aws_security_group.efa[0].id
  description       = "Extra SSH ingress for manually-attached EIP"
}

# EFA self-referencing（仅新建 SG 时）
resource "aws_security_group_rule" "efa_self_ingress" {
  count             = var.existing_sg_id == "" ? 1 : 0
  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  self              = true
  security_group_id = aws_security_group.efa[0].id
  description       = "Required by EFA: allow all in-SG traffic"
}

locals {
  # 统一入口：复用已有 SG 或用新建的
  sg_id = var.existing_sg_id != "" ? var.existing_sg_id : aws_security_group.efa[0].id
}

###############################################################################
# IAM（条件创建：existing_instance_profile_name 有值则复用，否则新建）
###############################################################################

resource "aws_iam_role" "instance" {
  count = var.existing_instance_profile_name == "" ? 1 : 0
  name  = "${var.name_prefix}-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  count      = var.existing_instance_profile_name == "" ? 1 : 0
  role       = aws_iam_role.instance[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "instance" {
  count = var.existing_instance_profile_name == "" ? 1 : 0
  name  = "${var.name_prefix}-profile"
  role  = aws_iam_role.instance[0].name
}

locals {
  # 统一入口：复用已有 Instance Profile 或用新建的
  instance_profile_name = var.existing_instance_profile_name != "" ? var.existing_instance_profile_name : aws_iam_instance_profile.instance[0].name
}

###############################################################################
# Launch Template
#
# 核心：用 network_interfaces 块声明 N 张网卡，AWS 在 RunInstances 时同步创建 ENI。
# - primary (network_card_index=0)：普通 ENA（interface_type 不指定）
# - EFA-only (network_card_index=1..N)：interface_type = "efa-only"
###############################################################################

resource "aws_launch_template" "instance" {
  name_prefix   = "${var.name_prefix}-lt-"
  image_id      = local.ami_id
  instance_type = var.instance_type
  key_name      = var.key_name

  iam_instance_profile {
    name = local.instance_profile_name
  }

  # 17 个 / 33 个 / N 个网卡声明
  # 注意：AWS 多 NIC 实例不允许设 associate_public_ip_address
  # 公网 IP 通过 aws_eip + aws_eip_association 在实例创建后挂上去
  dynamic "network_interfaces" {
    for_each = local.network_interfaces_config
    content {
      device_index          = network_interfaces.value.device_index
      network_card_index    = network_interfaces.value.network_card_index
      interface_type        = network_interfaces.value.interface_type
      subnet_id             = var.subnet_id
      security_groups       = [local.sg_id]
      delete_on_termination = true
    }
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_type           = "gp3"
      volume_size           = var.root_volume_size
      iops                  = 3000
      throughput            = 250
      delete_on_termination = true
      encrypted             = true
    }
  }

  user_data = base64encode(var.ami_choice == "eks" ? local.user_data_eks : local.user_data_dlami)

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name    = "${var.name_prefix}-instance"
      Purpose = "GPU bare metal validation"
    }
  }

  tag_specifications {
    resource_type = "network-interface"
    tags = {
      Name = "${var.name_prefix}-eni"
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name = "${var.name_prefix}-volume"
    }
  }

  # spot：在 LT 里设置 instance_market_options
  dynamic "instance_market_options" {
    for_each = var.purchase_mode == "spot" ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        max_price                      = var.spot_max_price != "" ? var.spot_max_price : null
        spot_instance_type             = "one-time"
        instance_interruption_behavior = "terminate"
      }
    }
  }

  # odcr / capacity_block：targeted reservation
  dynamic "capacity_reservation_specification" {
    for_each = contains(["odcr", "capacity_block"], var.purchase_mode) ? [1] : []
    content {
      capacity_reservation_preference = "none"
      capacity_reservation_target {
        capacity_reservation_id = var.capacity_reservation_id
      }
    }
  }

  # Placement Group（CB/ODCR 购买时绑定的 PG）
  dynamic "placement" {
    for_each = var.placement_group_name != "" ? [1] : []
    content {
      group_name = var.placement_group_name
    }
  }

  # on_demand 模式不设置 capacity_reservation_specification，AWS 默认 preference=open

}

###############################################################################
# Instance（基于 Launch Template 启动）
###############################################################################

resource "aws_instance" "p6_b300" {
  launch_template {
    id      = aws_launch_template.instance.id
    version = "$Latest"
  }
}

###############################################################################
# EIP（公有子网 + 多网卡场景，需手动关联公网 IP）
###############################################################################

resource "aws_eip" "instance" {
  count  = var.allocate_eip ? 1 : 0
  domain = "vpc"
  tags = {
    Name = "${var.name_prefix}-eip"
  }
}

data "aws_network_interface" "primary" {
  count = var.allocate_eip ? 1 : 0
  filter {
    name   = "attachment.instance-id"
    values = [aws_instance.p6_b300.id]
  }
  filter {
    name   = "attachment.device-index"
    values = ["0"]
  }
  filter {
    name   = "interface-type"
    values = ["interface"]
  }
}

resource "aws_eip_association" "instance" {
  count                = var.allocate_eip ? 1 : 0
  allocation_id        = aws_eip.instance[0].id
  network_interface_id = data.aws_network_interface.primary[0].id
}


###############################################################################
# User Data
###############################################################################

locals {
  # ===========================================================================
  # 公共片段：装 EFA userspace（libfabric-aws + openmpi5-aws）
  #
  # 参考 aws-samples/sample-eks-enterprise-quickstart 的写法：
  #   - --skip-kmod：EKS NVIDIA AMI 已自带 efa 内核模块，重装会冲突
  #   - 幂等检查（fi_info 已存在则跳过）：避免 reboot 后重复装
  #   - 失败降级（|| WARN）：装不上不阻塞节点 boot，容器自带 libfabric 仍可用
  #   - aws-ofi-nccl 不在 host 装：由训练容器自带（跟 NCCL 版本强耦合）
  # ===========================================================================
  _efa_install_block = <<-EFA_INSTALL
    # ============================================================
    # EFA userspace (libfabric-aws + openmpi5-aws)
    # 参考: aws-samples/sample-eks-enterprise-quickstart
    # 注意: aws-ofi-nccl 不在 host 装，由训练容器镜像自带
    # ============================================================
    if [ ! -x /opt/amazon/efa/bin/fi_info ]; then
      EFA_VERSION="${var.efa_installer_version != "" ? var.efa_installer_version : "latest"}"
      EFA_TARBALL="aws-efa-installer-$${EFA_VERSION}.tar.gz"
      echo "=== Installing EFA userspace ($${EFA_TARBALL}) ==="
      ( cd /tmp && \
        curl -fsSLO "https://efa-installer.amazonaws.com/$${EFA_TARBALL}" && \
        tar -xf "$${EFA_TARBALL}" && \
        cd aws-efa-installer && \
        ./efa_installer.sh -y --skip-kmod 2>&1 | tail -30 ) || \
        echo "WARN: efa_installer failed; containers with their own libfabric will still work"

      if [ -x /opt/amazon/efa/bin/fi_info ]; then
        echo "EFA userspace installed at /opt/amazon/efa/"
        /opt/amazon/efa/bin/fi_info --version 2>&1 | head -1 || true
        echo "EFA providers detected: $(/opt/amazon/efa/bin/fi_info -p efa 2>/dev/null | grep -c '^provider:')"
      fi
    else
      echo "EFA userspace already installed: $(/opt/amazon/efa/bin/fi_info --version 2>&1 | head -1)"
    fi
  EFA_INSTALL

  efa_installer_snippet = var.install_efa_userspace ? local._efa_install_block : "echo 'EFA userspace install skipped (install_efa_userspace=false)'"

  # ===========================================================================
  # 公共片段：验证脚本（落到 /root/validate-b300.sh）
  # ===========================================================================
  validate_snippet = <<-VALIDATE
    cat > /root/validate-b300.sh <<'CHECK'
    #!/bin/bash
    echo "=========================================="
    echo " GPU Bare Metal Validation"
    echo " Date: $(date)"
    echo "=========================================="

    echo "=== [1] GPU ==="
    nvidia-smi
    nvidia-smi -L
    echo ""

    echo "=== [2] NVLink/NVSwitch topology ==="
    nvidia-smi topo -m
    echo ""

    echo "=== [3] EFA devices ==="
    /opt/amazon/efa/bin/fi_info -p efa 2>/dev/null | head -100
    echo ""
    echo "EFA provider count: $(/opt/amazon/efa/bin/fi_info -p efa 2>/dev/null | grep -c '^provider:')"
    echo ""

    echo "=== [4] Network cards ==="
    ip -br link
    echo "(注意：EFA-only ENI 不暴露到 IP 层，ip link 看不到是正常的)"
    echo ""

    echo "=== [5] EFA Installer / libfabric / aws-ofi-nccl 版本 ==="
    cat /opt/amazon/efa_installed_packages 2>/dev/null
    rpm -qa | grep -iE "efa|libfabric|aws-ofi-nccl" | sort
    echo ""

    echo "=== [6] CUDA / Driver ==="
    nvidia-smi --query-gpu=driver_version,vbios_version --format=csv
    nvcc --version 2>/dev/null || echo "(no nvcc)"
    echo ""

    echo "=== [7] Fabric Manager ==="
    systemctl status nvidia-fabricmanager --no-pager 2>/dev/null | head -10
    echo ""

    echo "=== [8] NCCL test (single-node) ==="
    if [ -f /opt/nccl-tests/build/all_reduce_perf ]; then
      GPU_COUNT=$(nvidia-smi -L | wc -l)
      /opt/nccl-tests/build/all_reduce_perf -b 8 -e 8G -f 2 -g $GPU_COUNT
    else
      echo "(nccl-tests not pre-built)"
    fi
    CHECK
    chmod +x /root/validate-b300.sh
    echo "Run: sudo /root/validate-b300.sh" > /etc/motd
  VALIDATE

  user_data_dlami = <<-EOT
    #!/bin/bash
    set -e
    exec > >(tee /var/log/user-data.log) 2>&1
    echo "=== DLAMI bringup $(date) ==="

    %{if var.allocate_eip}
    # 等待公网连通（适用于 EIP 异步关联场景，最多等 10 分钟）
    for i in $(seq 1 60); do
      curl -sf --max-time 5 https://efa-installer.amazonaws.com/ >/dev/null 2>&1 && break
      echo "Waiting for internet connectivity... ($i/60)"
      sleep 10
    done
    %{endif}

    ${local.efa_installer_snippet}

    ${local.validate_snippet}

    echo "=== bringup done $(date) ==="
  EOT

  user_data_eks = <<-EOT
    #!/bin/bash
    set -e
    exec > >(tee /var/log/user-data.log) 2>&1
    echo "=== EKS AMI bringup $(date) ==="

    # 单机验证模式：disable EKS bootstrap
    systemctl disable --now nodeadm-config.service 2>/dev/null || true
    systemctl disable --now nodeadm-run.service    2>/dev/null || true
    systemctl disable --now kubelet                2>/dev/null || true
    echo "EKS AMI in inspection mode" > /var/log/inspection.log

    %{if var.allocate_eip}
    # 等待公网连通（适用于 EIP 异步关联场景，最多等 10 分钟）
    for i in $(seq 1 60); do
      curl -sf --max-time 5 https://efa-installer.amazonaws.com/ >/dev/null 2>&1 && break
      echo "Waiting for internet connectivity... ($i/60)"
      sleep 10
    done
    %{endif}

    ${local.efa_installer_snippet}

    ${local.validate_snippet}

    echo "=== bringup done $(date) ==="
  EOT
}

###############################################################################
# Outputs
###############################################################################

output "instance_id" {
  value = aws_instance.p6_b300.id
}

output "private_ip" {
  value = aws_instance.p6_b300.private_ip
}

output "public_ip" {
  value = var.allocate_eip ? aws_eip.instance[0].public_ip : null
}


output "ami_used" {
  value = "${var.ami_choice}: ${local.ami_id}"
}

output "launch_template_id" {
  value = aws_launch_template.instance.id
}

output "summary" {
  value = <<-EOT

  ========================================
   GPU instance launched
  ========================================
   Instance ID    : ${aws_instance.p6_b300.id}
   Instance Type  : ${var.instance_type}
   Purchase Mode  : ${var.purchase_mode}
   Private IP     : ${aws_instance.p6_b300.private_ip}
   AMI            : ${var.ami_choice} (${local.ami_id})
   Total NICs     : ${local.total_nic_count} (1 primary + ${local.efa_card_count} EFA-only)

   SSH 进入（通过堡垒机）：
     ssh -J ec2-user@<BASTION_HOST> ec2-user@${aws_instance.p6_b300.private_ip}

   或手动挂 EIP 后从公网直连（需要先在控制台/CLI 把 EIP 关到 primary ENI）：
     # 找到主网卡：
     #   aws ec2 describe-instances --instance-ids ${aws_instance.p6_b300.id} \
     #     --query 'Reservations[].Instances[].NetworkInterfaces[?Attachment.NetworkCardIndex==`0`].NetworkInterfaceId' --output text
     # 关联 EIP：
     #   aws ec2 associate-address --allocation-id eipalloc-xxx --network-interface-id eni-xxx

   登录后跑验证：
     sudo /root/validate-b300.sh

   销毁：
     terraform destroy

  ========================================
  EOT
}
