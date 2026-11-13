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
| M6 control plane | Not implemented | No API Server/controller/scheduler deployment, kubeconfig generation or HA validation |
| M7 runtime/kubelet/proxy | Not implemented | No containerd/kubelet/kube-proxy/Nginx failover deployment |
| M8 Harbor/Addons | Not implemented | Chart versions and image closure are unpinned |
| M9 verification/cleanup | Partial | Explicit NOT_VERIFIED response; full live checks and safe cleanup remain |
| M10 upgrade/recovery | Not implemented | No upgrade/rollback workflow |
| M11 release | Partial | CI checks only; no verified offline bundle or release workflow |

## Verification record

Commit `999f59896e68a22d786987fc83f745f967d688dc` passed GitHub Actions run [43348228075](https://github.com/bookgh/k8s-deploy-shell/actions/runs/43348228075): Bash syntax, ShellCheck, shfmt reporting, CFSSL integration tests, all 41 Bats tests (including intermediate CA issuance/chain checks), and forbidden-language scan passed. shfmt currently reports formatting differences as a warning-only step; it is not a blocking gate.

etcd 3.7.3 was selected as the current etcd 3.7 patch release. Its official release asset SHA256 is `5dfa9cc3b3ce3b4b491fbcc2057d3daa166bcc6676f743fcd20f8e5760cb9775`. Kubernetes 1.37 release notes for kOps state that 1.37 clusters default to etcd 3.7.3; this is compatibility evidence, not a Kubernetes upstream normative pin. The etcd v3.7 upgrade guide documents breaking changes; this implementation only bootstraps a new cluster and does not perform upgrades.

No Rocky Linux 9 target cluster, etcd quorum, snapshot restore, Kubernetes API, CNI, DNS or workload end-to-end validation was performed. No production CA was generated and no real cluster was modified.
