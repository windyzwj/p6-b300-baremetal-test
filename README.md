# p6-b300.48xlarge 裸机验证 Terraform

在 EKS 集群创建之前，先开一台 p6-b300 裸机做硬件验证：GPU、EFA、NCCL 通信、关键软件版本。

---

## 关键注意事项

p6-b300 是新硬件（Blackwell Ultra），比常规 GPU 实例多了几个**坑**，普通 `aws_instance` 默认配置起不来或起了功能不全：

### 坑 1：必须显式 attach 17 张网卡

p6-b300.48xlarge 物理上有 **17 张网卡**：
- 1 张 ENA（普通网卡，走 IP 流量、SSH、镜像拉取）
- 16 张 **EFA-only** ENI（B 系列新型 ENI，没有 IP，专门承载 EFA 高速通信）

**默认 `aws_instance` 只会创建 1 张 primary ENI**，其他 16 个 EFA 网卡完全没挂。结果：
- ✅ SSH 能进，nvidia-smi 正常
- ❌ `fi_info -p efa` 列不出 16 个 device，多机训练带宽掉到 1/16
- ❌ NCCL 看到只有 1 个网卡可用，AllReduce 性能直接崩盘

本 Terraform 用 Launch Template 的 `network_interfaces` 块声明全部 17 张网卡，AWS 在 RunInstances 时同步创建，实例销毁时自动清理。

### 坑 2：Security Group 必须 self-referencing

EFA 协议要求**同 SG 内的 EFA 端点之间允许全协议流量**，否则 NCCL 跨节点通信走不通。普通的 inbound 规则不够，必须加一条 `source = self` 的全协议放行。

### 坑 3：AMI 选择

| AMI | 适用场景 |
|---|---|
| **AWS Deep Learning Base GPU AMI (AL2023)** | 纯硬件 + EFA + NCCL 验证。预装 NVIDIA driver、CUDA、EFA Installer、aws-ofi-nccl、NCCL，开机即用 |
| **EKS-optimized NVIDIA AMI** | 验证 EKS 节点组上线后的实际行为（与 EKS 节点用同一 AMI） |

通过 `ami_choice` 变量切换，默认 `dlami`。

### 坑 4：EFA 用户态需要在 user-data 安装

EKS NVIDIA AMI 默认只预装 EFA 内核模块（`efa.ko`），**没有用户态工具**（libfabric / fi_info / aws-ofi-nccl）。本 Terraform 的 user-data 会自动安装 EFA Installer（不加 `--skip-kmod`，完整安装 libfabric-aws + aws-ofi-nccl）。

---

## 使用方法

### 1. 前置条件

- ✅ VPC + 私有子网已建好（子网在目标 AZ）
- ✅ EC2 Key Pair 已创建
- ✅ 堡垒机 SG 已存在
- ✅ Terraform ≥ 1.5、AWS CLI 已配好凭据

### 2. 配置变量

```bash
cd p6-b300-baremetal-test
cp terraform.tfvars.example terraform.tfvars
# 编辑 terraform.tfvars 填入实际 ID
```

### 3. 启动

```bash
terraform init
terraform plan
terraform apply
```

apply 完成后 outputs 里会打印 SSH 命令和 instance ID。

### 4. SSH 进入验证

通过堡垒机跳进去，登录后：

```bash
sudo /root/validate-b300.sh
```

脚本会输出：
- `nvidia-smi`：8 张 B300 是否全部识别
- `nvidia-smi topo -m`：NVLink/NVSwitch 拓扑
- `fi_info -p efa`：EFA provider 是否全部列出
- 网卡布局、EFA Installer / aws-ofi-nccl 版本、Driver 版本
- Fabric Manager 状态
- 单机 NCCL all_reduce_perf（DLAMI 自带 nccl-tests）

### 5. 重点关注

| 检查项 | 期望值 |
|---|---|
| `nvidia-smi -L` 列出 GPU 数量 | **8 张 B300** |
| `fi_info -p efa` provider 数 | **48**（16 张 EFA × 3 种 fabric） |
| EFA Installer 版本 | **≥ 1.47** |
| aws-ofi-nccl（libnccl-ofi） | **≥ 1.13** |
| NVIDIA Driver | **≥ 570** |
| CUDA Runtime | **≥ 12.8** |
| nccl-tests AllReduce busbw（8卡） | 理论值附近 |

### 6. 销毁

```bash
terraform destroy
```

---

## 文件结构

```
p6-b300-baremetal-test/
├── main.tf                       # 主资源定义
├── terraform.tfvars.example      # 变量模板
├── docker-compose-pd.yaml        # PD 分离部署（可选）
└── README.md                     # 本文件
```

---

## 进阶：多机 NCCL 测试

单机验证通过后，如果要测**多机 EFA 通信**，launch 两台同一 cluster placement group 内的 p6-b300，然后跑：

```bash
mpirun -np 16 -H node0:8,node1:8 \
  -x NCCL_DEBUG=INFO \
  -x FI_PROVIDER=efa \
  -x FI_EFA_USE_DEVICE_RDMA=1 \
  /opt/nccl-tests/build/all_reduce_perf -b 8M -e 8G -f 2 -g 1
```

---

## 常见问题

### Q1：`fi_info -p efa` 只列出 1 个 provider

- 网卡没挂全。检查 Launch Template 的 `network_interfaces` 是否声明了 16 张 efa-only
- EFA 用户态没装。登录后手动跑：
  ```bash
  cd /tmp && curl -fsSLO https://efa-installer.amazonaws.com/aws-efa-installer-latest.tar.gz
  tar -xf aws-efa-installer-latest.tar.gz && cd aws-efa-installer
  sudo ./efa_installer.sh -y
  ```

### Q2：NCCL 跨节点性能极差

- EFA SG 没 self-reference
- 检查 `FI_PROVIDER=efa`、`NCCL_DEBUG=INFO` 看是不是 fallback 到了 sockets

### Q3：用 EKS AMI 启动后一直在刷 nodeadm 日志

- user-data 里 disable nodeadm 没生效，手动再跑：
  ```bash
  sudo systemctl disable --now nodeadm-config.service nodeadm-run.service kubelet
  ```

### Q4：PD 分离模式下 nixl KV transfer 报 `vendor_err 0xf`

- UCX 错误选了 EFA RDMA transport。加环境变量限制 UCX 只走 cuda_ipc：
  ```yaml
  environment:
    - UCX_TLS=cuda_copy,cuda_ipc,tcp
    - UCX_MEMTYPE_REG_WHOLE_ALLOC_TYPES=cuda
  ```
- 单机 PD 分离走 `cuda_ipc`（NVLink），不需要 EFA
- 多机 PD 分离需要改用 libfabric backend（参考 NVIDIA Dynamo 文档）
