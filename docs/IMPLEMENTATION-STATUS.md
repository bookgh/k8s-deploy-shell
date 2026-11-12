# Implementation status

This record distinguishes implemented local tooling from component deployment that is not yet implemented or verified. A script existing is not evidence of a working cluster.

| Area | Status | Evidence / limitation |
|---|---|---|
| M0 repository skeleton | Partial | Layout, ignore rules, CI and tests exist; shfmt currently reports formatting differences as a non-blocking warning |
| M1 configuration/common library | Partial | Allowlisted KEY=VALUE parser, validation, logging, retry/lock/atomic-write/SHA256 helpers; CIDR overlap and full schema validation remain |
| M2 artifacts/Caddy | Partial | TSV manifest validation/fetch and Caddy example; no populated verified manifest, Caddy service lifecycle or full dependency closure |
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

GitHub Actions run for commit cf6a172f737360a7297847a380f258d71dda8deb: **success**.

- Bash syntax: passed.
- ShellCheck: passed.
- Bats: passed.
- Forbidden-language file/invocation scan: passed.
- shfmt: executed and reported formatting differences; currently warning-only, not a blocking gate.

No Rocky Linux 9 target host, SSH node inventory, certificate issuance, etcd restore, container runtime, Kubernetes API, CNI, DNS or workload end-to-end validation was performed. Those remain NOT VERIFIED. No production CA was generated and no real cluster was modified.
