# Implementation status

This record deliberately distinguishes code presence from verified functionality.

| Area | Status | Evidence / limitation |
|---|---|---|
| M0 repository skeleton | Implemented in this change | Layout, ignore rules, CI and test gates |
| M1 configuration/common library | Partial | Safe KEY=VALUE parser and validation; more schema and Bats coverage required |
| M2 artifacts/Caddy | Partial | Manifest validation/fetch and Caddy example; no verified artifact closure is supplied |
| M3 system/SSH | Partial | Strict SSH wrapper and guarded system initialization; Rocky 9 integration remains untested |
| M4 PKI | Partial | CA bootstrap only; leaf profiles, SAN inventory, rotation and recovery remain |
| M5 etcd | Not implemented | No member lifecycle, systemd deployment or snapshot restore |
| M6 control plane | Not implemented | No control-plane deployment or HA validation |
| M7 runtime/kubelet/proxy | Not implemented | No containerd/kubelet/kube-proxy/Nginx failover deployment |
| M8 Harbor/Addons | Not implemented | Chart versions and image closure remain unpinned |
| M9 verification/cleanup | Partial | Non-verified report only; live checks and safe cleanup remain |
| M10 upgrade/recovery | Not implemented | No upgrade/rollback workflow |
| M11 release | Partial | CI checks only; no verified offline bundle |

## Verification record

Local checks performed in authoring environment:

- `bash -n` on project shell scripts: passed.
- Config example parse/validation: passed.
- Unsafe shell-substitution rejection: passed; no command executed.
- Manifest rejection of HTTP source: passed.
- Read-only plan and system-init preview: passed.

ShellCheck, shfmt and Bats are not installed in the authoring environment; CI installs and runs them. Rocky Linux 9 integration, SSH access, certificate issuance, etcd restore and full cluster deployment have not been run. These are NOT VERIFIED.
