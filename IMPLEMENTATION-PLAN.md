# ks-deploy-shell 实施计划

> 状态：持续实施基线（2026-11-13）；真实完成状态见 docs/IMPLEMENTATION-STATUS.md。

## 1. 实施规则

每轮先读取 ARCHITECTURE.md、IMPLEMENTATION-PROMPT.md、IMPLEMENTATION-PLAN.md、README.md 和相关代码；检查分支、HEAD、工作区、最近提交和目录。只根据代码、测试和环境证据更新状态。严格 Shell-only。CI 不部署集群。任何真实节点操作、生产 CA 生成、制品下载或 Release 必须另有明确操作授权。

## 2. 里程碑

| 阶段 | 主题 | 交付 | 退出条件 |
|---|---|---|---|
| M0 | 仓库骨架 | 目录、忽略规则、CI、文档 | Shell-only 门禁和 CI |
| M1 | 配置/公共库 | 安全解析、校验、日志、锁、原子写、dry-run | Bats 覆盖正常/异常/重复/并发 |
| M2 | 安装节点/制品 | 预检、manifest、SHA256、Caddy | 离线制品闭包和 HTTP 校验 |
| M3 | 系统/SSH | HostKey、超时重试、系统初始化 | Rocky 9 目标验证、dry-run 零副作用 |
| M4 | PKI | CA、叶证书、检查、备份/轮换 | SAN/用途/期限/权限和恢复验证 |
| M5 | etcd | 官方二进制、Systemd、mTLS、成员/快照 | 健康和隔离恢复演练 |
| M6 | 控制平面 | API Server、controller、scheduler、HA | livez/readyz、组件健康 |
| M7 | 节点运行时 | containerd、kubelet、kube-proxy、Nginx | Node Ready、代理故障恢复 |
| M8 | Harbor/Addons | 镜像模式、Calico、CoreDNS、NodeLocal | 离线镜像闭包、网络/DNS |
| M9 | 验收/清理 | 报告、端到端、分级清理 | 所有强制项通过、删除保护 |
| M10 | 升级/恢复 | 逐版本升级、回滚、轮换 | 目标环境演练 |
| M11 | 发布 | 离线包、兼容矩阵、运维手册 | 可复现构建和发布审计 |

## 3. 各阶段验收

### M0
目录分层清晰；敏感文件被忽略；CI 执行 bash -n、ShellCheck、shfmt、Bats 和禁用语言扫描；CI 不连接集群。

### M1
配置加载不执行任意 shell；字段、类型、CIDR、节点、端口、版本校验在远端变更前失败；公共库提供日志、错误、参数、锁、临时目录、原子写、备份、SHA256、重试和 dry-run；测试证明 dry-run 零副作用。

### M2
本机 OS/架构/磁盘/命令/端口预检；manifest 使用不可变 HTTPS URL 和 SHA256；错误校验停止；Caddy 仅公开非敏感制品；RPM 和镜像/Chart 闭包可审计。

### M3
SSH 必须 strict host key、batch mode、超时和有限退避；SELinux 默认 Enforcing；防火墙最小规则；模块/sysctl/limits/Chrony 按角色配置并备份；重复执行幂等。

### M4
CFSSL 锁版本；根 CA 分离；证书检查链、SAN、用途、有效期和密钥匹配；已有 PKI 不覆盖；私钥权限和离线备份通过验证。

### M5–M8
etcd 成员变更不清空数据；快照可恢复。API Server TLS/RBAC/Node authorizer/审计有效。Runtime 每节点单 CRI endpoint、systemd cgroup。Worker kubeconfig 固定 localhost endpoint；Nginx 仅 stream 转发。Chart 和镜像完整闭包锁定；安装后比对镜像清单。

### M9–M11
报告区分 PASS/FAIL/NOT_VERIFIED；清理默认不删数据；升级遵循官方 skew、快照和逐节点滚动；离线包有清单、校验和、SBOM/来源记录（若纳入发布要求）及运维文档。

## 4. 完成定义

每个阶段必须具备：代码、静态检查、自动化测试、文档同步、风险记录和目标环境验证。任何未执行测试必须明确列为未验证。仅有脚本或配置文件不构成阶段完成。真实 Rocky Linux 9、目标网络、etcd 恢复和完整 Kubernetes 集群验证均为生产使用前置条件。

## 5. 状态跟踪

状态以 docs/IMPLEMENTATION-STATUS.md 为准。截至 2026-11-13：M0–M4 有部分工具实现（M4 包含 Kubernetes Root CA 与 pathLen=0 intermediate signer）；M5 已有 etcd 3.7.3 新集群 bootstrap、mTLS、Systemd、健康/成员/快照命令和 39 项 CI 测试，但真实 Rocky Linux 9 集群验证与恢复演练未完成，故仍为部分完成。M6 已有控制平面部署与 kubeconfig 入口，M7 已有 containerd CRI 基础部署入口，二者均为部分完成；kubelet/kube-proxy/Nginx 和 M8 Addons 尚未完成，M10 仍未实现，不能标记为完成。

## Progress snapshot — 2026-11-13

| Milestone | Current implementation state |
|---|---|
| M0–M5 | Previously recorded in `docs/IMPLEMENTATION-STATUS.md`; retain their existing acceptance gates |
| M6 | Partial: control-plane binaries, systemd units and kubeconfigs are present; HA rollout and live API validation remain unverified |
| M7 | Partial: containerd CRI, kubelet/kube-proxy binaries, node-specific kubeconfigs and disabled service units are present; Worker Nginx stream proxy and service activation remain |
| M8 | Not implemented: Harbor, Calico, CoreDNS and NodeLocal DNSCache are not yet deployable |
| M9–M11 | Not implemented: end-to-end acceptance, upgrade/recovery and release packaging remain |

A milestone is not complete merely because scripts exist. Each stage must pass static checks, unit tests, idempotence/dry-run checks, failure-path tests and Rocky Linux 9 integration tests before its status is changed to complete.

## M7 progress note — 2026-11-13

The current M7 implementation includes kubelet/kube-proxy credentials and disabled units, a pinned Nginx source build, and a Worker-only loopback stream proxy deployment path. Node-service activation remains gated until M8 add-ons have been installed. M7 is still partial until Rocky Linux 9 target integration, failover behavior, TLS pass-through, service recovery and end-to-end cluster checks pass.
