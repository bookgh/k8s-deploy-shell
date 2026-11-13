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
| M8 Harbor/Addons | Partial | Calico 3.33.0 (Kubernetes 1.37 tested; stable crd.projectcalico.org.v1 CRD chart and pinned operator/node/CNI/typha images), CoreDNS 1.48.2 and a Kubernetes v1.37.2-derived NodeLocal DNSCache chart are pinned; Helm 3.22.1 and an image-lock/import path exist. Apply is fail-closed until the full rendered/operator image closure and archive lock are populated and Rocky 9 integration is validated. Harbor and online image modes remain blocked |
| M9 verification/cleanup | Partial | Read-only live checks write text+JSON reports; explicit --e2e creates temporary cross-node BusyBox pods to test Pod IP, DNS, ClusterIP, Service DNS and NodePort. Cleanup is stop-only; data deletion is blocked |
| M10 upgrade/recovery | Partial | One-minor-step upgrade planner and downgrade guard exist; apply remains blocked pending etcd restore, HA rolling-upgrade and Rocky 9 integration tests |
| M11 release | Partial | Sanitized offline bundle builder and verifier exist; apply requires a complete image lock and verified artifact cache. No GitHub Release is created automatically |

## Verification record

Commit `999f59896e68a22d786987fc83f745f967d688dc` passed GitHub Actions run [43348228075](https://github.com/bookgh/k8s-deploy-shell/actions/runs/43348228075): Bash syntax, ShellCheck, shfmt reporting, CFSSL integration tests, all 41 Bats tests (including intermediate CA issuance/chain checks), and forbidden-language scan passed. shfmt currently reports formatting differences as a warning-only step; it is not a blocking gate.

etcd 3.7.3 was selected as the current etcd 3.7 patch release. Its official release asset SHA256 is `5dfa9cc3b3ce3b4b491fbcc2057d3daa166bcc6676f743fcd20f8e5760cb9775`. Kubernetes 1.37 release notes for kOps state that 1.37 clusters default to etcd 3.7.3; this is compatibility evidence, not a Kubernetes upstream normative pin. The etcd v3.7 upgrade guide documents breaking changes; this implementation only bootstraps a new cluster and does not perform upgrades.

No Rocky Linux 9 target cluster, containerd CRI runtime, kubelet/kube-proxy service startup, etcd quorum, snapshot restore, Kubernetes API, CNI, DNS or workload end-to-end validation was performed. No production CA was generated and no real cluster was modified.


## M8 implementation note — 2026-11-13

M8 now includes immutable Calico CRD/operator and CoreDNS chart artifacts, Helm 3.22.1 (Helm 3 is required by the current Calico installation guide), a local NodeLocal DNSCache chart based on the Kubernetes v1.37.2 upstream manifest, image archive lock validation/import, and an explicit addon deployment entrypoint. The script currently supports only `local-import`; it refuses Harbor and online modes. A real `images.lock.tsv` is intentionally not committed: every rendered and operator-generated image must be independently pinned by OCI digest and paired with a SHA256-verified archive before apply. M8 remains partial until the image closure, runtime import behavior, CoreDNS/NodeLocal values, Calico bootstrap, and Rocky Linux 9 cluster integration pass.


## M9–M11 implementation note — 2026-11-13

M9 now provides read-only API, etcd, node readiness, Calico, CoreDNS, NodeLocal DNSCache, kubelet kubeconfig endpoint, per-node loopback API, system-pod image-lock closure and containerd sandbox-image lock checks with text/JSON reports. Explicit --e2e uses a pinned BusyBox image with imagePullPolicy Never to test cross-node Pod IP, DNS, ClusterIP, Service DNS, NodePort and NetworkPolicy deny/recovery; without --e2e those traffic checks remain NOT_VERIFIED. Cleanup is stop-only; data deletion is blocked.

M10 provides a one-minor-step upgrade planner and downgrade guard. It does not execute upgrades. M11 provides a sanitized bundle builder that excludes cluster.env, known_hosts, PKI, kubeconfigs and state; bundle creation remains blocked until a complete images.lock.tsv and verified artifact/image cache exist. No release is published.
