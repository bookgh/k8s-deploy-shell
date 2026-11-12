# ks-deploy-shell 架构设计

> 状态：项目基线（2026-11-12）。本文定义目标架构；实现状态以 docs/IMPLEMENTATION-STATUS.md 为准。
> 技术基线：Rocky Linux 9 / amd64 / Kubernetes v1.37.2。

## 1. 目标与边界

建设以安装节点为唯一入口、使用官方二进制/RPM/Helm Chart/镜像归档和 Systemd 的 Kubernetes 部署框架。支持在线准备制品、离线交付和离线部署；部署期间不访问公网。全部编排、构建、配置解析、测试辅助和验收逻辑使用 Bash/Shell，禁止 Python、Perl、Ruby、Node.js、Go 等通用语言承担项目逻辑。

不使用 kubeadm、k3s、RKE、Ansible、SaltStack；不通过 SCP/SFTP/rsync 分发部署文件；GitHub Actions 只做静态检查、测试、构建和制品发布，不连接集群。Worker kubeconfig 的 API endpoint 必须为 https://127.0.0.1:6443。

## 2. 角色与数据流

- 安装节点：配置解析、预检、SSH 编排、制品缓存、Caddy HTTP 服务、锁、日志和报告。
- Master：etcd、API Server、controller-manager、scheduler、kubelet、kube-proxy。
- Worker：containerd、kubelet、kube-proxy、Nginx stream 本地 API 代理、工作负载。
- Harbor：可选镜像仓库。

安装节点通过 SSH 发送远程命令；远端节点仅通过安装节点 Caddy 下载非敏感制品并校验 SHA256。Caddy 默认 TCP 2026，HTTP 根目录不得包含私钥、kubeconfig、token 或日志。Worker Nginx 仅做 TCP stream 转发，监听 loopback 127.0.0.1:6443，TLS 在 API Server 终止。不得假设开源 Nginx 默认支持主动健康检查。

## 3. 配置单一事实源

- cluster.env：集群标识、节点角色/地址、CIDR、DNS、目录、端口、开关、运行时、镜像模式、SSH 参数。
- versions.yaml：Kubernetes、etcd、containerd、runc、CFSSL、Helm、Caddy、Nginx 等精确版本和来源。
- charts.yaml：Calico、CoreDNS、NodeLocal DNSCache 的精确 Chart 版本。
- artifacts/manifest.tsv：名称、版本、架构、HTTPS 来源、SHA256、文件名。
- config/：节点地址、Caddy、组件配置和受控模板。

配置不得 source 或 eval；采用受控 KEY=VALUE 数据解析。YAML 不得用 grep/sed 解析；如采用 yq，必须锁定版本、校验来源并纳入离线闭包。IP、版本、镜像、端口、路径不得在脚本中重复硬编码。必须校验节点唯一性、CIDR 冲突、端口、SAN、组件依赖和架构。

## 4. 网络与端口

| 服务 | 端口 | 说明 |
|---|---:|---|
| Kubernetes API | TCP 6443 | Master API |
| etcd client/peer | TCP 2379/2380 | mTLS |
| kubelet | TCP 10250 | 控制平面到节点 |
| scheduler/controller | TCP 10259/10257 | 默认安全端口 |
| Caddy | TCP 2026 | 非敏感制品下载 |
| Worker Nginx | 127.0.0.1:6443 | 本地 API TCP 代理 |
| NodePort | 配置范围 | 仅显式启用 |

Pod CIDR、Service CIDR、节点网段、管理网段不得冲突。防火墙按方向和角色开放最小端口，不得全局关闭或 flush。SELinux 默认 Enforcing。

## 5. 制品与离线闭包

准备阶段可联网获取官方二进制、RPM、Chart、镜像归档和工具；生成包含来源、版本、架构、文件名、大小、SHA256 和签名校验信息的清单。部署阶段仅从安装节点 HTTP 获取并再次校验。RPM 依赖必须闭包完整；Chart 闭包包括 templates、subcharts、hooks、initContainers、sidecars 和 operator 动态镜像。OCI digest 与归档 SHA256 是不同概念。镜像模式互斥：offline-harbor、online、local-import。离线无 Harbor 时不得暗中公网拉取。

## 6. PKI 与安全

Kubernetes Root CA、ETCD CA、Front Proxy CA 分离；ServiceAccount key 独立；Harbor 使用独立证书策略。100 年证书期限使用 CFSSL 876000h 并实际验证。已有 PKI 必须检查用途、SAN、有效期、密钥匹配和权限，禁止覆盖。私钥目录 0700、私钥 0600；CA 私钥离线备份。admin kubeconfig 仅在安装节点 output/kubeconfig/admin.kubeconfig，权限 0600。

etcd 使用官方二进制、Systemd、mTLS，数据目录与二进制分离；支持成员管理、健康检查、快照和恢复演练。成员变更不得清空数据目录。API Server 启用 TLS、RBAC、Node authorizer、关闭匿名访问和可配置审计。

## 7. 运行时、代理与 Addons

默认 containerd + CRI + systemd cgroup；Docker 运行时必须配 cri-dockerd，每节点仅一个 CRI endpoint。HTTP registry 是明文，不得称为 TLS 信任；HTTPS 校验 CA、链和 SAN。

kube-proxy 默认 nftables，可选 ipvs/iptables；切换前预检模块/工具、备份并逐节点操作，禁止全局 flush。Calico、CoreDNS、NodeLocal DNSCache 使用本地 Chart 安装，Chart 和镜像版本必须锁定。安装后审计实际 Pod 镜像闭包。验证跨节点 Pod 网络、Service、DNS、MTU、NodePort 和网络策略。

## 8. 执行依赖

安装节点预检/制品准备 → 系统初始化 → PKI → 可选 Harbor → etcd → Runtime → 控制平面 → Worker Nginx 代理 → kubelet/kube-proxy → Addons → kubeconfig → 端到端验收。Master kubelet 同样依赖 CRI。Worker 本地 Nginx 必须早于 Worker kubelet。

## 9. 幂等、恢复、升级和清理

所有变更先备份；原子写入；集群级/节点级锁；有限重试；SSH StrictHostKeyChecking；错误保留退出码。Dry-run 严格零副作用：不创建文件/目录、不持锁、不下载、不 SSH、不改权限或系统。状态文件不是健康证据，必须查询 systemd、etcd、API、Node、Pod、网络和证书真实状态。

升级遵循 Kubernetes 官方 skew，逐 Minor；先验证 etcd 快照，HA 控制面滚动升级，Worker cordon/drain。二进制回滚不代表 etcd/API 数据回滚。清理默认仅停服务；删除数据必须列出目标、确认备份并二次确认。不能安全回滚时停止并给出人工恢复说明。

## 10. 验收标准

必须覆盖制品校验、RPM/Chart/镜像闭包、SSH HostKey、系统参数、etcd health/member/snapshot/restore、API livez/readyz、Node Ready、Pod 网络、DNS、Service、Harbor（启用时）、Worker localhost endpoint、Nginx 故障恢复、证书 SAN/用途/权限/轮换、dry-run 零副作用、幂等、并发和清理保护。输出文本与 JSON 报告；未运行必须标记未验证。真实 Rocky Linux 9 环境验收不可由静态检查替代。
