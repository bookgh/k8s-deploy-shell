# k8s-deploy-shell

基于 Bash 的 Kubernetes 官方二进制部署框架。目标 Rocky Linux 9 / amd64 / Kubernetes v1.37.2。项目支持在线准备制品、离线交付和离线部署；安装节点是唯一编排入口。

## 原则

- 官方二进制、RPM、Helm Chart、镜像归档和 Systemd。
- SSH 执行远程命令，安装节点 Caddy HTTP 提供非敏感制品。
- 不使用 kubeadm/k3s/RKE/Ansible/SaltStack；不使用 SCP/SFTP/rsync。
- Shell-only：禁止 Python、Perl、Ruby、Node.js、Go 承担项目逻辑。
- Worker kubeconfig API endpoint 必须为 https://127.0.0.1:6443。
- 部署阶段不访问公网；配置驱动版本、IP、CIDR、端口、目录和镜像。
- 幂等、可审计、可恢复；以真实健康状态验收。

## 文档

- ARCHITECTURE.md：目标架构、安全、组件、网络和依赖。
- IMPLEMENTATION-PROMPT.md：编码代理强制约束。
- IMPLEMENTATION-PLAN.md：M0–M11 阶段和退出条件。
- docs/IMPLEMENTATION-STATUS.md：已实现、部分实现、未实现和验证记录。
- docs/OPERATIONS.md：初始配置与命令。
- docs/SECURITY.md：安全模型。

## 初始化

```bash
cp cluster.env.example cluster.env
bin/install.sh --config cluster.env validate
bin/install.sh --config cluster.env plan
```

`CONTROL_PLANE_ENDPOINT` 配置外部 API 入口（HA 时应指向 L4 VIP/LB），`KUBERNETES_CONFIG_DIR`、`KUBERNETES_LOG_DIR`、`KUBERNETES_DATA_DIR` 和 `KUBERNETES_BIN_DIR` 配置远端路径。节点地址、角色、SSH 用户和端口由 `config/nodes.tsv` 维护；先复制 `config/nodes.tsv.example` 并更新 `NODE_INVENTORY_FILE`。示例配置默认 `DRY_RUN=true`。制品准备也默认只输出下载计划；只有显式设置 `DRY_RUN=false` 才会下载。命令行 `--dry-run` 可强制预览。

M2 包含安装节点预检、制品清单校验和受保护的 Caddy Systemd 安装入口；M3 包含基于节点清单的 SSH/OS 只读预检和 PKI 安全分发；M4 包含 PKI 生成。M5 增加 etcd 3.7.3 的新集群部署、mTLS、Systemd、健康/成员检查和快照入口。M6 增加 API Server、controller-manager、scheduler 的二进制/Systemd 安装和 kubeconfig 生成入口。M7 已增加 containerd/runc/CNI 远程 CRI 安装、kubelet/kube-proxy 二进制、逐节点 kubeconfig 与禁用状态的 systemd 单元；Worker Nginx stream 代理和服务激活仍未完成。etcd 现有数据目录默认 fail-closed，不执行隐式成员变更或恢复。

## etcd M5 使用顺序

```bash
bin/install.sh --config cluster.env prepare
scripts/00-prepare-install-node.sh --config cluster.env verify-cache
# 启动/确认 Caddy 后：
bin/deploy-step.sh --config cluster.env --dry-run pki
bin/deploy-step.sh --config cluster.env --dry-run distribute-pki
bin/deploy-step.sh --config cluster.env --dry-run etcd
```

真实部署必须先完成节点/HostKey/PKI 检查，并显式设置 `DRY_RUN=false`、传入 `--apply`。不得在已有 etcd 数据目录上运行新集群初始化。

## 安全与状态

默认保留 SELinux Enforcing，不全局关闭防火墙、不 flush 规则。已有 PKI/etcd/业务数据不得覆盖或删除。私钥不进入 Git 或 HTTP 根目录。真实 Rocky Linux 9 集群验证、etcd quorum 和快照恢复尚未完成；请以 docs/IMPLEMENTATION-STATUS.md 为准。

## M6/M7 当前命令入口

先确保制品缓存与 Caddy HTTP 服务就绪，并完成 SSH HostKey、节点清单、PKI 和 etcd 前置检查。示例配置默认 `DRY_RUN=true`，预览命令不会连接节点或更改主机：

```bash
bin/deploy-step.sh --config cluster.env --dry-run control-plane
bin/deploy-step.sh --config cluster.env --dry-run runtime
```

实际执行前必须人工确认配置并设置 `DRY_RUN=false`。M6 控制平面部署要求 etcd 健康且 PKI 已安全分发；M7 runtime 当前只部署 containerd CRI 和 CNI 基础插件，不会启动 kubelet/kube-proxy，也不会安装 Worker 本地 API Nginx 代理。M7 的完整状态和限制见 `docs/IMPLEMENTATION-STATUS.md`。

当前 M7 可预览的节点组件准备命令：

```bash
bin/deploy-step.sh --config cluster.env --dry-run kubelet-proxy
```

该步骤不会启动 kubelet/kube-proxy；必须等 Worker 本地 API stream 代理部署完成后再激活。

### M7 Worker API proxy

The Nginx stream binary is built from a SHA256-pinned official source archive on Rocky Linux 9 x86_64. Worker proxy listeners bind only to `127.0.0.1:<CONTROL_PLANE_PORT>` and pass TCP through to configured Masters; API TLS is not terminated by Nginx. Active health checks are not claimed.


## M8 Addons (partial)

Chart versions are pinned in `charts.yaml`: Calico/Tigera 3.33.0 (Kubernetes 1.37 tested, unified `quay.io/calico/calico` image and `projectcalico.org.v3` CRDs), CoreDNS chart 1.48.2 and the local NodeLocal DNSCache chart aligned to Kubernetes v1.37.2. Helm is pinned to v3.22.1 because the current Calico Helm installation guide specifies Helm 3. M8 currently supports only `IMAGE_MODE=local-import`. Before applying, create `images.lock.tsv` from `images.lock.tsv.example`, populate the complete chart-rendered and operator-generated image set with OCI digests and SHA256-verified archives, and place the archives in the Caddy cache. The script intentionally refuses to apply with an incomplete or missing image lock. Preview with `bin/deploy-step.sh --config cluster.env --dry-run addons`.


## Verification, cleanup, upgrade and packaging

- M9: `bin/deploy-step.sh --config cluster.env verify` writes text/JSON reports. End-to-end Pod/Service/DNS checks remain NOT_VERIFIED until a dedicated pinned test image/workload is available.
- Cleanup: `bin/deploy-step.sh --config cluster.env cleanup` previews stop-only actions. Data deletion is blocked.
- M10: `bin/deploy-step.sh --config cluster.env upgrade-plan` previews a one-minor-step upgrade; apply is blocked pending integration tests.
- M11: `bin/deploy-step.sh --config cluster.env bundle` previews a sanitized offline bundle. Building requires a complete image lock and verified cache; no release is published.
