# Operations guide

## Initial setup

1. Copy `cluster.env.example` to `cluster.env` and replace every example value.
2. Populate the node inventory and provision SSH host keys out of band.
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

System initialization and PKI are currently preview-only. Caddy deployment is guarded by an explicit apply flag and requires the installation node to be Rocky Linux 9 / x86_64. Their `--apply` paths fail closed until their full safety checks, rollback and Rocky Linux 9 integration tests are implemented. Do not bypass these guards.

## Honest status

A successful config validation or plan is not evidence of a deployed cluster. Component stages without complete implementation must fail closed. See `docs/IMPLEMENTATION-STATUS.md`.
