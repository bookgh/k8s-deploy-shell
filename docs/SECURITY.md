# Security model

- Config and inventory files are data, never sourced or evaluated.
- SSH requires BatchMode and StrictHostKeyChecking with a dedicated known_hosts file.
- The artifact HTTP root contains non-secret immutable artifacts only.
- Private keys and kubeconfigs must never enter Git, logs or the HTTP root.
- Existing non-empty CA/PKI directories cause a hard failure; no overwrite is implicit.
- Kubernetes, etcd and front-proxy root CAs are separate; ServiceAccount signing key is independent.
- Root CA validity is 876024h so it outlives 876000h leaf certificates by 24 hours.
- Root CA, leaf and ServiceAccount private keys are mode 0600 under a mode 0700 PKI directory; public HTTP cache is a separate path.
- Leaf private keys are generated on the installation node and must be delivered only over authenticated SSH; never place them in the Caddy HTTP cache.
- CFSSL binaries are pinned by exact version and SHA256. Certificate validity is verified from issued NotAfter, not assumed from requested duration.
- Root CA private keys must be backed up offline; external backup is not automated.
- SELinux remains enabled unless explicitly configured otherwise; that choice is security-sensitive.
- Firewall rules are not globally flushed or disabled.
- Dry-run must avoid filesystem, network, lock and system side effects.
- etcd restore, member changes, certificate rotation, upgrades and data deletion require separately reviewed and confirmed procedures.
