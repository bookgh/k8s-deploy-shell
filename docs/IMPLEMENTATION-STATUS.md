# 项目实施状态

本文区分本地工具已实现、组件部署入口已实现和真实环境已验证三种不同状态。脚本存在不代表集群功能已经可用。

## 一、里程碑状态

| 阶段 | 状态 | 已有实现与限制 |
|---|---|---|
| M0 仓库骨架 | 部分完成 | 目录、忽略规则、CI 和测试已存在；shfmt 仍以非阻断警告方式报告格式差异。 |
| M1 配置与公共库 | 部分完成 | 具备白名单、非执行式配置解析，拒绝重复/未知键，具备 IPv4 CIDR、etcd 端口/路径/日志策略和节点清单校验；更广泛的网段冲突与故障注入覆盖仍不足。 |
| M2 制品与 Caddy | 部分完成 | HTTPS TSV 清单；固定版本 Caddy 2.11.9、CFSSL 1.7.1、etcd 3.7.3 及 SHA256；具备缓存校验和受保护的 Caddy Systemd 安装入口；尚无真实 Rocky Linux 9 安装及完整 RPM/Chart/镜像依赖闭包。 |
| M3 系统与 SSH | 部分完成 | 严格 Host Key SSH 包装器、节点清单、Rocky Linux 9/amd64 只读检查和 SSH stdin PKI 分发已实现；M12 正在补充 SSH 用户/端口/超时/重试参数边界及拒绝符号链接 known_hosts 的回归测试。系统初始化 apply 仍受角色防火墙/SELinux 集成测试门禁限制。 |
| M4 PKI | 部分完成 | 三套独立根 CA、ServiceAccount 密钥对、API/控制面客户端/kubelet/etcd/front-proxy 叶证书及 SAN/EKU/密钥/有效期校验已实现；轮换、恢复和真实节点分发尚未验证。 |
| M5 etcd | 部分完成 | 固定版本 etcd 3.7.3、mTLS Systemd bootstrap、专用 etcd 身份、已有数据 fail-closed 保护、健康/成员/快照保存命令及 Bats 测试已实现；当前没有受保护的快照恢复子命令；新增了只读恢复清单校验库和 Bats 回归用例，用于校验清单字段、快照 SHA256/文件大小、集群/版本/成员拓扑及输入文件类型，并已接入 `scripts/04-deploy-etcd.sh restore-preflight --snapshot FILE --manifest FILE` 本地只读命令；尚未生成恢复清单或执行 etcdutl 内部元数据比对。真实 Rocky Linux 9 多成员 quorum、隔离恢复演练和故障恢复均未完成。 |
| M6 控制平面 | 部分完成 | API Server/controller-manager/scheduler 远程安装、admin/controller/scheduler kubeconfig、Systemd 单元和参数校验流程已实现；HA 控制面滚动部署及 API/etcd 实时集成未验证。 |
| M7 Runtime/kubelet/代理 | 部分完成 | Containerd CRI、kubelet/kube-proxy 二进制和禁用状态单元已实现；Worker 已具备 Rocky Linux 9 构建的 Nginx stream 代理部署入口，目标监听 loopback 并进行 TCP 透传；实际节点运行和故障切换未验证。协调激活 kubelet/kube-proxy 仍延后到 M8 Addons 完成后。 |
| M8 Harbor/Addons | 部分完成 | Calico 稳定 CRD/operator、CoreDNS 和 NodeLocal Chart 已锁定；Helm 3.22.1 已校验。导入前必须渲染 Chart，并将所有渲染镜像、operator 动态生成镜像（包括 sandbox pause 和 M9 BusyBox）与 OCI digest/归档锁逐项匹配。Calico/CoreDNS/NodeLocal 工作负载使用 `imagePullPolicy: Never`。真实 Rocky Linux 9 集成未验证；Harbor 和 online 镜像模式仍被阻断。 |
| M9 验收与清理 | 部分完成 | 只读集群检查及镜像锁审计可生成文本/JSON 报告；显式 `--e2e` 可测试跨节点 Pod IP、DNS、ClusterIP、Service DNS、NodePort 和 NetworkPolicy 拒绝/恢复。清理仅停止服务，数据删除仍被阻断。 |
| M10 升级与恢复 | 部分完成 | 已有单 Minor 步进升级规划器和降级保护；apply 仍受 etcd 恢复、HA 滚动升级和 Rocky Linux 9 集成测试门禁限制。 |
| M11 发布 | 部分完成 | 已有可复现、脱敏的离线包构建器和校验器；构建要求完整镜像锁和经过验证的制品缓存；不会自动创建 GitHub Release。 |
| M12 安全加固与生产验收 | 进行中 | 已开始全仓安全审查，首批完成制品缓存链接防护、回归测试和中文文档整理；完整退出条件见 `IMPLEMENTATION-PLAN.md`。 |

## 二、自动化验证记录

主分支历史提交 `61149d90791c25901a7291c28e535fa0486f5912` 曾通过 GitHub Actions run [43367793538](https://github.com/bookgh/k8s-deploy-shell/actions/runs/43367793538)：Bash 语法、ShellCheck、shfmt 报告、固定版本 CFSSL 集成测试、Calico/CoreDNS/NodeLocal Helm lint/render、上游 Chart SHA256 校验、74 项 Bats 测试和禁用语言扫描均通过。shfmt 仍为非阻断步骤。

M12 分支新增制品缓存安全回归测试后，GitHub Actions run [43371464552](https://github.com/bookgh/k8s-deploy-shell/actions/runs/43371464552) 已成功：Bash 语法、ShellCheck、CFSSL 集成、Helm/Chart 校验、79 项 Bats 测试及 Shell-only 门禁全部通过。shfmt 仍以非阻断格式报告方式运行。

etcd 3.7.3 被选为当前 etcd 3.7 补丁版本，其官方发布制品 SHA256 为 `5dfa9cc3b3ce3b4b491fbcc2057d3daa166bcc6676f743fcd20f8e5760cb9775`。kOps 的 Kubernetes 1.37 发布说明将 etcd 3.7.3 作为默认版本，这是兼容性参考，不是 Kubernetes 上游规范性版本锁定。etcd v3.7 升级指南包含破坏性变更；当前实现只负责新集群 bootstrap，不执行 etcd 升级。

## 三、真实环境验证缺口

尚未在 Rocky Linux 9 目标集群执行以下验证：

- containerd CRI Runtime、kubelet/kube-proxy 服务实际启动；
- etcd 多成员 quorum、快照校验和隔离恢复；
- Kubernetes API、控制面组件健康；
- Calico 跨节点网络、CoreDNS、NodeLocal DNSCache；
- Pod 网络、DNS、Service、NodePort 和 NetworkPolicy 端到端流量；
- Worker Nginx 故障切换与连接恢复；
- 完整离线环境部署及升级/回滚演练。

没有生成生产 CA，没有修改真实集群。

## 四、M8 实现补充

M8 包含稳定版 `crd.projectcalico.org.v1` Chart、Calico operator Chart、CoreDNS Chart、Helm 3.22.1，以及基于 Kubernetes v1.37.2 上游清单制作的本地 NodeLocal DNSCache Chart。镜像导入前，部署脚本渲染三个 Chart，检查渲染出的全部镜像、operator 生成的 Calico node/CNI/Typha 镜像、Runtime sandbox pause 镜像和 M9 测试镜像是否全部存在于 `images.lock.tsv`。Calico operator 管理的 Pod、CoreDNS、NodeLocal 和 M9 测试 Pod 使用 `imagePullPolicy: Never`。当前仅支持 `local-import`；Harbor 和 online 模式被阻断。仓库有意不提交真实 `images.lock.tsv`：使用者必须针对实际目标填写 OCI digest 并提供对应归档。M8 仍需通过 Rocky Linux 9 集群集成验收。

## 五、M9–M11 实现补充

M9 提供只读 API、etcd、节点 Ready、Calico、CoreDNS、NodeLocal DNSCache、kubelet kubeconfig endpoint、逐节点 loopback API、系统 Pod 镜像闭包及 containerd sandbox 镜像锁检查，并生成文本/JSON 报告。显式执行 `--e2e` 时，使用固定版本 BusyBox 和 `imagePullPolicy: Never` 测试跨节点 Pod IP、DNS、ClusterIP、Service DNS、NodePort 及 NetworkPolicy 拒绝/恢复；不带 `--e2e` 时相关流量检查保持 NOT_VERIFIED。清理仅停止服务，数据删除被阻断。

M10 提供单 Minor 步进升级规划器和降级保护，不执行升级。M11 提供可复现、脱敏的离线包构建器和校验器：排除 `cluster.env`、known_hosts、PKI、kubeconfig 和运行时状态；通过 `SOURCE_DATE_EPOCH` 归一化 tar 元数据；生成可移植 SHA256 sidecar，并验证归档和内部制品/镜像校验和。只有完整 `images.lock.tsv` 和已验证的制品/镜像缓存就绪后才允许构建。不会发布 Release。

## 六、M12 第一批安全修复（2026-11-13）

本轮在独立分支 `m12/hardening-and-validation` 开展代码审查，发现并修复制品缓存对符号链接和硬链接的信任问题：

- 制品下载入口拒绝符号链接缓存根目录、符号链接制品和非普通文件目标。
- 缓存验证要求缓存根目录及每个制品均为非符号链接的真实目录/普通文件，并拒绝链接计数大于 1 的硬链接制品，避免公共 HTTP 缓存通过文件链接暴露缓存目录之外的数据。
- 新增 Bats 回归用例，覆盖内容哈希正确但目标为符号链接、缓存根目录为符号链接、制品为硬链接，以及下载入口遇到符号链接时必须在网络访问前失败。

上述代码和测试已推送到 M12 开发分支。GitHub Actions run `43371464552` 成功，79 项 Bats 测试全部通过。该结果只证明 CI 环境中的自动化测试通过，不代表 Rocky Linux 9 真实部署或生产集群验收通过。

M12 本轮继续审查 M3–M7：SSH 包装器现在独立校验用户、端口、超时、重试和退避参数，并拒绝符号链接或非普通文件的 known_hosts。新增测试覆盖无网络调用的失败路径及 StrictHostKeyChecking 参数。本轮提交关联 GitHub Actions run [43380154235](https://github.com/bookgh/k8s-deploy-shell/actions/runs/43380154235) 已成功：Bash 语法、ShellCheck、shfmt 报告、CFSSL 集成、Helm/Chart 校验、83 项 Bats 测试及 Shell-only 门禁全部通过。shfmt 仍为非阻断步骤。

在 SSH 远端命令参数边界增加 Shell 元字符/空白注入回归用例后，GitHub Actions run [43380545168](https://github.com/bookgh/k8s-deploy-shell/actions/runs/43380545168) 再次成功：Bash 语法、ShellCheck、shfmt 报告、CFSSL 集成、Helm/Chart 校验、**84 项 Bats 测试**及 Shell-only 门禁全部通过。shfmt 格式差异仍以非阻断警告报告。M12 本轮继续发现远端 etcd、控制平面、kubelet/kube-proxy 和 Worker Nginx 代理安装器缺少统一节点级并发互斥；现已分别加入 `/run/lock` 下的独立 `flock` 锁，冲突时以退出码 75 失败，避免并行修改服务二进制、配置与 Systemd 单元。Runtime 安装器原有节点锁保持不变，并新增 Bats 静态回归检查。该改动关联 GitHub Actions run [43388768436](https://github.com/bookgh/k8s-deploy-shell/actions/runs/43388768436) 已成功：Bash 语法、ShellCheck、shfmt 报告、CFSSL 集成、Helm/Chart 校验、**87 项 Bats 测试**及 Shell-only 门禁全部通过；同一提交的 Kubernetes CLI flag 校验 run [43388768439](https://github.com/bookgh/k8s-deploy-shell/actions/runs/43388768439) 也已成功。前一版状态文档提交对应的 Shell CI run [43388887995](https://github.com/bookgh/k8s-deploy-shell/actions/runs/43388887995) 和 CLI flag 校验 run [43388888051](https://github.com/bookgh/k8s-deploy-shell/actions/runs/43388888051) 均已成功，87 项 Bats 全部通过。随后更新的状态文档提交对应 Shell CI run [43389067944](https://github.com/bookgh/k8s-deploy-shell/actions/runs/43389067944) 和 CLI flag 校验 run [43389067970](https://github.com/bookgh/k8s-deploy-shell/actions/runs/43389067970) 也已成功，87 项 Bats 全部通过。shfmt 仍为非阻断格式报告。后续仍需完成离线归档安全、Dry-run 零副作用、服务启动顺序、组件健康探测、备份恢复和真实集群故障演练。未执行的测试必须继续标记为未验证。

## 七、M12 Dry-run 零副作用修复（2026-11-13）

继续审查公共锁包装器时发现：ks_with_lock 在 KS_DRY_RUN=true 时虽然没有创建锁文件，却仍会执行传入的回调函数。该行为违反架构与实施提示词中“Dry-run 不执行任何变更命令”的强制要求；调用方一旦把变更函数交给公共锁包装器，就可能在预览模式下实际执行写操作。

已修复为 Dry-run 只记录“将获取锁并执行的命令”，随后直接返回成功，不创建锁文件，也不调用回调。新增 tests/common.bats 两项回归测试，分别验证 Dry-run 不执行回调/不创建锁，以及正常模式仍会执行回调并创建锁文件。

GitHub Actions Shell CI run [43390326016](https://github.com/bookgh/k8s-deploy-shell/actions/runs/43390326016) 已成功：Bash Syntax、ShellCheck、shfmt 报告、CFSSL、Helm/Chart 校验、**89 项 Bats 测试**及 Shell-only 门禁全部通过。shfmt 仍为非阻断报告步骤。该测试证明公共锁包装器的 Dry-run 行为，不替代所有部署入口的文件系统/网络系统调用级零副作用验证，也不代表真实 Rocky Linux 9 环境验收通过。


## 八、M5 恢复前置校验基础（2026-11-13）

新增 `scripts/lib/etcd-restore.sh` 中的 `ks_etcd_restore_manifest_validate` 只读校验函数、`scripts/04-deploy-etcd.sh restore-preflight --snapshot FILE --manifest FILE` 本地预检命令及 `tests/etcd-restore.bats` 回归用例。校验器要求 manifest 和 snapshot 均为普通非符号链接文件，拒绝组/其他用户可写的 manifest；严格检查 schema、必需字段、重复/未知字段、etcd 版本、集群名、成员拓扑、snapshot SHA256 和文件大小，并校验 revision/hash/cluster ID 等字段格式。

该命令不连接节点、不执行恢复、不调用 etcdutl，也不证明 manifest 的来源真实性；manifest 若由具有写权限的同一主体伪造，SHA256 本身不能建立可信来源。调用方仍必须独立执行 `etcdutl snapshot status` 并核对 revision/hash/size，检查成员状态、证书和目录空间，再进入任何后续事务。当前校验库尚未接入 `scripts/04-deploy-etcd.sh` 命令入口，也未实现 manifest 生成、远端 Prepare/Commit/Rollback。

新增 11 项 Bats 测试覆盖正常校验、哈希篡改、集群/拓扑不匹配、重复/未知字段、符号链接、文件大小不匹配及不安全权限。代码已推送至 `m12/hardening-and-validation`；Bats、ShellCheck 和 GitHub Actions 结果待本提交 CI 实际运行后更新。不得将此项基础校验描述为 etcd restore 已实现。


本节 11 项 Bats 用例在初次集成时发现测试文件重复块和缺少 `etcd.sh` 测试依赖加载；已分别清理并补齐。最近修复提交为 `a220c54e5b4f5afae3efc5118873fa69d8ca3ee8`。之前 Shell CI run #113 的失败源于上述测试夹具问题，不能作为当前代码通过证据；修复后必须以最新 CI 运行结果为准。
