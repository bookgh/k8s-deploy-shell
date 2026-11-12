# ks-deploy-shell 项目实施总提示词（Shell-only）

> 本文是项目 AI 编码代理和贡献者必须遵循的实施契约。任何实现均须以仓库中的架构文档、实施计划和本文件为准。若约束冲突、信息缺失或目标环境与假设不符，先停止并报告，不得自行放宽要求。
>
> **当前授权边界：** 用户只要求完善需求/提示词时，只能修改 Markdown 文档；不得编写部署脚本、下载制品、生成生产证书、触发 Release、连接或修改真实集群。只有用户明确指定实现里程碑或操作时，才可进入对应范围。

## 1. 项目目标与技术基线

构建面向 Rocky Linux 9、amd64 的 Kubernetes 官方二进制部署框架，目标 Kubernetes 版本为 `v1.37.2`。采用官方二进制、RPM、Helm Chart、镜像归档和 Systemd；安装节点是唯一编排入口。部署必须可重复、可审计、可离线交付、可恢复、可平滑升级。

- 仅允许 Bash Shell 编排；远端通过 SSH 执行命令，远端通过安装节点 Caddy 的 HTTP 服务下载制品。
- 禁止 kubeadm、k3s、RKE、Ansible、SaltStack 等替代本项目的部署编排。
- GitHub Actions 仅构建、验证、打包和发布制品，不得连接集群或执行部署。
- Kubernetes、etcd、运行时、CNI、工具、Chart、镜像版本必须精确锁定；版本只允许在权威配置中定义。
- 部署期间禁止从公网下载制品；禁止 SCP/SFTP/rsync 或 SSH heredoc 逐台传输部署文件。
- Worker kubeconfig 的 API 地址必须为 `https://127.0.0.1:6443`，不得直连 Master IP。

## 2. Shell-only 强制约束

### 2.1 语言边界

项目部署、构建、配置解析、模板处理、状态判断、测试辅助和验收逻辑全部使用 Bash / Shell 及明确批准的命令行工具。**禁止 Python**，包括内嵌脚本、临时代码、CI 辅助程序和测试逻辑；禁止以 Perl、Ruby、Node.js、Go 或其他通用语言承担上述项目逻辑。不得动态生成并执行这些语言的程序。

允许工具须纳入依赖清单并锁定版本、来源、架构、校验和及离线获取方式：Bash、GNU coreutils、findutils、grep、sed、gawk、util-linux、curl、tar、gzip、xz、sha256sum、openssl、systemctl、journalctl、ss、ip、nft、iptables、ipvsadm、modprobe、sysctl、rpm、dnf、kubectl、crictl、ctr、helm、ShellCheck、Bats-core、shfmt。jq 仅用于 JSON 数据处理；yq 仅在版本锁定、校验来源并纳入离线依赖闭包后使用。不得假定目标机预装了开发机已有工具。不得使用 jq/yq 或其他工具替代 Shell 编排。

### 2.2 脚本规范

所有脚本使用：

```bash
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\\n\\t'
```

统一公共库处理日志、错误、参数、锁、临时目录、原子写入、备份、校验和、重试、超时和权限。错误处理保留原始退出码、脚本名、函数名、行号及日志位置。命令参数优先使用 Bash 数组；变量引用加双引号；路径和用户输入做白名单校验。

禁止 `eval`、`bash -c "$user_input"`、未经校验的动态命令拼接、危险通配删除和不可信配置直接 `source`。Shell 配置若采用 source，必须限制为受控赋值语法并先验证；优先使用无执行能力的解析方式。不得使用 grep/sed 解析任意 YAML。

### 2.3 工程质量

- 函数必须明确输入、输出、副作用、失败语义；公共函数不得暗改全局配置。
- 步骤必须幂等：每次重新探测真实状态，不得以文件存在或状态标记代替健康检查。
- 安装节点使用 flock 等机制实现集群级并发锁；远端组件变更也须防并发。
- 文件写入采用同文件系统临时文件和原子 mv；临时文件权限从创建时即受控。
- 所有远端命令安全编码参数；SSH 开启 HostKey 验证、连接超时、有限重试、退避、日志和退出码。
- Dry-run 必须严格零副作用：不得创建目录/文件、持锁、下载、SSH 执行、改权限、改系统或调用会产生副作用的命令。通过命令计划和测试证明。
- 每个变更先备份并定义失败恢复路径；危险操作分级并要求显式确认。

## 3. 架构和配置基线

### 3.1 角色

- **安装节点：** 唯一部署入口；配置解析、预检、SSH 编排、Caddy、制品缓存、日志和报告。
- **Master：** etcd、Kubernetes 控制平面、kubelet、kube-proxy。
- **Worker：** 容器运行时、kubelet、kube-proxy、Nginx stream 本地 API 代理和业务 Pod。
- **Harbor：** 可选独立节点/服务。

### 3.2 配置与目录

建议使用 `cluster.env` 管理节点、地址、CIDR、目录、开关、运行时和 SSH 参数；`versions.yaml` 管理 Kubernetes、etcd、containerd、runc、CNI、cfssl、Helm、Caddy、Nginx、Harbor 等版本及下载信息；`charts.yaml` 管理 Calico、CoreDNS、NodeLocal DNSCache 的精确 Chart 版本。节点数组必须描述名称、IP、SSH 用户、角色及 etcd member 名称。Chart 默认版本如需动态解析，只能在初始化时解析一次并锁定，之后不得使用 latest。

目录至少规划 README、bin、scripts、config、templates、pki、artifacts、output、state、docs、tests 和 GitHub Actions workflow。敏感文件必须被 .gitignore 排除；不得把密钥、CA 私钥或 kubeconfig 放入制品 HTTP 根目录。

所有 IP、网段、域名、端口、路径、版本和镜像信息均由单一权威配置驱动。必须校验地址合法性、节点唯一性、CIDR 冲突、SAN 一致性、多网卡选择和组件依赖。不得根据网卡顺序、主机名或默认路由猜测用户意图。

## 4. 组件实施要求

### 4.1 安装节点与制品

Caddy 默认端口 2026，端口可配置。HTTP 根目录只包含非敏感制品。每个制品提供来源、版本、架构、SHA256、签名/校验方式和清单。部署节点仅通过 HTTP 下载并校验 SHA256。RPM 最小依赖集合必须包含完整依赖闭包；离线制品分包、可校验、可追溯。

### 4.2 系统初始化

`01-init-system.sh` 按配置处理 firewalld、SELinux、内核模块、sysctl、PAM/Systemd limits、TCP、Chrony、hostname 和 hosts。默认安全策略优先保留 SELinux Enforcing 并配置所需策略/端口；若用户显式要求关闭，必须说明安全影响并受配置开关控制。防火墙应配置最小必要规则，不得无差别关闭或清空。按节点角色参数化；检查内核能力，不盲目设置极大值。Systemd unit 明确资源限制。

### 4.3 PKI 与证书

使用 CFSSL 建立 Kubernetes Root CA、ETCD CA、Front Proxy CA；ServiceAccount key 独立；Harbor 证书独立。用户要求证书有效期 100 年时，CFSSL duration 使用 `876000h`，不得写 `100y`。CI 必须用锁定的 CFSSL 实际签发根/叶证书并验证 NotBefore/NotAfter。已有 PKI 必须逐项检查用途、SAN、有效期、密钥匹配和权限，严禁无条件覆盖。私钥目录 0700、私钥文件 0600。提供 CA 离线备份、审计、证书扫描、轮换和回滚流程。

### 4.4 etcd 与控制平面

etcd 使用官方独立二进制、Systemd、双向 TLS；数据目录与二进制分离。实现 endpoint health/status/member list、快照、校验和恢复演练。成员变更不得清空数据目录。API Server 监听地址/端口按配置，默认端口 6443；启用 TLS、RBAC、Node authorizer、关闭匿名访问和可配置审计。HA 使用官方 leader election。admin kubeconfig 仅导出至安装节点 `output/kubeconfig/admin.kubeconfig`，权限 0600。

### 4.5 容器运行时与 Worker 代理

默认 containerd、CRI、systemd cgroup；root/state 目录配置化。Docker 若作为运行时必须使用 cri-dockerd；Docker 作为附属工具时 kubelet 不得指向 Docker。每节点只允许一个 CRI endpoint。HTTP registry 是明文，不得描述为 TLS 信任；HTTPS 必须校验 CA、完整证书链和 SAN。

Worker Nginx stream 本地监听 `127.0.0.1:6443`，upstream 由 Master 列表生成，TLS 由 API Server 终止，Nginx 仅做 TCP 转发。不得假设开源 Nginx 默认支持主动健康检查。配置变更先语法检查再 reload；测试 Master 故障/恢复、连接重建和 API 请求。Worker kubelet/kubeconfig 只访问本地代理。

### 4.6 Harbor、镜像和 Addons

Harbor 可选，使用官方离线包、版本锁定和持久化目录。镜像模式互斥：`offline-harbor`、`online`、`local-import`。离线且无 Harbor 时禁止暗中公网拉取。镜像归档导入后校验 repository、tag、digest。Chart values 与镜像归档映射必须一致。

通过 Helm 安装 Calico、CoreDNS、NodeLocal DNSCache；Chart tgz 本地安装。CI 解析 values、templates、subcharts、hooks、initContainers、sidecars 的镜像闭包；operator 动态镜像必须补充清单并在安装后做差异检查。区分 OCI digest 与归档 SHA256。验证 Calico、kube-proxy、内核、NodeLocal、nftables/iptables 兼容矩阵。

### 4.7 kube-proxy

支持 nftables（默认）、ipvs、iptables，模式必须显式配置并做模块/工具预检。模式切换前备份，逐节点切换并验证；禁止全局 flush 规则。

## 5. 脚本和执行依赖

建议脚本：
- `00-prepare-install-node.sh`
- `01-init-system.sh`
- `02-gen-ca-and-certs.sh`
- `03-deploy-harbor.sh`
- `04-deploy-etcd.sh`
- `05-deploy-k8s-control-plane.sh`
- `06-deploy-container-runtime.sh`
- `07-deploy-kubelet-kubeproxy.sh`
- `08-deploy-worker-nginx-proxy.sh`
- `09-deploy-addons.sh`
- `10-cluster-check.sh`
- `11-rotate-certificates.sh`
- `00-clean-cluster.sh`
- `bin/install.sh`、`bin/deploy-step.sh`

编号不代表机械执行顺序。依赖顺序必须为：准备安装节点 -> 系统初始化 -> 证书 -> Harbor（可选）-> etcd -> 容器运行时 -> 控制平面 -> Worker Nginx 代理（早于 Worker kubelet）-> kubelet/kube-proxy -> addons -> kubeconfig -> 验收。Master kubelet 同样依赖 CRI。调度器必须按依赖图检查前置条件，不能仅按文件名排序。

## 6. 安全、恢复、升级与清理

- 任何现有 PKI、etcd、容器、Harbor 或业务数据必须先识别和保护；禁止默认覆盖或删除。
- 升级遵循 Kubernetes 官方版本偏差策略，逐 Minor 升级；先验证 etcd 快照，再按 HA 控制面滚动升级；Worker 逐节点 cordon/drain；保留可回退的旧二进制和配置。
- 二进制回滚不等于 API/etcd 数据回滚，必须单独说明兼容性和恢复边界。
- 清理分级：默认只停止服务；删除数据必须明确列出目标、展示影响、确认备份并二次确认。不得使用未校验路径的 rm -rf。
- 证书轮换、节点增删、etcd member 变更、运行时切换和 kube-proxy 模式切换均需独立事务、备份、逐步验证和回滚方案。

## 7. 验收与测试

每个脚本必须有 ShellCheck、shfmt、Bats 测试；关键函数覆盖正常、失败、重复执行、并发、异常输入和中断恢复。测试不得依赖 Python。至少验证：

1. 制品清单、SHA256、Caddy 下载及 RPM 依赖闭包。
2. 系统参数、SSH HostKey/超时/重试、网络连通和端口。
3. etcd health/status/member、快照与恢复。
4. API Server livez/readyz、控制面组件、Node Ready。
5. Calico 跨节点网络、DNS、ClusterIP、NodePort。
6. Harbor（启用时）、镜像 digest 和离线镜像闭包。
7. Worker kubeconfig localhost endpoint、Nginx 故障切换与恢复。
8. 证书有效期、SAN、用途、权限和轮换。
9. 临时 Deployment/Service 端到端访问和清理。
10. dry-run 零副作用、重复执行幂等、并发锁和破坏性操作保护。

验收输出文本与 JSON 报告。关键项全部通过才可报告成功；未运行的测试必须标记未验证，不得伪造通过。真实 Rocky Linux 9 目标环境验证不可由静态检查替代。

## 8. 建议实施阶段与交付标准

实施计划必须为每个里程碑定义目标、前置条件、文件范围、交付物、测试、验收条件、风险和退出条件。建议先完成仓库骨架、配置契约、公共 Shell 库、预检和测试基础，再逐组件实施。未经用户授权不得跨越里程碑。

每轮实现任务必须：
1. 先读取 main 分支的 `ARCHITECTURE.md`、`IMPLEMENTATION-PROMPT.md`、`IMPLEMENTATION-PLAN.md`、`README.md` 和相关代码/测试。
2. 报告当前分支、HEAD、工作区状态、已实现/部分实现/未实现情况。
3. 只实现用户本轮明确指定的范围。
4. 同步更新测试、文档、风险和兼容性说明。
5. 提供实际执行的命令、结果和未验证事项；不得把文件存在或 TODO 当作完成。
6. 未完成静态检查、自动化测试、Rocky Linux 9 目标环境验证、文档同步和风险记录前，不得标记里程碑完成。

## 9. AI 代理每轮任务模板

开始任务前先执行上下文恢复，不得直接编码：

- 读取 main 分支项目文档和现有代码，优先完整阅读架构、提示词、实施计划及 README。
- 检查 git status、HEAD、最近提交和目录结构。
- 梳理本轮相关功能的真实实现、调用链、测试和已知问题。
- 列出本轮唯一目标、允许修改的文件、明确不做的事项、验收命令及风险。
- 若关键文档缺失、相互冲突或仓库状态无法确认，先停止并提问/报告。

**本轮任务：** `<用户明确指定的任务，例如：启动 M0 / 完成某个具体功能>`

**边界：** 不扩展到其他里程碑；不擅自部署；不执行破坏性操作；严格遵循 Shell-only；不得使用 Python。
