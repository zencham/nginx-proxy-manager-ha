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
3. `.vault_pass` file in the project root containing the vault password (gitignored).
   Create it after cloning: `echo -n 'your-vault-password' > .vault_pass && chmod 600 .vault_pass`

## Setup

### 1. Configure secrets

```bash
cp inventory/group_vars/ha_nodes/vault.yml.example inventory/group_vars/ha_nodes/vault.yml
# Edit inventory/group_vars/ha_nodes/vault.yml with real values
ansible-vault encrypt inventory/group_vars/ha_nodes/vault.yml
```

Store the vault password in a password manager and write it to `.vault_pass` (gitignored):

```bash
echo -n 'your-vault-password' > .vault_pass
chmod 600 .vault_pass
```

Then run the playbook (vault decrypts automatically via `.vault_pass`):

```bash
ansible-playbook main.yml
```

### 2. DRBD prerequisite

The DRBD block devices (`/dev/sdb1`, `/dev/sdb2`) must exist and be partitioned before running the playbook. The role handles `create-md`, `up`, formatting, and Pacemaker resource creation automatically and idempotently.

## New Deployment (Different Cluster)

To deploy this role to a different cluster:

1. Clone the repo.
2. Edit `inventory/hosts` — replace hostnames and `ansible_host` IPs.
3. Edit `inventory/group_vars/ha_nodes/vars.yml` — fill in your cluster topology
   (node IPs/hostnames, VIP, disk devices, cluster name, timezone).
4. Copy `inventory/group_vars/ha_nodes/vault.yml.example` to
   `inventory/group_vars/ha_nodes/vault.yml`, fill in real secrets, encrypt:
   ```bash
   ansible-vault encrypt inventory/group_vars/ha_nodes/vault.yml
   ```
5. Write your vault password to `.vault_pass` (gitignored):
   ```bash
   echo -n 'your-vault-password' > .vault_pass
   chmod 600 .vault_pass
   ```
6. Run:
   ```bash
   ansible-playbook main.yml
   ```

## Selective Execution (Tags)

| Tag | Scope |
|---|---|
| `preflight` | Pre-flight checks (runs always, cannot be skipped) |
| `prepare` | Package install, service enable |
| `drbd` | DRBD config, metadata init, format |
| `app` | Mounts, docker-compose.yml, systemd unit |
| `cluster` | Corosync/Pacemaker cluster setup |
| `resources` | Pacemaker resources, constraints, timeouts |
| `verify` | Post-deployment cluster/DRBD health checks (also runs with `resources`) |

```bash
# Re-deploy compose config only
ansible-playbook main.yml --tags app

# Re-run only cluster setup
ansible-playbook main.yml --tags cluster
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

These are role-level defaults. Deployment-specific config (node IPs, hostnames, VIP, disk
devices, DRBD resource names, timezone) lives in `inventory/group_vars/ha_nodes/vars.yml`.

| Variable | Default | Description |
|---|---|---|
| `drbd_device_app` | `/dev/drbd10` | DRBD virtual device for app (kernel-managed) |
| `drbd_device_db` | `/dev/drbd11` | DRBD virtual device for db (kernel-managed) |
| `drbd_port_app` | `7790` | DRBD replication TCP port for app resource |
| `drbd_port_db` | `7791` | DRBD replication TCP port for db resource |
| `drbd_resync_rate` | `10M` | DRBD initial-sync rate limit |
| `npm_compose_dir` | `/opt/npm/compose` | Docker Compose file directory |
| `npm_mount_app` | `/mnt/npm_app` | Mount point for app DRBD device |
| `npm_mount_db` | `/mnt/npm_db` | Mount point for db DRBD device |
| `npm_image_version` | `2.14.0` | NPM Docker image tag |
| `mariadb_image_version` | `10.11.16` | MariaDB Docker image tag |
| `npm_admin_port` | `15625` | Host port for NPM admin UI |
| `drbd_stop_timeout` | `90s` | Pacemaker DRBD stop timeout |
| `npm_service_timeout` | `120s` | Pacemaker npm-stack start/stop timeout |

## Network Requirements

No host firewall (`ufw`/`firewalld`/standalone `nftables` rules) is
currently managed on either node — only Docker's own `iptables-nft` chains
exist. If you add perimeter or host firewall rules, the cluster needs:

| Purpose | Protocol/Port |
|---|---|
| Corosync cluster traffic | UDP 5404, 5405 |
| pcsd (cluster auth/management) | TCP 2224 |
| DRBD app replication | TCP 7790 (`drbd_port_app`) |
| DRBD db replication | TCP 7791 (`drbd_port_db`) |
| HTTP/HTTPS (NPM proxy) | TCP 80, 443 |
| NPM admin UI | TCP 15625 (`npm_admin_port`) |

## Certificate Management (cert_manager)

Wildcard TLS certificates are issued on the controller via [acme.sh](https://github.com/acmesh-official/acme.sh) + Cloudflare DNS-01 and pushed to NPM nodes via the NPM HTTP API. NPM nodes have no outbound internet access — all ACME traffic originates from the controller.

### Prerequisites

- Cloudflare API token per domain (DNS:Edit permission on that specific zone)
- NPM admin UI password

### Setup

1. Copy and populate the controller vault:

```bash
cp inventory/group_vars/controller/vault.yml.example inventory/group_vars/controller/vault.yml
# Edit inventory/group_vars/controller/vault.yml: fill in each cloudflare_tokens entry and npm_admin_password
ansible-vault encrypt inventory/group_vars/controller/vault.yml --encrypt-vault-id default
```

2. Edit `inventory/group_vars/controller/vars.yml` with your domain list, NPM API URL, and ACME email.

### Running

```bash
ansible-playbook cert_manager.yml
```

- **First run per domain**: issues a new wildcard + apex cert from Let's Encrypt via Cloudflare DNS-01.
- **Subsequent runs**: renews only if the cert expires within `cert_renew_days` (default 30 days). No-op if still valid.

### Automating (optional)

Add a weekly cron on the controller:

```
0 3 * * 1 cd /path/to/ansible && ansible-playbook cert_manager.yml
```

No role changes needed — the `--days` threshold already makes runs idempotent.

### Staging / testing

To avoid Let's Encrypt rate limits while testing, set in `inventory/group_vars/controller/vars.yml`:

```yaml
acme_server: "letsencrypt_test"
```

Issue against staging, verify the cert upload flow, then switch back to `letsencrypt` and re-run to issue the production cert.

## Future Considerations

- **Docker CE migration**: both nodes currently run `docker.io` (the Debian
  package). Upstream `docker-ce` receives security updates faster, but
  swapping it in on already-deployed nodes requires a planned in-place
  package replacement (conflicting packages, daemon restart) — out of scope
  for this role pass.
- **STONITH (`fence_pve`)**: The original design spec included STONITH via `fence-agents-pve`
  against the Proxmox hypervisor. It was deferred because it requires Proxmox API credentials,
  VM ID mapping, and a dedicated task file. Until implemented, DRBD Protocol C provides
  split-brain protection but a two-node cluster without STONITH cannot safely recover from
  a partial network partition — both nodes may attempt primary. Track as a separate spec.
