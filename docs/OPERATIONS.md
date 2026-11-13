# Operations guide

## Initial setup

1. Copy `cluster.env.example` to `cluster.env` and replace every example value.
2. Set `CONTROL_PLANE_ENDPOINT` to the external L4 VIP/load-balancer DNS name (or a single Master address for non-HA) and `CONTROL_PLANE_PORT` to the API port. This endpoint is included in the API Server certificate SAN.
3. Copy `config/nodes.tsv.example` to `config/nodes.tsv`, set every node address/SSH user/port, and update `NODE_INVENTORY_FILE` in `cluster.env`. Provision SSH host keys out of band.
4. Configure a dedicated known_hosts file; strict checking is mandatory.
5. Populate `artifacts/manifest.tsv` with immutable HTTPS URLs and independently verified SHA256 values.
6. Pin component and Helm chart versions after compatibility and image-closure validation.
7. Run `bin/install.sh --config cluster.env validate`, then `preflight` and `plan`.

## Commands

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

`DRY_RUN=true` is the example default and is propagated into artifact preparation and step entrypoints. The CLI `--dry-run` flag forces preview mode. Dry-run must not create cache directories, lock files, temporary files, keys, SSH connections or host state.

`prepare` is the online artifact-fetch phase. It requires a complete manifest and only accepts HTTPS sources with SHA256 verification. Set `DRY_RUN=false` deliberately to download artifacts. Then run `scripts/00-prepare-install-node.sh --config cluster.env verify-cache` and review the Caddy preview. Caddy installation additionally requires `DRY_RUN=false` and explicit `--apply`.

System initialization remains preview-only. PKI generation creates three independent root CAs and a separate ServiceAccount keypair. Existing non-empty PKI is never overwritten. Leaf keys are delivered by strict-HostKey SSH stdin and are not exposed through Caddy.

## etcd M5

The etcd binary is pinned to v3.7.3 with the upstream GitHub release asset digest. `versions.yaml` and `artifacts/manifest.tsv` must agree. Deploying etcd requires:
- Rocky Linux 9 / x86_64 target nodes in the configured etcd member list.
- Successful PKI generation and `distribute-pki`.
- A running Caddy artifact server and verified local cache.
- `DRY_RUN=false`, a dedicated known_hosts file, and explicit `--apply`.

Preview first:

```bash
bin/deploy-step.sh --config cluster.env --dry-run etcd
```

Only after reviewing the plan and confirming this is a new cluster with empty etcd data directories:

```bash
bin/deploy-step.sh --config cluster.env --apply etcd
bin/deploy-step.sh --config cluster.env etcd-health
bin/deploy-step.sh --config cluster.env etcd-members
bin/deploy-step.sh --config cluster.env etcd-snapshot
```

The installer refuses to initialize over non-empty data directories or mismatched active members. It does not automatically add/remove members or restore snapshots. Snapshot files remain on an etcd member under `ETCD_BACKUP_DIR`; copy them to independently managed encrypted backup storage and test restore in an isolated environment. A successful systemd activation is not proof of quorum; use `etcd-health` and `etcd-members`.

## Honest status

A successful config validation or plan is not evidence of a deployed cluster. See `docs/IMPLEMENTATION-STATUS.md`. M5 code has not yet been validated on a real Rocky Linux 9 multi-member cluster.

## Container runtime deployment (M7 partial)

The runtime stage currently supports **containerd only**. It pins the static containerd archive, runc binary and CNI plugin archive through `versions.yaml` and `artifacts/manifest.tsv`. The installer validates archive SHA256 values before extraction, configures containerd v3, uses the systemd cgroup driver, and points the CRI plugin at the configured CNI directories.

1. Copy `cluster.env.example` to `cluster.env` and review the node inventory and all directory paths.
2. Confirm the artifact cache contains the three runtime archives and the Caddy HTTP service serves that same cache root.
3. Confirm every target's SSH host key is already trusted in the configured known_hosts file. Targets must be Rocky Linux 9 x86_64 and have root SSH access or non-interactive sudo.
4. Run a read-only plan:

   ```bash
   bin/deploy-step.sh runtime --config cluster.env --dry-run
   ```

5. To apply, explicitly set `DRY_RUN=false` in `cluster.env`, then run:

   ```bash
   bin/deploy-step.sh runtime --config cluster.env --apply
   ```

This stage does not pull container images, configure Calico, start kubelet/kube-proxy, or install the Worker Nginx stream proxy. The pause image is pinned in `versions.yaml` and must be included in the later verified image-import closure before workloads are started. The installer refuses to replace differing existing containerd binaries/configuration; upgrades require the separate upgrade workflow.

## Kubelet and kube-proxy preparation (M7 partial)

After the containerd runtime and PKI distribution stages are complete, prepare the kubelet and kube-proxy binaries and per-node credentials:

```bash
bin/deploy-step.sh --config cluster.env --dry-run kubelet-proxy
```

The apply path requires `DRY_RUN=false`, a verified local `kubectl`, the pinned kubelet/kube-proxy artifacts in the Caddy cache, and node certificates already distributed by `distribute-pki`. Kubelet identities are checked against `system:node:<node>` / `system:nodes`; kube-proxy uses `system:kube-proxy` / `system:node-proxier`. Generated kubeconfigs embed client credentials and are transferred only over the verified SSH channel, never through the public artifact HTTP root.

Both kubeconfigs point to `https://127.0.0.1:<CONTROL_PLANE_PORT>`. On Workers this endpoint is intentionally unusable until the local Nginx stream proxy is deployed. The stage installs binaries and disabled systemd units but does not enable or start kubelet/kube-proxy. Do not start these services until the Worker proxy and node-service activation stages are complete.
