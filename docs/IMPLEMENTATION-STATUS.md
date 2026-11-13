# Implementation status

This record distinguishes implemented local tooling from component deployment that is not yet implemented or verified. A script existing is not evidence of a working cluster.

| Area | Status | Evidence / limitation |
|---|---|---|
| M0 repository skeleton | Partial | Layout, ignore rules, CI and tests exist; shfmt still reports formatting differences as a non-blocking warning |
| M1 configuration/common library | Partial | Allowlisted non-executing parser; duplicate/unknown key rejection; IPv4 CIDR checks; etcd ports/paths/log policy; node inventory validation; broader subnet collision and failure-injection coverage remain |
| M2 artifacts/Caddy | Partial | HTTPS-only TSV manifest; pinned Caddy 2.11.9, CFSSL 1.7.1 and etcd 3.7.3 artifacts with SHA256; cache verification and guarded Caddy Systemd installer; no real Rocky 9 installation or full RPM/Chart/image closure |
| M3 system/SSH | Partial | Strict HostKey SSH wrapper, node inventory, remote Rocky 9/amd64 read-only check, SSH-stdin PKI delivery; system initialization apply remains blocked pending role firewall/SELinux integration tests |
| M4 PKI | Partial | Three independent root CAs, ServiceAccount keypair, API/control-plane/kubelet/etcd/front-proxy leaf certificates, SAN/EKU/key/validity checks; rotation/recovery and real-node distribution not validated |
| M5 etcd | Partial | Pinned etcd 3.7.3 binary, mTLS Systemd bootstrap, dedicated etcd identity, existing-data fail-closed guard, health/member-list/snapshot commands and Bats coverage; real Rocky 9 multi-member quorum, snapshot restore and failure recovery remain NOT VERIFIED |
| M6 control plane | Partial | API Server/controller-manager/scheduler remote installation, generated admin/controller/scheduler kubeconfigs, systemd units and flag-validation workflow exist; HA control-plane rollout and live API/etcd integration remain NOT VERIFIED |
| M7 runtime/kubelet/proxy | Partial | Containerd/runc/CNI CRI, kubelet/kube-proxy binaries and disabled units, plus Rocky 9-built Nginx stream proxy on Workers with loopback-only TCP passthrough. Coordinated kubelet/kube-proxy activation is deferred until M8 add-ons are installed |
| M8 Harbor/Addons | Partial | Stable Calico CRDs/operator, CoreDNS and NodeLocal charts are pinned; Helm 3.22.1 is verified. Before import, charts are rendered and every emitted plus operator-generated image (including sandbox pause and M9 BusyBox) must match the OCI digest/archive lock. Calico/CoreDNS/NodeLocal workload pull policies are Never. Real Rocky 9 integration remains unverified; Harbor and online image modes remain blocked |
| M9 verification/cleanup | Partial | Read-only live checks and system image-lock audit write text+JSON reports; explicit --e2e tests cross-node Pod IP, DNS, ClusterIP, Service DNS, NodePort and NetworkPolicy deny/recovery. Cleanup is stop-only; data deletion is blocked |
| M10 upgrade/recovery | Partial | One-minor-step upgrade planner and downgrade guard exist; apply remains blocked pending etcd restore, HA rolling-upgrade and Rocky 9 integration tests |
| M11 release | Partial | Reproducible sanitized offline bundle builder and verifier exist; apply requires a complete image lock and verified artifact cache. No GitHub Release is created automatically |

## Verification record

Commit `61149d90791c25901a7291c28e535fa0486f5912` passed GitHub Actions run [43367793538](https://github.com/bookgh/k8s-deploy-shell/actions/runs/43367793538): Bash syntax, ShellCheck, shfmt reporting, pinned CFSSL integration tests, Helm lint/render of Calico/CoreDNS/NodeLocal charts, upstream chart SHA256 checks, all 74 Bats tests, and forbidden-language scan passed. shfmt still reports formatting differences as a warning-only step; it is not a blocking gate.

etcd 3.7.3 was selected as the current etcd 3.7 patch release. Its official release asset SHA256 is `5dfa9cc3b3ce3b4b491fbcc2057d3daa166bcc6676f743fcd20f8e5760cb9775`. Kubernetes 1.37 release notes for kOps state that 1.37 clusters default to etcd 3.7.3; this is compatibility evidence, not a Kubernetes upstream normative pin. The etcd v3.7 upgrade guide documents breaking changes; this implementation only bootstraps a new cluster and does not perform upgrades.

No Rocky Linux 9 target cluster, containerd CRI runtime, kubelet/kube-proxy service startup, etcd quorum, snapshot restore, Kubernetes API, CNI, DNS or workload end-to-end validation was performed. No production CA was generated and no real cluster was modified.


## M8 implementation note — 2026-11-13

M8 now includes the stable `crd.projectcalico.org.v1` chart, Calico operator chart, CoreDNS chart, Helm 3.22.1 and a local NodeLocal DNSCache chart based on the Kubernetes v1.37.2 upstream manifest. Before import, the deployment script renders all three charts, checks every rendered image plus the operator-generated Calico node/CNI/Typha set, runtime sandbox pause image and M9 test image against `images.lock.tsv`, and imports only SHA256-verified archives through the installation node. Calico operator-managed pods, CoreDNS, NodeLocal and M9 test pods use `imagePullPolicy: Never`. The script supports only `local-import`; Harbor and online modes remain blocked. A real `images.lock.tsv` is intentionally not committed: users must populate OCI digests and matching archives for the exact target. M8 remains partial until Rocky Linux 9 cluster integration passes.


## M9–M11 implementation note — 2026-11-13

M9 now provides read-only API, etcd, node readiness, Calico, CoreDNS, NodeLocal DNSCache, kubelet kubeconfig endpoint, per-node loopback API, system-pod image-lock closure and containerd sandbox-image lock checks with text/JSON reports. Explicit --e2e uses a pinned BusyBox image with imagePullPolicy Never to test cross-node Pod IP, DNS, ClusterIP, Service DNS, NodePort and NetworkPolicy deny/recovery; without --e2e those traffic checks remain NOT_VERIFIED. Cleanup is stop-only; data deletion is blocked.

M10 provides a one-minor-step upgrade planner and downgrade guard. It does not execute upgrades. M11 provides a reproducible sanitized bundle builder and verifier. It excludes cluster.env, known_hosts, PKI, kubeconfigs and runtime state, normalizes tar metadata with SOURCE_DATE_EPOCH, emits a portable SHA256 sidecar and validates the archive and embedded artifact/image checksums. Bundle creation remains blocked until a complete images.lock.tsv and verified artifact/image cache exist. No release is published.

## M12 安全加固与验证记录（2026-11-13）

本轮在独立分支 `m12/hardening-and-validation` 开展代码审查。已发现并修复制品缓存对符号链接的信任问题：

- 制品下载入口拒绝符号链接缓存根目录、符号链接目标和非普通文件目标，避免校验后仍将缓存外文件当作可信制品。
- 制品缓存验收要求缓存根目录及每个制品均为非符号链接的真实目录/普通文件。
- 新增 Bats 回归用例，覆盖内容哈希正确但目标为符号链接，以及缓存根目录本身为符号链接两种情况。

本轮验证边界：
- 上述修改已推送至 M12 开发分支。GitHub Actions run `43371464552` 已完成且结论为 success：Bash 语法、ShellCheck、CFSSL 集成、Helm/Chart 校验、全部 79 项 Bats 测试及 Shell-only 门禁均通过；新增的符号链接与硬链接回归测试均已包含在 79 项测试中。shfmt 步骤仍为非阻断格式报告。
- 尚未在 Rocky Linux 9 amd64 真实节点执行安装、升级、etcd 恢复、CNI、DNS、网络策略和离线部署演练。
- M0–M11 仍按各自现有证据标记为部分完成；本轮不把静态测试或代码审查替代真实集群验收。
- 未生成生产 CA、未连接或修改任何真实集群、未发布 Release。

后续 M12 必须继续检查离线归档解包安全、Dry-run 零副作用、远端命令参数边界、服务启动顺序、组件健康探测和恢复演练，并以实际 CI 与 Rocky Linux 9 集成证据更新状态。
