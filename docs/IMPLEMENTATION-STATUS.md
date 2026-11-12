# Implementation status

This record distinguishes implemented local tooling from component deployment that is not yet implemented or verified. A script existing is not evidence of a working cluster.

| Area | Status | Evidence / limitation |
|---|---|---|
| M0 repository skeleton | Partial | Layout, ignore rules, CI and tests exist; shfmt still reports formatting differences as a non-blocking warning |
| M1 configuration/common library | Partial | Allowlisted non-executing parser; duplicate/unknown key rejection; IPv4 CIDR overlap and DNS membership checks; node role/etcd odd-membership validation; retry/lock/atomic-write/backup/SHA256 helpers; dry-run propagated to artifact preparation. Node IP inventory, complete schema and broader concurrency/failure tests remain |
| M2 artifacts/Caddy | Partial | HTTPS-only TSV manifest with immutable asset metadata, GitHub asset SHA256 for Caddy 2.11.9, cache verification, Rocky 9/amd64 preflight and guarded Caddy Systemd installer. No artifact has been downloaded or Caddy installed; RPM/Chart/image closure remains |
| M3 system/SSH | Partial | Strict HostKey SSH wrapper and preview-only system-init entrypoint; no Rocky 9 apply workflow or target integration |
| M4 PKI | Partial | Safe preview entrypoint; actual CA and leaf certificate issuance, SAN profiles, rotation and recovery remain blocked |
| M5 etcd | Not implemented | No member lifecycle, systemd deployment, mTLS rollout or snapshot restore |
| M6 control plane | Not implemented | No component deployment, kubeconfig generation or HA validation |
| M7 runtime/kubelet/proxy | Not implemented | No containerd/kubelet/kube-proxy/Nginx failover deployment |
| M8 Harbor/Addons | Not implemented | Chart versions and image closure are intentionally unpinned |
| M9 verification/cleanup | Partial | Explicit NOT_VERIFIED response; live checks and safe cleanup remain |
| M10 upgrade/recovery | Not implemented | No upgrade/rollback workflow |
| M11 release | Partial | CI checks only; no verified offline bundle or release workflow |

## Verification record

GitHub Actions run for commit `601c98f2e8aa8d0e35d57837e79e17f6cd8452c1`: **success**.

- Bash syntax: passed.
- ShellCheck: passed.
- Bats: passed (16 tests).
- Forbidden-language file/invocation scan: passed.
- shfmt: executed and reported formatting differences; currently warning-only, not a blocking gate.

The M2 installer scripts are being added in the current development series; their first CI result is pending. No Rocky Linux 9 target host, SSH node inventory, certificate issuance, etcd restore, container runtime, Kubernetes API, CNI, DNS or workload end-to-end validation was performed. Those remain NOT VERIFIED. No production CA was generated and no real cluster was modified.
