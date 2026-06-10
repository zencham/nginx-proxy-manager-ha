# NPM HA Cluster — Ansible Role

2-node High Availability Nginx Proxy Manager cluster using Pacemaker + Corosync + DRBD.
Deployed as Debian Trixie VMs. DRBD Protocol C provides synchronous replication and
split-brain data protection without requiring external STONITH.

## Architecture

| Component | Detail |
|---|---|
| Node 1 | MIBTECH-NPM-PROD-01 — 192.168.206.33 |
| Node 2 | MIBTECH-NPM-PROD-02 — 192.168.206.40 |
| VIP | 192.168.206.220/24 |
| DRBD App | /dev/sdb1 → /dev/drbd10 (3G) — mounted at /mnt/npm_app |
| DRBD DB | /dev/sdb2 → /dev/drbd11 (2G) — mounted at /mnt/npm_db |
| STONITH | Disabled — DRBD Protocol C handles split-brain protection |

## Prerequisites

1. Two Debian Trixie VMs with:
   - `/dev/sdb` present and partitioned as `/dev/sdb1` (3G+) and `/dev/sdb2` (2G+)
   - DRBD kernel module available (`modprobe --dry-run drbd`)
   - At least 2GB free on `/`
   - SSH key access from the Ansible controller
2. Ansible >= 2.14 on the controller

## Setup

### 1. Configure secrets

```bash
cp vault_vars/vault.yml.example vault_vars/vault.yml
# Edit vault_vars/vault.yml with real values
ansible-vault encrypt vault_vars/vault.yml
```

Store the vault password in a password manager. To run the playbook:

```bash
ansible-playbook main.yml --ask-vault-pass
```

### 2. DRBD prerequisite

The DRBD block devices (`/dev/sdb1`, `/dev/sdb2`) must exist and be partitioned before running the playbook. The role handles `create-md`, `up`, formatting, and Pacemaker resource creation automatically and idempotently.

## Selective Execution (Tags)

| Tag | Scope |
|---|---|
| `preflight` | Pre-flight checks (runs always, cannot be skipped) |
| `prepare` | Package install, service enable |
| `drbd` | DRBD config, metadata init, format |
| `app` | Mounts, docker-compose.yml, systemd unit |
| `cluster` | Corosync/Pacemaker cluster setup |
| `resources` | Pacemaker resources, constraints, timeouts |

```bash
# Re-deploy compose config only
ansible-playbook main.yml --ask-vault-pass --tags app

# Re-run only cluster setup
ansible-playbook main.yml --ask-vault-pass --tags cluster
```

## Testing (Molecule)

```bash
pip install molecule molecule-docker

# Idempotency — verifies file artifacts are created
cd roles/npm_ha && molecule test -s default

# Preflight failure — verifies bad disk config is caught early
molecule test -s preflight
```

## Key Defaults (overridable via inventory group_vars)

| Variable | Default | Description |
|---|---|---|
| `drbd_disk_app` | `/dev/sdb1` | Underlying block device for app DRBD |
| `drbd_disk_db` | `/dev/sdb2` | Underlying block device for db DRBD |
| `drbd_device_app` | `/dev/drbd10` | DRBD virtual device for app |
| `drbd_device_db` | `/dev/drbd11` | DRBD virtual device for db |
| `npm_image_version` | `2.14.0` | NPM Docker image tag |
| `mariadb_image_version` | `10.11` | MariaDB Docker image tag |
| `npm_admin_port` | `15625` | Host port for NPM admin UI |
| `drbd_stop_timeout` | `90s` | Pacemaker DRBD stop timeout |
| `npm_service_timeout` | `120s` | Pacemaker npm-stack start/stop timeout |
| `timezone` | `Africa/Casablanca` | Container timezone |
