# Operations guide

## Initial setup

1. Copy `cluster.env.example` to `cluster.env` and replace every example value.
2. Copy `config/nodes.tsv.example` to `config/nodes.tsv`, set every node address/SSH user/port, and update `NODE_INVENTORY_FILE` in `cluster.env`. Provision SSH host keys out of band.
3. Configure a dedicated known_hosts file; strict checking is mandatory.
4. Populate `artifacts/manifest.tsv` with immutable HTTPS URLs and independently verified SHA256 values.
5. Pin component and Helm chart versions after compatibility and image-closure validation.
6. Run `bin/install.sh --config cluster.env validate`, then `preflight` and `plan`.

## Commands

```bash
bin/install.sh --config cluster.env validate
bin/install.sh --config cluster.env preflight
bin/install.sh --config cluster.env plan
bin/install.sh --config cluster.env prepare
bin/install.sh --config cluster.env --dry-run prepare
bin/deploy-step.sh --config cluster.env --dry-run init-system
bin/deploy-step.sh --config cluster.env --dry-run pki
```

`DRY_RUN=true` is the example default and is propagated into artifact preparation and step entrypoints. The CLI `--dry-run` flag forces preview mode even if the configuration says otherwise. Dry-run must not create cache directories, lock files, temporary files, keys, or change host state.

`prepare` is the online artifact-fetch phase. It requires a complete manifest and only accepts HTTPS sources with SHA256 verification. Set `DRY_RUN=false` in `cluster.env` deliberately to download artifacts. Then run `scripts/00-prepare-install-node.sh --config cluster.env verify-cache` and review the Caddy preview. Caddy installation additionally requires `DRY_RUN=false` and explicit `--apply`. This does not authorize deploying or connecting to cluster nodes.

`--check-ssh` is a read-only target check for SSH HostKey, remote OS release and architecture. It only performs SSH when `DRY_RUN=false`; with the example default it prints the SSH plan. No remote system changes are made.

System initialization remains preview-only. PKI `--apply` generates three independent root CAs (Kubernetes, etcd, front-proxy), the separate ServiceAccount keypair, API Server certificate, control-plane client certificates, per-node kubelet client/serving certificates, per-etcd-member server/peer certificates, etcd client certificates and front-proxy client certificate. Root CA validity is `876024h`; leaf validity is `876000h`. Leaf private keys are generated locally on the installation node; secure delivery to target nodes, rotation and recovery are not yet implemented. Existing non-empty PKI is never overwritten. CA private keys remain local and must be backed up offline. Caddy deployment is guarded by an explicit apply flag and requires the installation node to be Rocky Linux 9 / x86_64. Do not bypass these guards.

## Honest status

A successful config validation or plan is not evidence of a deployed cluster. Component stages without complete implementation must fail closed. See `docs/IMPLEMENTATION-STATUS.md`.


### PKI credential delivery

The default `distribute-pki` command is preview-only. For a real transfer, provision `config/known_hosts` out of band, set `DRY_RUN=false`, then run:

```bash
bin/deploy-step.sh --config cluster.env --apply distribute-pki
```

Private keys are streamed through authenticated SSH stdin to a mode-0600 temporary file, checked remotely by SHA256, and atomically renamed. Remote PKI directories are mode 0700. SCP/SFTP/rsync and the Caddy artifact server are not used for sensitive files. Root CA private keys and the admin credential stay on the installation node.
