# 研究进度记录

## 时间

2026-05-09

## 已完成

- 在 Linux 虚拟机 `/home/weiye-chen/SimAI` 上完成 SimAI 基础环境部署
- 修复并验证 `SimAI_analytical` 编译链
- 修复并验证 `SimAI_simulator` 编译链
- 处理 Linux 环境下脚本执行、CRLF、编译器版本、日志路径等问题
- 实现 barrier-tail priority 第一版原型

## 当前原型机制

这版实现的核心逻辑是：

- 使用 `current_flow_id` 作为逻辑 group 标识
- 在接收端维度按 `(dst, group_id)` 维护一个 fan-in group
- 记录 group 中哪些 sender 仍有未完成 QP
- 当 group 中只剩最后一个 sender 未完成时：
  - 将其剩余 QP 标记为 `tail-critical`
  - 在 `QbbNetDevice` 中优先调度这些 QP
  - 同时将其切换到更高优先级 PG

## 当前实现边界

这仍然是“最小原型”，还没有加入：

- 完成比例阈值
- 剩余字节阈值
- 提优超时回退
- 更细粒度的多队列配额控制

## 当前主要风险

- `ns-3-alibabacloud` 仍然是子模块，研究改动需要 patch 或独立 fork 管理
- 活动编译目录与根目录源码存在镜像关系，需要保持同步
- 现阶段只验证了“能编译、能启动”，还没有完成完整实验对照

## 接下来最重要的事情

### 优先级最高

做一个最小 many-to-one 仿真实验，验证：

- 最后一个 sender 是否真的被识别为关键尾流
- 提优是否真的缩短 fan-in barrier 完成时间

### 建议实验顺序

1. 小规模 `5 -> 1` 聚合
2. 关闭机制 baseline
3. 开启机制 experimental
4. 对比 tail completion time 和 group completion time
5. 看是否需要增加保护条件
