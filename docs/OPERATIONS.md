# Operations guide

## Initial setup

1. Copy `cluster.env.example` to `cluster.env` and replace example values.
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
bin/deploy-step.sh --config cluster.env init-system
bin/deploy-step.sh --config cluster.env pki
```

`prepare` is the online artifact-fetch phase and requires a complete manifest. System initialization and PKI commands are preview-only unless explicitly invoked with `--apply`. Do not use `--apply` on production hosts before reviewing backups and recovery steps.

## Honest status

A successful config validation or plan is not evidence of a deployed cluster. Component stages without complete implementation must fail closed. See `IMPLEMENTATION-STATUS.md`.
