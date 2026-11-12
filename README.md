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

    cp cluster.env.example cluster.env
    bin/install.sh --config cluster.env validate
    bin/install.sh --config cluster.env plan

填写节点地址、SSH HostKey、网络、版本和 artifact manifest 后，再按计划执行。cluster.env.example 是示例，不是可直接用于生产的配置。charts.yaml 中的空版本必须在安装前锁定。

## 目录

bin/ 为 CLI；scripts/lib/ 为 Bash 公共库；scripts/ 为步骤入口；config/ 和 templates/ 为配置模板；artifacts/ 为制品清单和缓存；pki/、output/、state/ 为运行时目录且敏感数据不入 Git；tests/ 为 Bats；.github/workflows/ 仅做 CI。

## 安全

默认保留 SELinux Enforcing，不全局关闭防火墙、不 flush 规则。已有 PKI/etcd/业务数据不得覆盖或删除。私钥不进入 Git 或 HTTP 根目录。任何危险操作必须备份、预览、显式确认。真实集群操作不在 CI 中执行。

## 状态

当前提交包含基础工程骨架和部分本地工具，不代表 Kubernetes 集群部署功能已经完成。请以 docs/IMPLEMENTATION-STATUS.md 为准。未经过 Rocky Linux 9 真实目标环境和故障恢复演练前，不得用于生产。
