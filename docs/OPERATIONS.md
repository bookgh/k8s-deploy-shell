# 运维操作指南

## 一、初始化配置

1. 复制 `cluster.env.example` 为 `cluster.env`，逐项替换所有示例值。
2. 将 `CONTROL_PLANE_ENDPOINT` 设置为外部 L4 VIP/负载均衡器 DNS 名称；非 HA 集群可设置为单个 Master 地址。将 `CONTROL_PLANE_PORT` 设置为 API 端口。该入口会写入 API Server 证书 SAN。
3. 复制 `config/nodes.tsv.example` 为 `config/nodes.tsv`，填写每个节点的地址、SSH 用户和端口，并在 `cluster.env` 中更新 `NODE_INVENTORY_FILE`。节点 SSH Host Key 必须通过带外可信渠道获取。
4. 配置专用的 known_hosts 文件；必须启用严格 Host Key 校验。
5. 在 `artifacts/manifest.tsv` 中填写不可变 HTTPS 地址及独立核验的 SHA256。
6. 完成兼容性和镜像闭包验证后，锁定组件及 Helm Chart 版本。
7. 依次执行 `bin/install.sh --config cluster.env validate`、`preflight` 和 `plan`。

## 二、常用命令

```bash
bin/install.sh --config cluster.env validate
bin/install.sh --config cluster.env preflight
bin/install.sh --config cluster.env plan
bin/install.sh --config cluster.env prepare
bin/install.sh --config cluster.env --dry-run prepare
bin/deploy-step.sh --config cluster.env --dry-run init-system
bin/deploy-step.sh --config cluster.env --dry-run pki
bin/deploy-step.sh --config cluster.env --dry-run distribute-pki
bin/deploy-step.sh --config cluster.env --dry-run etcd
bin/deploy-step.sh --config cluster.env etcd-health
bin/deploy-step.sh --config cluster.env etcd-members
bin/deploy-step.sh --config cluster.env etcd-snapshot
```

示例配置默认 `DRY_RUN=true)，并将该设置传递给制品准备和部署步骤入口。命令行 `--dry-run` 可强制进入预览模式。Dry-run 不得创建缓存目录、锁文件、临时文件或密钥，不得建立 SSH 连接，也不得修改主机状态。

`prepare` 是在线制品获取阶段，要求制品清单完整，只接受 HTTPS 来源并执行 SHA256 校验。只有明确设置 `DRY_RUN=false` 才会下载制品。完成后执行 `scripts/00-prepare-install-node.sh --config cluster.env verify-cache`，并检查 Caddy 配置预览。安装 Caddy 同样要求 `DRY_RUN=false` 和显式 `--apply`。

系统初始化当前仅提供预览入口。PKI 生成会创建三个相互独立的根 CA，以及独立的 ServiceAccount 密钥对。已有非空 PKI 目录不会被覆盖。叶证书私钥仅通过严格 Host Key 校验的 SSH stdin 分发，不会暴露在 Caddy 服务中。

## 三、etcd（M5）

etcd 二进制固定为 v3.7.3，并校验上游 GitHub Release 制品摘要。`versions.yaml` 与 `artifacts/manifest.tsv` 必须保持一致。部署 etcd 前必须满足：

- 目标节点为 Rocky Linux 9 / x86_64，且位于配置的 etcd 成员清单中。
- 已成功生成 PKI 并完成 `distribute-pki`。
- Caddy 制品服务已启动，本地缓存已经校验。
- 已设置 `DRY_RUN=false`，配置专用 known_hosts 文件，并显式传入 `--apply`。

先预览：

```bash
bin/deploy-step.sh --config cluster.env --dry-run etcd
```

只有在审核部署计划，并确认这是一个全新集群且 etcd 数据目录为空之后，才允许执行：

```bash
bin/deploy-step.sh --config cluster.env --apply etcd
bin/deploy-step.sh --config cluster.env etcd-health
bin/deploy-step.sh --config cluster.env etcd-members
bin/deploy-step.sh --config cluster.env etcd-snapshot
```

安装程序拒绝在非空数据目录或活动成员不匹配的情况下初始化集群。它不会自动添加/删除成员，也不会自动恢复快照。快照文件暂存在 etcd 成员的 `ETCD_BACKUP_DIR`；必须将其复制到独立管理的加密备份存储，并在隔离环境中进行恢复测试。Systemd 启动成功不代表 quorum 已建立，必须使用 `etcd-health` 和 `etcd-members` 检查。

## 四、如实报告实施状态

配置校验或部署计划成功，不代表集群已经部署成功。请查阅 `docs/IMPLEMENTATION-STATUS.md`。M5 代码尚未在真实 Rocky Linux 9 多成员集群上完成验证。

## 五、容器运行时部署（M7，部分完成）

当前 Runtime 阶段仅支持 **containerd**。containerd 静态归档、runc 二进制和 CNI 插件归档均通过 `versions.yaml` 与 `artifacts/manifest.tsv` 锁定。安装程序在解包前校验归档 SHA256，配置 containerd v3、systemd cgroup 驱动，并将 CRI 插件指向已配置的 CNI 目录。

1. 复制 `cluster.env.example` 为 `cluster.env`，审核节点清单和所有目录路径。
2. 确认制品缓存包含三个 Runtime 归档，且 Caddy HTTP 服务使用相同缓存根目录。
3. 确认每个目标节点的 SSH Host Key 已存在于指定 known_hosts 文件中。目标系统必须为 Rocky Linux 9 x86_64，并具备 root SSH 权限或免交互 sudo 权限。
4. 执行只读预览：

   ```bash
   bin/deploy-step.sh runtime --config cluster.env --dry-run
   ```

5. 如需实际部署，必须在 `cluster.env` 中显式设置 `DRY_RUN=false)，然后执行：

   ```bash
   bin/deploy-step.sh runtime --config cluster.env --apply
   ```

该阶段不会拉取容器镜像、配置 Calico、启动 kubelet/kube-proxy，也不会安装 Worker Nginx stream 代理。pause 镜像已在 `versions.yaml` 中锁定，启动工作负载前必须将其纳入后续经过校验的镜像导入闭包。安装程序拒绝替换内容不同的现有 containerd 二进制或配置；升级必须走独立升级流程。

## 六、kubelet 与 kube-proxy 准备（M7，部分完成）

containerd Runtime 和 PKI 分发完成后，可准备 kubelet、kube-proxy 二进制及逐节点凭据：

```bash
bin/deploy-step.sh --config cluster.env --dry-run kubelet-proxy
```

实际执行要求 `DRY_RUN=false)、本地 `kubectl` 已校验、Caddy 缓存中存在锁定版本的 kubelet/kube-proxy 制品，并且节点证书已通过 `distribute-pki` 分发。kubelet 身份必须匹配 `system:node:<node>` / `system:nodes`；kube-proxy 身份必须匹配 `system:kube-proxy` / `system:node-proxier`。生成的 kubeconfig 内嵌客户端凭据，只能通过已验证的 SSH 通道传输，不能放入公开制品 HTTP 根目录。

两个 kubeconfig 的 API 地址均为 `https://127.0.0.1:<CONTROL_PLANE_PORT>`。Worker 在本地 Nginx stream 代理部署前无法使用该地址。此阶段只安装二进制和处于 disabled 状态的 Systemd 单元，不会 enable 或 start kubelet/kube-proxy。Worker 代理和节点服务激活阶段完成前，不得启动这两个服务。

## 七、Nginx Worker API 代理（M7，部分完成）

在 Rocky Linux 9 x86_64 安装节点上，根据锁定的官方源码归档构建仅启用 stream 的 Nginx 二进制：

```bash
bin/deploy-step.sh --config cluster.env --dry-run build-nginx
```

审核计划后，在 `cluster.env` 中设置 `DRY_RUN=false)，再执行 `bin/deploy-step.sh --config cluster.env --apply build-nginx`。生成的归档及其 SHA256/来源记录写入仅保留在本地的 `state/generated-artifacts.tsv`。

然后向 Worker 部署代理：

```bash
bin/deploy-step.sh --config cluster.env --dry-run worker-proxy
bin/deploy-step.sh --config cluster.env --apply worker-proxy
```

Worker 监听地址限制为 `127.0.0.1:<CONTROL_PLANE_PORT>`。Nginx 使用 stream TCP 透传，API Server TLS 保持端到端；上游为配置的 Master IP。开源 Nginx 在此处只提供被动连接失败处理，不假设存在主动健康检查指令。该阶段会 enable 并启动代理服务，但 kubelet/kube-proxy 仍保持禁用，直到 M8 Addons 阶段和显式节点激活步骤完成。

## 八、Addons（M8，部分完成且受门禁保护）

M8 使用固定版本 Chart 和本地 NodeLocal DNSCache Chart。当前仅支持 `IMAGE_MODE=local-import`；Harbor 和在线镜像模式被有意阻断。Calico 3.33 要求镜像锁至少包含 operator（`quay.io/tigera/operator:v1.44.0`）、`quay.io/calico/calico:v3.33.0`、`quay.io/calico/node:v3.33.0`、`quay.io/calico/third-party-cni-plugins:v3.33.0` 和 `quay.io/calico/typha:v3.33.0`。还必须锁定 `versions.yaml` 中的 Runtime sandbox 镜像（`registry.k8s.io/pause:3.10.1`）和 M9 测试镜像（`docker.io/library/busybox:1.37.0`）。稳定版 CRD 包为 `crd.projectcalico.org.v1`。operator 管理的 Pod 设置 `Installation.imagePullPolicy: Never`；CoreDNS、NodeLocal 和 M9 测试 Pod 在归档导入后同样使用 `Never`。

只有在渲染全部 Chart 并审计所有 operator 动态生成镜像后，才可创建 `images.lock.tsv`。每行必须包含 repository:tag、OCI digest、归档文件名、归档 SHA256 和 linux/amd64 平台。将校验后的归档复制到 Caddy 缓存，然后执行：

```bash
bin/deploy-step.sh --config cluster.env --dry-run addons
bin/deploy-step.sh --config cluster.env addons verify
```

只有完成完整镜像闭包审计、审核部署计划、确认 Chart 兼容性并设置 `DRY_RUN=false` 后，才允许执行 `bin/deploy-step.sh --config cluster.env --apply addons`。该流程会先激活 kubelet，再引导 Calico；Calico 状态变为 Available 后才启动 kube-proxy，随后安装 CoreDNS 和 NodeLocal DNSCache。该流程尚未在真实 Rocky Linux 9 集群验证；M9 验收通过前不得视为可用于生产。

## 九、M9 集群验收报告（只读）

仅当集群已按计划启动且允许执行认证检查时，才设置 `DRY_RUN=false)，然后运行：

```bash
bin/deploy-step.sh --config cluster.env verify
```

检查器会在 `output/reports` 下写入权限为 0600 的文本和 JSON 报告，并验证系统命名空间 Pod 镜像引用是否全部包含在 digest/归档锁中。执行显式 E2E 测试前，先在 `images.lock.tsv` 中锁定并导入 `m9-test-busybox`（`docker.io/library/busybox:1.37.0`），再执行 `scripts/10-cluster-check.sh --config cluster.env --e2e`。该命令会创建临时命名空间和两个调度到不同节点、使用 `imagePullPolicy: Never` 的 Pod，测试 Pod IP 通信、DNS、ClusterIP、Service DNS、NodePort 和 NetworkPolicy 拒绝/恢复，并在退出时安排删除临时命名空间。不带 `--e2e` 时，这些项目保持 NOT_VERIFIED，总体状态为 PARTIAL。

## 十、清理（仅停止服务）

使用 `bin/deploy-step.sh --config cluster.env cleanup` 预览清理计划。若要停止 Kubernetes 服务，必须设置 `DRY_RUN=false)，并显式向 `scripts/13-clean-cluster.sh stop` 传入 `--apply`。清理命令不会删除 etcd、containerd、PKI、kubeconfig、Harbor 或工作负载数据。`delete-data` 当前被阻断。

## 十一、升级规划与离线包

使用 `bin/deploy-step.sh --config cluster.env upgrade-plan` 预览升级顺序；针对指定目标版本，可直接向 `scripts/14-upgrade.sh` 传入 `--target-version vX.Y.Z`。在 Rocky Linux 9 HA、恢复和回滚测试完成前，实际升级执行保持阻断。

使用 `bin/deploy-step.sh --config cluster.env bundle` 预览离线包要求。创建离线包必须设置 `DRY_RUN=false)、显式传入 `--apply)，并提供完整的 `images.lock.tsv`、已验证的制品缓存，以及不含符号链接和敏感文件的缓存目录。构建器使用 `SOURCE_DATE_EPOCH` 归一化归档 mtime（默认采用源提交时间），生成相对路径 SHA256 sidecar，并在报告成功前调用 `scripts/16-verify-offline-bundle.sh`。传输后使用 `scripts/16-verify-offline-bundle.sh /path/to/bundle.tar.gz` 验证。离线包排除集群密钥，不会自动发布 GitHub Release。
