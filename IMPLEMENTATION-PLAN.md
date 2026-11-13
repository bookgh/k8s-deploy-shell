# ks-deploy-shell 实施计划

> 状态：持续实施基线（2026-11-13）；真实完成状态以 `docs/IMPLEMENTATION-STATUS.md` 为准。

## 一、实施规则

每轮开发前，必须读取 `ARCHITECTURE.md`、`IMPLEMENTATION-PROMPT.md`、`IMPLEMENTATION-PLAN.md`、`README.md` 和相关代码；检查分支、HEAD、工作区、最近提交和目录结构。只根据代码、测试和环境证据更新状态。严格遵循 Shell-only。CI 不得连接或部署真实集群。任何真实节点操作、生产 CA 生成、制品下载或 Release 发布，均须有单独、明确的操作授权。

## 二、里程碑

| 阶段 | 主题 | 主要交付 | 退出条件 |
|---|---|---|---|
| M0 | 仓库骨架 | 目录、忽略规则、CI、基础文档 | Shell-only 门禁和 CI 通过 |
| M1 | 配置与公共库 | 安全解析、校验、日志、锁、原子写、dry-run | Bats 覆盖正常、异常、重复和并发场景 |
| M2 | 安装节点与制品 | 预检、manifest、SHA256、Caddy | 离线制品闭包和 HTTP 校验通过 |
| M3 | 系统与 SSH | HostKey、超时重试、系统初始化 | Rocky Linux 9 目标验证、dry-run 零副作用 |
| M4 | PKI | CA、叶证书、检查、备份/轮换 | SAN、用途、期限、权限和恢复验证 |
| M5 | etcd | 官方二进制、Systemd、mTLS、成员/快照 | 健康检查和隔离恢复演练 |
| M6 | 控制平面 | API Server、controller-manager、scheduler、HA | livez/readyz 和组件健康检查 |
| M7 | 节点运行时 | containerd、kubelet、kube-proxy、Nginx | Node Ready、代理故障恢复 |
| M8 | Harbor 与 Addons | 镜像模式、Calico、CoreDNS、NodeLocal | 离线镜像闭包、网络和 DNS 验收 |
| M9 | 验收与清理 | 验收报告、端到端测试、分级清理 | 所有强制项通过，数据删除保护有效 |
| M10 | 升级与恢复 | 逐版本升级、回滚、证书轮换 | 目标环境升级/恢复演练 |
| M11 | 发布 | 离线包、兼容矩阵、运维手册 | 可复现构建和发布审计 |
| M12 | 安全加固与生产验收 | 全仓审查、风险修复、攻击面回归测试、Rocky Linux 9 集成验证 | CI 全绿、离线/在线闭包验证、真实集群恢复与端到端验收 |

## 三、各阶段验收要求

### M0：仓库骨架

目录分层清晰；敏感文件被忽略；CI 执行 Bash 语法检查、ShellCheck、shfmt、Bats 和禁用语言扫描；CI 不连接集群。

### M1：配置与公共库

配置加载不得执行任意 Shell；字段、类型、CIDR、节点、端口和版本校验必须在远端变更前完成；公共库提供日志、错误处理、参数、锁、临时目录、原子写、备份、SHA256、重试和 dry-run；测试必须证明 dry-run 零副作用。

### M2：安装节点与制品

执行本机 OS/架构/磁盘/命令/端口预检；manifest 使用不可变 HTTPS URL 和 SHA256；校验失败必须停止；Caddy 只公开非敏感制品；RPM、Chart 和镜像依赖闭包可审计。

### M3：系统与 SSH

SSH 必须使用 StrictHostKeyChecking、BatchMode、专用且为普通文件的 known_hosts（拒绝符号链接）、经过范围校验的 SSH 用户/端口/超时/重试参数和有限退避；远端命令参数必须白名单约束。SELinux 默认 Enforcing；防火墙只配置最小必要规则；内核模块/sysctl/limits/Chrony 按节点角色配置并备份；重复执行保持幂等。

### M4：PKI

CFSSL 锁定版本；根 CA 分离；证书检查覆盖证书链、SAN、用途、有效期和密钥匹配；已有 PKI 不得覆盖；私钥权限和离线备份必须通过验证。

### M5–M8：核心组件

etcd 成员变更不得清空数据目录；快照必须能够在隔离环境恢复。API Server 的 TLS/RBAC/Node authorizer/审计必须有效。Runtime 每个节点只能配置一个 CRI endpoint，并使用 systemd cgroup。Worker kubeconfig 固定使用 localhost endpoint；Nginx 仅做 stream TCP 透传。Chart 和镜像完整闭包必须锁定，安装后比对实际镜像清单。

### M9–M11：验收、恢复与交付

报告区分 PASS/FAIL/NOT_VERIFIED；清理默认不得删除数据；升级遵循官方版本偏差策略、快照和逐节点滚动流程；离线包具备清单、校验和、来源记录及运维文档。

## 四、完成定义

每个阶段必须同时具备代码、静态检查、自动化测试、文档同步、风险记录和目标环境验证。任何未执行的测试必须明确列为未验证。只有脚本或配置文件存在，不构成阶段完成。真实 Rocky Linux 9、目标网络、etcd 恢复和完整 Kubernetes 集群验证，均为生产使用前置条件。

## 五、当前状态跟踪

状态以 `docs/IMPLEMENTATION-STATUS.md` 为准。截至 2026-11-13：

- M0–M4 已有部分工具实现。M4 包含 Kubernetes Root CA 和 pathLen=0 intermediate signer，但证书轮换/恢复及真实节点分发仍未完成。
- M5 已有 etcd 3.7.3 新集群 bootstrap、mTLS、Systemd、健康/成员/快照命令和自动化测试；真实 Rocky Linux 9 集群验证与恢复演练未完成。
- M6 已有控制平面部署与 kubeconfig 入口；HA 控制面滚动部署和实时 API 验证未完成。
- M7 已有 containerd CRI、kubelet/kube-proxy、Nginx Worker loopback 代理入口；真实节点服务激活和故障恢复未验证。
- M8 已有固定版本 Calico/CoreDNS/NodeLocal Chart 和本地镜像导入入口；镜像闭包及真实集群验证未完成。
- M9 已有只读验收报告和可选 E2E 测试；完整生产验收未完成。
- M10 只有升级规划器，实际升级和恢复演练未完成。
- M11 只有受保护的离线包构建器，完整镜像闭包和发布审计未完成。
- M12 正在开展安全加固与生产验收：已加固制品缓存链接边界，并开始收紧 SSH 参数和 known_hosts 文件类型校验；当前提交及 CI 证据以状态文档和 PR #1 为准。

## 六、M12：安全加固与生产验收

M12 不以增加脚本数量为目标，而是逐项关闭 M0–M11 的实现缺口。所有修复必须先有可复现问题或明确验收缺口，再修改代码并增加回归测试。

执行顺序：

1. **安全边界：** 制品缓存与 HTTP 根目录、归档路径/链接/特殊文件、SSH 参数、PKI 分发、权限和敏感数据排除。
2. **幂等与恢复：** 重复执行、并发锁、原子写入、中断清理、备份一致性、失败回滚和现有数据保护。
3. **部署依赖：** etcd quorum、CRI、控制平面、Worker 本地代理、kubelet/kube-proxy、Addons 的实际依赖及服务启动顺序。
4. **验收可信度：** PASS/FAIL/NOT_VERIFIED 语义、API/etcd/节点/镜像闭包/跨节点网络/DNS/Service/NodePort/NetworkPolicy 检查。
5. **交付验证：** ShellCheck、shfmt、Bats、Shell 语法、Shell-only 门禁、Helm 渲染、制品哈希、离线包安全验证及可复现构建。
6. **真实环境：** Rocky Linux 9 amd64 多节点部署、etcd 快照恢复、控制平面故障、Worker 故障切换、离线部署和升级/回滚演练。

退出条件：

- 每个已修复缺陷均有自动化回归测试，且 CI 实际运行成功。
- 任何危险操作均有显式授权、备份、失败保护和恢复说明。
- 在线准备与离线部署的制品闭包完整且可验证。
- 真实 Rocky Linux 9 环境完成部署、故障、恢复和端到端验收。
- 文档逐项列出证据、命令、结果和未验证事项；没有证据的能力继续标记为未验证。

边界：GitHub Actions 不连接集群；CI 通过不等于生产验收通过。没有用户提供的目标环境、访问凭据和单独的操作授权时，只能补齐验证工具与自动化测试，不得宣称完成真实集群验证。
