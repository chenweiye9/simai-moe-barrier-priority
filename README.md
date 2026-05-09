# simai-moe-barrier-priority

SimAI-based research code for barrier-aware network scheduling in MoE training.

> This repository snapshot is self-contained.
> The working contents of `ns-3-alibabacloud`, `aicb`, and `SimCCL` are vendored directly in this snapshot so the repo can be used without re-applying local submodule changes first.

## 项目概述

这个仓库基于 [aliyun/simAI](https://github.com/aliyun/simAI) 做二次研究，当前聚焦的创新点是：

**在 MoE 训练的 many-to-one 专家聚合阶段，识别决定 barrier 完成的最后未完成 sender，并对其剩余流量进行动态优先级提升。**

它解决的核心问题是：

- 一个接收端往往需要等待多个专家返回结果
- 即使大部分 sender 已经完成，只要最后一个 sender 没到，当前轮次仍然会被阻塞
- 因此，网络调度的重点不应该只是“谁短谁先发”，还应该识别“谁决定这一轮什么时候结束”

## 当前进度

截至 **2026-05-09**，已经完成以下工作：

- Linux 虚拟机环境已打通，主工作目录为 `/home/weiye-chen/SimAI`
- `SimAI_analytical` 编译通过
- `SimAI_simulator` 编译通过
- `AstraSimNetwork` 入口验证通过：`SimAI_simulator -h`
- 已实现 barrier-tail priority 的第一版最小原型

当前原型机制如下：

1. 使用 AstraSim 的 `current_flow_id` 作为 group id
2. 在 `RdmaHw` 中按 `(dst, group_id)` 跟踪 fan-in group
3. 当某个 group 只剩最后一个 sender 未完成时，将该 sender 下剩余 QP 标记为 `tail-critical`
4. `QbbNetDevice` 优先调度这些 `tail-critical` QP，并将其切换到更高优先级 PG

## 关键改动位置

主仓库中的核心改动：

- `astra-sim-alibabacloud/astra-sim/network_frontend/ns3/entry.h`
- `astra-sim-alibabacloud/astra-sim/network_frontend/phynet/SimAiMain.cc`
- `astra-sim-alibabacloud/astra-sim/system/MockNcclLog.h`
- `astra-sim-alibabacloud/build.sh`
- `astra-sim-alibabacloud/build/astra_ns3/build.sh`
- `scripts/build.sh`

`ns-3-alibabacloud` 子模块中的核心改动：

- `simulation/src/applications/helper/rdma-client-helper.cc`
- `simulation/src/applications/helper/rdma-client-helper.h`
- `simulation/src/applications/model/rdma-client.cc`
- `simulation/src/applications/model/rdma-client.h`
- `simulation/src/network/utils/bit-deserializer.h`
- `simulation/src/network/utils/bit-serializer.h`
- `simulation/src/point-to-point/model/qbb-net-device.cc`
- `simulation/src/point-to-point/model/rdma-driver.cc`
- `simulation/src/point-to-point/model/rdma-driver.h`
- `simulation/src/point-to-point/model/rdma-hw.cc`
- `simulation/src/point-to-point/model/rdma-hw.h`
- `simulation/src/point-to-point/model/rdma-queue-pair.cc`
- `simulation/src/point-to-point/model/rdma-queue-pair.h`

## 构建说明

### 1. 初始化环境

```bash
git clone <this-repository>
cd simai-moe-barrier-priority
```

> 当前快照已经直接包含 barrier-tail 相关源码改动。
> `patches/` 目录保留的是研究补丁副本，主要用于对照、迁移或复现，不再是使用当前仓库的前置步骤。

### 2. 编译

建议显式使用 `gcc-13/g++-13`：

```bash
export CC=gcc-13
export CXX=g++-13
export SIMAI_LOG_DIR=$HOME/.simai
```

分析模型：

```bash
./scripts/build.sh -c
```

ns-3 仿真模型：

```bash
cd astra-sim-alibabacloud/build/astra_ns3
./build.sh -r
```

### 3. 运行入口

```bash
~/SimAI/bin/SimAI_analytical
~/SimAI/bin/SimAI_simulator
```

## 当前构建链注意事项

- 当前 Ubuntu 24.04 环境下默认 `gcc/g++` 可能不是可用版本，建议固定到 `gcc-13/g++-13`
- 日志路径已从 `/etc/astra-sim` 改为用户目录，默认写入 `~/.simai`
- `astra-sim-alibabacloud/build/astra_ns3/build.sh` 已增加自动同步逻辑：
  - 会把根目录 `ns-3-alibabacloud/simulation/src` 的源码同步到活动构建镜像
  - 这样后续修改 ns-3 源码时，不需要手动再改 `extern/network_backend/ns3-interface/simulation/src`

## 下一步实验任务

接下来优先做的是最小验证实验，而不是继续扩机制：

1. 构造一个小规模 many-to-one 聚合场景，例如 `5 -> 1`
2. 分别运行“关闭机制”和“开启机制”两组实验
3. 关注以下指标：
   - 最后一个 tail flow 的完成时间
   - 整个 fan-in group 的完成时间
   - iteration 总完成时间
4. 检查日志中是否出现 `barrier-tail-prio enable/disable`
5. 根据结果判断是否需要加入：
   - 完成比例阈值
   - 剩余字节门限
   - 防止高优队列长期占用的保护策略

## 与上游仓库的关系

本项目建立在上游 SimAI 之上，建议保留对上游的关注：

- 上游主仓库：<https://github.com/aliyun/simAI>
- 本项目仓库：<https://github.com/chenweiye9/simai-moe-barrier-priority>

当前建议的工作方式是：

- 以本仓库作为研究主仓库
- 用 patch 管理 `ns-3-alibabacloud` 的实验性改动
- 当机制稳定后，再决定是否把子模块改动拆成独立 fork 或直接 vendor 进主仓库
