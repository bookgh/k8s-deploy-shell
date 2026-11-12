# Security model

- Config and inventory files are data, never sourced or evaluated.
- SSH requires BatchMode and StrictHostKeyChecking with a dedicated known_hosts file.
- The artifact HTTP root contains non-secret immutable artifacts only.
- Private keys and kubeconfigs must never enter Git, logs or the HTTP root.
- Existing CA directories cause a hard failure; no overwrite is implicit.
- SELinux remains enabled unless explicitly configured otherwise; that choice is security-sensitive.
- Firewall rules are not globally flushed or disabled.
- Dry-run must avoid filesystem, network, lock and system side effects.
- etcd restore, member changes, certificate rotation, upgrades and data deletion require separately reviewed and confirmed procedures.
