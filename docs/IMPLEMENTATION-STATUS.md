# Implementation status

This record distinguishes implemented local tooling from component deployment that is not yet implemented or verified. A script existing is not evidence of a working cluster.

| Area | Status | Evidence / limitation |
|---|---|---|
| M0 repository skeleton | Partial | Layout, ignore rules, CI and tests exist; shfmt still reports formatting differences as a non-blocking warning |
| M1 configuration/common library | Partial | Allowlisted non-executing parser; duplicate/unknown key rejection; IPv4 CIDR overlap and DNS membership checks; node role/etcd odd-membership validation; retry/lock/atomic-write/backup/SHA256 helpers; dry-run propagated to artifact preparation. Node IP/role/SSH inventory is now validated; full CIDR collision against node subnets, complete schema and broader concurrency/failure tests remain |
| M2 artifacts/Caddy | Partial | HTTPS-only TSV manifest with pinned Caddy 2.11.9 and CFSSL 1.7.1 assets, SHA256 verification, cache verification, Rocky 9/amd64 preflight and guarded Caddy Systemd installer. No production artifact has been downloaded or Caddy installed; RPM/Chart/image closure remains |
| M3 system/SSH | Partial | Strict HostKey SSH wrapper, node inventory, remote Rocky 9/amd64 read-only check, and SSH-stdin file delivery with remote SHA256 verification and atomic rename; no real target-node integration or Rocky 9 apply workflow |
| M4 PKI | Partial | CFSSL 1.7.1 generates three independent root CAs (876024h), ServiceAccount keypair, API Server/control-plane clients, per-node kubelet client/serving, per-etcd-member server/peer, etcd clients and front-proxy client certificates. SANs, EKUs, key matches, modes and 876000h leaf validity are verified. SSH delivery workflow is implemented but has dry-run coverage only; rotation and recovery remain |
| M5 etcd | Not implemented | No member lifecycle, systemd deployment, mTLS rollout or snapshot restore |
| M6 control plane | Not implemented | No component deployment, kubeconfig generation or HA validation |
| M7 runtime/kubelet/proxy | Not implemented | No containerd/kubelet/kube-proxy/Nginx failover deployment |
| M8 Harbor/Addons | Not implemented | Chart versions and image closure are intentionally unpinned |
| M9 verification/cleanup | Partial | Explicit NOT_VERIFIED response; live checks and safe cleanup remain |
| M10 upgrade/recovery | Not implemented | No upgrade/rollback workflow |
| M11 release | Partial | CI checks only; no verified offline bundle or release workflow |

## Verification record

GitHub Actions run for commit `b3e544c2beaaa2bf3f149605e841dceeb9630bf8`: **success**.

- Bash syntax: passed.
- ShellCheck: passed.
- Bats: passed (27 tests), including actual CFSSL 1.7.1 root/leaf certificate generation, SAN/EKU checks, key permissions, and 100-year validity in a disposable CI directory. SSH file delivery is tested in dry-run only.
- Forbidden-language file/invocation scan: passed.
- shfmt: executed and reported formatting differences; currently warning-only, not a blocking gate.

M2/M3/M4 code passed Bash syntax, ShellCheck, Bats and forbidden-language scan. The CI PKI integration test downloads the pinned CFSSL binaries, verifies their SHA256, generates throwaway CA material in the runner, and does not touch a real cluster. No Rocky Linux 9 target host, SSH node inventory, certificate issuance, etcd restore, container runtime, Kubernetes API, CNI, DNS or workload end-to-end validation was performed. Those remain NOT VERIFIED. No production CA was generated and no real cluster was modified.
