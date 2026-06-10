# NPM HA — Configuration Centralization and Project Autonomy Design

**Date:** 2026-06-10
**Branch:** to be implemented on a new feature branch off `master`
**Scope:** Restructure variable placement, centralize cluster config, close tooling gaps

---

## Overview

The role currently splits configuration across three locations with a variable-precedence
defect that prevents overriding cluster topology from inventory:

- `roles/npm_ha/vars/main.yml` — node IPs, hostnames, VIP (Ansible `vars/` tier: **higher
  precedence than `group_vars`** — cannot be overridden from inventory without fighting Ansible)
- `roles/npm_ha/defaults/main.yml` — DRBD tuning, image versions, paths, timeouts (correct tier)
- `vault_vars/vault.yml` — secrets, loaded via an explicit `vars_files:` in `main.yml`
  (non-standard; secrets loaded outside the normal inventory variable flow)

Goals of this pass:

1. **Centralize** — all deployment-specific config lives in `inventory/group_vars/ha_nodes/`,
   the single place an operator edits to configure any cluster.
2. **Standardize** — proper Ansible variable precedence tiers; `vars/main.yml` emptied;
   `vault_vars/` removed; `vars_files:` removed from playbook.
3. **Compact** — `defaults/main.yml` trimmed to only values that have a meaningful
   cross-deployment default; deployment-required values moved to `group_vars` with no
   fallback (explicit undefined-variable error is safer than a wrong default).
4. **Full autonomy** — clone repo → edit two files in `inventory/group_vars/ha_nodes/` →
   `ansible-playbook main.yml` works. No external vault file path to remember, no
   extra CLI flags required.

---

## Directory Structure After

```
ansible/
├── .ansible-lint
├── .gitignore                         # adds .vault_pass
├── ansible.cfg                        # adds interpreter_python, vault_password_file;
│                                      # removes deprecated retry_files_enabled
├── main.yml                           # removes vars_files:; become: yes → true
├── inventory/
│   ├── hosts                          # adds ansible_host per node
│   └── group_vars/
│       └── ha_nodes/
│           ├── vars.yml               # NEW — all deployment-specific plaintext config
│           ├── vault.yml              # MOVED from vault_vars/ (same encrypted content)
│           └── vault.yml.example      # MOVED from vault_vars/
├── vault_vars/                        # REMOVED entirely
├── roles/
│   └── npm_ha/
│       ├── defaults/main.yml          # TRIMMED — generic defaults only
│       └── vars/main.yml              # EMPTIED — just ---
└── docs/
    └── superpowers/specs/
        └── 2026-06-10-npm-ha-config-centralization-design.md  ← this file
```

---

## Variable Placement

### `roles/npm_ha/defaults/main.yml` — role-level defaults

Values that have a sensible cross-deployment answer. A deployer who doesn't override
these gets working behaviour. All can be overridden from `group_vars`.

```yaml
---
# DRBD virtual device paths (created by DRBD kernel module)
drbd_device_app: /dev/drbd10
drbd_device_db:  /dev/drbd11

# DRBD replication ports
drbd_port_app: 7790
drbd_port_db:  7791

# DRBD initial-sync rate limit
drbd_resync_rate: "10M"

# Application paths on DRBD mounts
npm_compose_dir: /opt/npm/compose
npm_mount_app:   /mnt/npm_app
npm_mount_db:    /mnt/npm_db

# Container image versions (pinned)
npm_image_version:      "2.14.0"
mariadb_image_version:  "10.11.16"

# NPM admin UI host port
npm_admin_port: 15625

# Pacemaker resource timeouts
drbd_stop_timeout:    90s
npm_service_timeout:  120s
```

**Removed from defaults (vs. current state):**
- `drbd_disk_app / drbd_disk_db` — physical disk paths are hardware-specific with no
  safe universal default. An undefined-variable error if unset is safer than silently
  formatting the wrong device.
- `drbd_resource_app / drbd_resource_db` — naming is deployment-specific.
- `cluster_settle_wait: 15` — orphaned dead variable (both pause tasks were replaced by
  polling in the hardening pass).
- `timezone` — deployment-specific; meaningless as a role default.
- All topology vars (moved to `group_vars`).

### `inventory/group_vars/ha_nodes/vars.yml` — deployment identity

Everything specific to this cluster. A new deployment edits only this file (and `vault.yml`).

```yaml
---
# SSH connection
ansible_user: root   # SSH user on the cluster nodes

# Pacemaker cluster name
cluster_name: npm_ha_cluster

# Node topology
node1_hostname: MIBTECH-NPM-PROD-01
node1_ip:       192.168.206.33
node2_hostname: MIBTECH-NPM-PROD-02
node2_ip:       192.168.206.40

# Virtual IP
vip_address: 192.168.206.220
vip_cidr:    "24"

# DRBD underlying physical block devices
# WARNING: verify with `lsblk` on each node before first run.
# Wrong disk = data loss. No default is set intentionally.
drbd_disk_app: /dev/sdb1
drbd_disk_db:  /dev/sdb2

# DRBD resource names (used by pcs and drbdadm — must be stable after first deploy)
drbd_resource_app: mib_npm_ha_drbd_npm
drbd_resource_db:  mib_npm_ha_drbd_db

# Container timezone
timezone: Africa/Casablanca
```

### `inventory/group_vars/ha_nodes/vault.yml` — secrets (ansible-vault encrypted)

Same four variables as the current `vault_vars/vault.yml`. File is moved, not changed.
Loaded automatically by Ansible for the `ha_nodes` group — no `vars_files:` needed.

```yaml
# (ansible-vault AES256 encrypted)
hacluster_password: "..."
drbd_secret:        "..."
mysql_root_password: "..."
mysql_npm_password:  "..."
```

### `roles/npm_ha/vars/main.yml` — emptied

```yaml
---
```

No variables. The `vars/` tier is reserved for values that must not be overridable
(e.g., computed/derived facts). This role has none.

---

## File Changes

### `inventory/hosts`

Add `ansible_host` per node so the playbook works even if the hostnames are not in
DNS (e.g., on a fresh deploy before `/etc/hosts` entries exist):

```ini
[ha_nodes]
MIBTECH-NPM-PROD-01 ansible_host=192.168.206.33
MIBTECH-NPM-PROD-02 ansible_host=192.168.206.40
```

Note: `ansible_host` (SSH target IP) and `node1_ip`/`node2_ip` (DRBD/pcs cluster IPs)
are the same values but serve different purposes and are intentionally co-located.

### `main.yml`

Remove `vars_files:` (vault auto-loaded from `group_vars`). Fix `become: yes` → `become: true`.

```yaml
---
- name: Deploy HA Cluster for NPM (Pacemaker, Corosync, DRBD)
  hosts: ha_nodes
  become: true
  roles:
    - role: npm_ha
```

### `ansible.cfg`

Three changes:

1. Remove `retry_files_enabled = False` — deprecated since Ansible 2.12, generates a
   deprecation warning on every run.
2. Add `interpreter_python = auto_silent` — suppresses Python interpreter discovery
   warnings on Debian Trixie (which has multiple Python versions).
3. Add `vault_password_file = .vault_pass` — if a local `.vault_pass` file exists
   (gitignored), vault decrypts automatically with no CLI flags. If the file is absent
   Ansible errors; the operator must either create `.vault_pass` or override with
   `--ask-vault-pass` on the command line. Enables unattended automation without
   embedding the password in the repo.

```ini
[defaults]
inventory            = inventory/hosts
roles_path           = roles
stdout_callback      = yaml
host_key_checking    = True
timeout              = 30
interpreter_python   = auto_silent
vault_password_file  = .vault_pass

[ssh_connection]
pipelining           = True
```

### `.gitignore`

Add `.vault_pass` so the local vault password file is never accidentally committed:

```
*.retry
.vault_pass
```

### `vault_vars/` — removed entirely

Both `vault.yml` (encrypted) and `vault.yml.example` are removed from this directory.

- `vault.yml` is migrated to `inventory/group_vars/ha_nodes/vault.yml` (file content
  unchanged — same ansible-vault AES256 encryption, same password, just a new path).
- `vault.yml.example` is migrated to `inventory/group_vars/ha_nodes/vault.yml.example`.

### `README.md`

Update:
- Vault section: replace `vault_vars/vault.yml` references with `inventory/group_vars/ha_nodes/vault.yml`.
- Add a "New Deployment" quick-start section (see below).
- Update the "Key Defaults" table to reflect the trimmed `defaults/main.yml`.
- Add a note in the Prerequisites section: "copy `.vault_pass.example` or write your
  vault password to `.vault_pass` in the project root".

New Deployment quick-start block to add to README:

```markdown
## New Deployment

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
```

---

## Gap and Issue Inventory

| # | Issue | Resolution |
|---|---|---|
| 1 | `vars/main.yml` precedence blocks topology override from inventory | Emptied; values moved to `group_vars` |
| 2 | Config scattered across `vars/`, `defaults/`, `vault_vars/` | Consolidated: `group_vars/ha_nodes/vars.yml` + `vault.yml` |
| 3 | `drbd_disk_app/db` silently default to `/dev/sdb*` (data-loss risk if wrong) | Removed from `defaults`; explicit unset error forces operator attention |
| 4 | `cluster_settle_wait: 15` orphaned in `defaults/main.yml` | Removed |
| 5 | `vault_vars/vault.yml` loaded via non-standard `vars_files:` | Moved to `group_vars`; auto-loaded |
| 6 | `inventory/hosts` DNS-dependent — breaks without working DNS | `ansible_host` added per node |
| 7 | Every run requires `--vault-password-file` or `--ask-vault-pass` | `vault_password_file = .vault_pass` in `ansible.cfg` |
| 8 | `.gitignore` missing `.vault_pass` | Added |
| 9 | `retry_files_enabled = False` deprecated — warning on every run | Removed from `ansible.cfg` |
| 10 | `interpreter_python` unset — Python discovery warnings on Trixie | `auto_silent` added |
| 11 | `become: yes` in playbook | `become: true` |
| 12 | STONITH (`fence_pve`) from original design spec never implemented | Documented as future work (separate spec required — needs Proxmox API creds, `fence-agents-pve` package, VM ID mapping) |

---

## Out of Scope

- STONITH / `fence_pve` — requires Proxmox API credentials and a dedicated task file;
  deserves its own spec and implementation pass.
- Multi-cluster inventory (multiple `inventory/` directories) — not needed for this
  single-cluster project; can be added later by duplicating the inventory directory.
- `ansible_user` beyond documenting it in `vars.yml` — SSH key management and user
  provisioning are outside this role's scope.
- `host_vars/` per node — the two cluster nodes are symmetric; no per-node overrides
  are needed.
