# NPM HA Config Centralization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Consolidate all deployment-specific config into `inventory/group_vars/ha_nodes/`, fix Ansible variable precedence so the role is reusable, and make the playbook fully self-contained (no extra CLI flags required).

**Architecture:** Move 7 topology/cluster vars out of `roles/npm_ha/vars/main.yml` (wrong precedence tier — higher than group_vars) into a new `inventory/group_vars/ha_nodes/vars.yml`. Move vault secrets from `vault_vars/vault.yml` (loaded via an explicit `vars_files:`) into `inventory/group_vars/ha_nodes/vault.yml` so Ansible auto-loads them. Trim `roles/npm_ha/defaults/main.yml` to role-level generics only (removing deployment-specific and dead variables).

**Tech Stack:** Ansible 2.14+, ansible-lint v26.4.0, ansible-vault AES256, git

---

## File Map

| File | Action | Reason |
|---|---|---|
| `inventory/group_vars/ha_nodes/vars.yml` | CREATE | New home for all deployment-specific plaintext vars |
| `inventory/group_vars/ha_nodes/vault.yml` | MOVE from `vault_vars/` | Auto-loaded by Ansible; replaces explicit vars_files |
| `inventory/group_vars/ha_nodes/vault.yml.example` | MOVE from `vault_vars/` | Template for new deployments, updated header comment |
| `vault_vars/` | DELETE directory | Replaced entirely by group_vars |
| `inventory/hosts` | MODIFY | Add `ansible_host` per node |
| `roles/npm_ha/vars/main.yml` | MODIFY | Empty — all vars removed |
| `roles/npm_ha/defaults/main.yml` | MODIFY | Trim to 12 role-level defaults; remove 6 deployment-specific/dead vars |
| `main.yml` | MODIFY | Remove `vars_files:`, fix `become: yes` → `become: true` |
| `ansible.cfg` | MODIFY | Add `vault_password_file`, `interpreter_python`; remove deprecated `retry_files_enabled` |
| `.gitignore` | MODIFY | Add `.vault_pass` |
| `README.md` | MODIFY | New Deployment quick-start, updated Key Defaults table, vault path updates |

---

## Task 1: Create feature branch

**Files:** none (git only)

- [ ] **Step 1: Confirm you are on master with a clean working tree**

```bash
git status
git branch
```

Expected: `On branch master`, `nothing to commit`.

- [ ] **Step 2: Create and check out the feature branch**

```bash
git checkout -b feature/npm-ha-config-centralization
```

Expected: `Switched to a new branch 'feature/npm-ha-config-centralization'`

- [ ] **Step 3: Verify branch**

```bash
git branch
```

Expected: `* feature/npm-ha-config-centralization` is active.

---

## Task 2: Create group_vars deployment config and update inventory/hosts

**Files:**
- Create: `inventory/group_vars/ha_nodes/vars.yml`
- Modify: `inventory/hosts`

### Background

`inventory/group_vars/ha_nodes/` is auto-loaded by Ansible for every host in the `[ha_nodes]` group. Variables here have group_vars precedence (priority 8) and CAN be overridden from the command line or extra vars. This is the correct tier for deployment-specific config.

`inventory/hosts` currently has bare hostnames with no `ansible_host`. If the controller's DNS doesn't resolve those names, Ansible will fail. Adding `ansible_host` binds each inventory name to a specific IP, making the playbook DNS-independent.

- [ ] **Step 1: Verify the target directory does not yet exist**

```bash
ls inventory/group_vars/ 2>/dev/null || echo "NOT FOUND"
```

Expected: either `NOT FOUND` or no `ha_nodes` subdirectory listed.

- [ ] **Step 2: Create the group_vars directory**

```bash
mkdir -p inventory/group_vars/ha_nodes
```

- [ ] **Step 3: Write vars.yml**

Create `inventory/group_vars/ha_nodes/vars.yml` with this exact content:

```yaml
---
# SSH connection
ansible_user: root

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

- [ ] **Step 4: Verify vars.yml was created**

```bash
grep -c "node1_hostname\|vip_address\|drbd_disk_app\|timezone" inventory/group_vars/ha_nodes/vars.yml
```

Expected: `4`

- [ ] **Step 5: Update inventory/hosts with ansible_host entries**

`inventory/hosts` currently contains:
```ini
[ha_nodes]
MIBTECH-NPM-PROD-01
MIBTECH-NPM-PROD-02
```

Replace it with:

```ini
[ha_nodes]
MIBTECH-NPM-PROD-01 ansible_host=192.168.206.33
MIBTECH-NPM-PROD-02 ansible_host=192.168.206.40
```

- [ ] **Step 6: Verify hosts file**

```bash
grep "ansible_host" inventory/hosts
```

Expected output:
```
MIBTECH-NPM-PROD-01 ansible_host=192.168.206.33
MIBTECH-NPM-PROD-02 ansible_host=192.168.206.40
```

- [ ] **Step 7: Commit**

```bash
git add inventory/group_vars/ha_nodes/vars.yml inventory/hosts
git commit -m "$(cat <<'EOF'
feat: add group_vars deployment config, add ansible_host to inventory

Centralizes all cluster topology, DRBD device names, VIP, and timezone
into inventory/group_vars/ha_nodes/vars.yml. Adds ansible_host entries
to inventory/hosts so the playbook works without DNS resolution.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Migrate vault files and remove vault_vars/

**Files:**
- Move: `vault_vars/vault.yml` → `inventory/group_vars/ha_nodes/vault.yml`
- Move: `vault_vars/vault.yml.example` → `inventory/group_vars/ha_nodes/vault.yml.example`
- Delete: `vault_vars/` directory

### Background

`vault_vars/vault.yml` is the ansible-vault encrypted secrets file. Currently it is loaded via an explicit `vars_files:` in `main.yml`. Moving it to `inventory/group_vars/ha_nodes/` makes it auto-loaded for the `ha_nodes` group — no explicit `vars_files:` needed. The encryption is preserved (the file content is not decrypted by this move).

`vault.yml.example` is a plaintext template; its header comment needs updating to reflect the new path.

- [ ] **Step 1: Verify vault_vars/ contents**

```bash
ls -la vault_vars/
```

Expected: `vault.yml` and `vault.yml.example` exist.

- [ ] **Step 2: Move vault.yml using git mv (preserves history)**

```bash
git mv vault_vars/vault.yml inventory/group_vars/ha_nodes/vault.yml
```

- [ ] **Step 3: Move vault.yml.example using git mv**

```bash
git mv vault_vars/vault.yml.example inventory/group_vars/ha_nodes/vault.yml.example
```

- [ ] **Step 4: Update the header comment in vault.yml.example**

`inventory/group_vars/ha_nodes/vault.yml.example` currently has this header:
```
# vault_vars/vault.yml.example
# Copy to vault_vars/vault.yml, fill in real values, then:
#   ansible-vault encrypt vault_vars/vault.yml
```

Replace with:
```
# inventory/group_vars/ha_nodes/vault.yml.example
# Copy to inventory/group_vars/ha_nodes/vault.yml, fill in real values, then:
#   ansible-vault encrypt inventory/group_vars/ha_nodes/vault.yml
```

The `---` and the four variable lines below it remain unchanged:
```yaml
---
hacluster_password: "CHANGE_ME"
drbd_secret: "CHANGE_ME"
mysql_root_password: "CHANGE_ME"
mysql_npm_password: "CHANGE_ME"
```

- [ ] **Step 5: Remove the now-empty vault_vars/ directory**

After the git mv operations, `vault_vars/` is empty on disk. Remove it:

```bash
rmdir vault_vars/
```

- [ ] **Step 6: Verify new locations**

```bash
ls inventory/group_vars/ha_nodes/
```

Expected: `vars.yml  vault.yml  vault.yml.example`

```bash
ls vault_vars/ 2>/dev/null && echo "STILL EXISTS" || echo "REMOVED"
```

Expected: `REMOVED`

- [ ] **Step 7: Commit**

```bash
git add inventory/group_vars/ha_nodes/vault.yml.example
git commit -m "$(cat <<'EOF'
refactor: move vault files into group_vars/ha_nodes, remove vault_vars/

Secrets are now auto-loaded by Ansible for the ha_nodes group.
No vars_files: needed in the playbook. vault.yml.example header
comment updated to reflect new path.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Update main.yml, ansible.cfg, and .gitignore

**Files:**
- Modify: `main.yml`
- Modify: `ansible.cfg`
- Modify: `.gitignore`

### Background

**main.yml**: The `vars_files: - vault_vars/vault.yml` line is no longer needed (vault is auto-loaded from group_vars). `become: yes` is valid YAML but Ansible best practice (and ansible-lint) prefers boolean `true`.

**ansible.cfg**:
- `retry_files_enabled = False` — deprecated since Ansible 2.12, emits a deprecation warning on every run; remove it.
- `interpreter_python = auto_silent` — suppresses Python interpreter discovery warnings that appear on Debian Trixie (which ships multiple Python versions).
- `vault_password_file = .vault_pass` — if a `.vault_pass` file exists in the project root (gitignored), Ansible uses it automatically; no `--ask-vault-pass` needed. If the file is absent Ansible errors; the operator must create it or pass `--ask-vault-pass` manually.

**.gitignore**: `.vault_pass` must be gitignored to prevent accidentally committing the vault password.

- [ ] **Step 1: Verify current main.yml state**

```bash
grep -n "vars_files\|become" main.yml
```

Expected:
```
4:  become: yes
5:  vars_files:
6:    - vault_vars/vault.yml
```

- [ ] **Step 2: Rewrite main.yml**

Replace the full content of `main.yml` with:

```yaml
---
- name: Deploy HA Cluster for NPM (Pacemaker, Corosync, DRBD)
  hosts: ha_nodes
  become: true
  roles:
    - role: npm_ha
```

- [ ] **Step 3: Verify main.yml**

```bash
grep -c "vars_files\|vault_vars" main.yml
```

Expected: `0`

```bash
grep "become:" main.yml
```

Expected: `  become: true`

- [ ] **Step 4: Verify current ansible.cfg state**

```bash
grep -n "retry_files\|interpreter\|vault_password" ansible.cfg
```

Expected: only `retry_files_enabled = False` appears; no interpreter_python or vault_password_file lines.

- [ ] **Step 5: Rewrite ansible.cfg**

Replace the full content of `ansible.cfg` with:

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

- [ ] **Step 6: Verify ansible.cfg**

```bash
grep -c "retry_files_enabled" ansible.cfg
```

Expected: `0`

```bash
grep "interpreter_python\|vault_password_file" ansible.cfg
```

Expected:
```
interpreter_python   = auto_silent
vault_password_file  = .vault_pass
```

- [ ] **Step 7: Verify current .gitignore**

```bash
cat .gitignore
```

Expected: only `*.retry` (no `.vault_pass` line yet).

- [ ] **Step 8: Add .vault_pass to .gitignore**

The current `.gitignore` content is:
```
# Ansible retry files
*.retry
```

Replace with:
```
# Ansible retry files
*.retry

# Vault password file — never commit this
.vault_pass
```

- [ ] **Step 9: Verify .gitignore**

```bash
grep ".vault_pass" .gitignore
```

Expected: `.vault_pass`

- [ ] **Step 10: Commit**

```bash
git add main.yml ansible.cfg .gitignore
git commit -m "$(cat <<'EOF'
chore: remove vars_files, add vault_password_file, suppress deprecation warnings

main.yml: vault auto-loaded from group_vars (no vars_files needed), become: true.
ansible.cfg: drop deprecated retry_files_enabled, add interpreter_python=auto_silent
and vault_password_file=.vault_pass.
.gitignore: add .vault_pass.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Empty vars/main.yml and trim defaults/main.yml

**Files:**
- Modify: `roles/npm_ha/vars/main.yml`
- Modify: `roles/npm_ha/defaults/main.yml`

### Background

**vars/main.yml** holds the MIBTECH topology at Ansible precedence tier 14 (vars/ files) — higher than group_vars (tier 8). This means any value here cannot be overridden by inventory, making the role non-reusable. Since all these values were moved to `group_vars` in Task 2, this file must be emptied.

**defaults/main.yml** currently contains 6 values that do not belong in role defaults:
- `drbd_disk_app / drbd_disk_db` — hardware-specific physical disk paths. No safe universal default exists; wrong disk = data loss. A mandatory undefined-variable error is intentionally safer than silently using `/dev/sdb*` on a node with different hardware.
- `drbd_resource_app / drbd_resource_db` — deployment-specific naming; must be stable after first deploy (pcs resource names are persistent state).
- `cluster_settle_wait: 15` — dead variable; both pause tasks it guarded were replaced by polling loops in the hardening pass.
- `timezone` — deployment-specific.

All four categories above were moved to `group_vars` in Task 2.

- [ ] **Step 1: Verify current vars/main.yml content**

```bash
cat roles/npm_ha/vars/main.yml
```

Expected: 8 lines with cluster_name, vip_address, vip_cidr, node1_hostname, node1_ip, node2_hostname, node2_ip.

- [ ] **Step 2: Empty vars/main.yml**

Replace the full content of `roles/npm_ha/vars/main.yml` with:

```yaml
---
```

- [ ] **Step 3: Verify vars/main.yml is empty**

```bash
wc -l roles/npm_ha/vars/main.yml
```

Expected: `1 roles/npm_ha/vars/main.yml`

```bash
grep -c "cluster_name\|vip_address\|node1" roles/npm_ha/vars/main.yml
```

Expected: `0`

- [ ] **Step 4: Verify current defaults/main.yml content**

```bash
grep -n "drbd_disk\|drbd_resource\|cluster_settle\|timezone" roles/npm_ha/defaults/main.yml
```

Expected: lines showing all 6 values that will be removed.

- [ ] **Step 5: Rewrite defaults/main.yml with trimmed content**

Replace the full content of `roles/npm_ha/defaults/main.yml` with:

```yaml
---
# DRBD virtual device paths (created by DRBD kernel module — not the physical disk)
drbd_device_app: /dev/drbd10
drbd_device_db:  /dev/drbd11

# DRBD replication ports
drbd_port_app: 7790
drbd_port_db:  7791

# DRBD initial-sync rate limit (avoids saturating the replication link on first sync)
drbd_resync_rate: "10M"

# Application paths on DRBD mounts
npm_compose_dir: /opt/npm/compose
npm_mount_app:   /mnt/npm_app
npm_mount_db:    /mnt/npm_db

# Container image versions (pinned)
npm_image_version:      "2.14.0"
mariadb_image_version:  "10.11.16"

# NPM admin UI host port (mapped to container port 81)
npm_admin_port: 15625

# Pacemaker resource timeouts
drbd_stop_timeout:    90s
npm_service_timeout:  120s
```

- [ ] **Step 6: Verify defaults/main.yml has no removed variables**

```bash
grep -c "drbd_disk\|drbd_resource\|cluster_settle\|timezone" roles/npm_ha/defaults/main.yml
```

Expected: `0`

- [ ] **Step 7: Verify defaults/main.yml has the expected 12 variables**

```bash
grep -c "^[a-z]" roles/npm_ha/defaults/main.yml
```

Expected: `12`

- [ ] **Step 8: Commit**

```bash
git add roles/npm_ha/vars/main.yml roles/npm_ha/defaults/main.yml
git commit -m "$(cat <<'EOF'
refactor: empty vars/main.yml, trim defaults to role-level generics

vars/main.yml emptied — all topology vars now live in group_vars where
they can be overridden from inventory (correct precedence tier).
defaults/main.yml trimmed: removed drbd_disk_app/db, drbd_resource_app/db,
cluster_settle_wait (dead), and timezone — all deployment-specific.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Update README.md

**Files:**
- Modify: `README.md`

### Changes required

1. **Prerequisites**: Add vault_pass note.
2. **Setup > Configure secrets**: Update all `vault_vars/` path references to `inventory/group_vars/ha_nodes/`. Update run command.
3. **Add "New Deployment" section**: 6-step quick-start for a new cluster.
4. **Key Defaults table**: Remove `drbd_disk_app`, `drbd_disk_db`, `timezone` (moved to group_vars; no longer defaults). Add `drbd_port_app`, `drbd_port_db`, `npm_compose_dir`, `npm_mount_app`, `npm_mount_db` (were in defaults but missing from table).
5. **Future Considerations**: Add STONITH entry.

- [ ] **Step 1: Verify current Prerequisites section**

```bash
grep -n "Prerequisites\|vault_pass\|sdb1\|sdb2\|SSH" README.md | head -20
```

Note the current content of the Prerequisites section (lines ~19–26).

- [ ] **Step 2: Replace the Prerequisites section**

Find this block in `README.md`:
```markdown
## Prerequisites

1. Two Debian Trixie VMs with:
   - `/dev/sdb` present and partitioned as `/dev/sdb1` (3G+) and `/dev/sdb2` (2G+)
   - DRBD kernel module available (`modprobe --dry-run drbd`)
   - At least 2GB free on `/`
   - SSH key access from the Ansible controller
2. Ansible >= 2.14 on the controller
```

Replace with:
```markdown
## Prerequisites

1. Two Debian Trixie VMs with:
   - `/dev/sdb` present and partitioned as `/dev/sdb1` (3G+) and `/dev/sdb2` (2G+)
   - DRBD kernel module available (`modprobe --dry-run drbd`)
   - At least 2GB free on `/`
   - SSH key access from the Ansible controller
2. Ansible >= 2.14 on the controller
3. `.vault_pass` file in the project root containing the vault password (gitignored).
   Create it after cloning: `echo -n 'your-vault-password' > .vault_pass && chmod 600 .vault_pass`
```

- [ ] **Step 3: Verify Prerequisites section update**

```bash
grep -A5 "^## Prerequisites" README.md | grep "vault_pass"
```

Expected: line with `.vault_pass` appears.

- [ ] **Step 4: Replace the Setup > Configure secrets section**

Find this block in `README.md`:
```markdown
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
```

Replace with:
```markdown
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
```

- [ ] **Step 5: Verify Configure secrets section update**

```bash
grep -c "vault_vars/" README.md
```

Expected: `0` (no remaining references to the old path).

- [ ] **Step 6: Add "New Deployment" section**

Insert a new section after the `## Setup` block (after the DRBD prerequisite section, before `## Selective Execution`). Find the line:

```
## Selective Execution (Tags)
```

Insert immediately before it:

```markdown
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

```

- [ ] **Step 7: Verify New Deployment section exists**

```bash
grep -c "New Deployment" README.md
```

Expected: `1`

- [ ] **Step 8: Replace the Key Defaults table**

Find this block:
```markdown
## Key Defaults (overridable via inventory group_vars)

| Variable | Default | Description |
|---|---|---|
| `drbd_disk_app` | `/dev/sdb1` | Underlying block device for app DRBD |
| `drbd_disk_db` | `/dev/sdb2` | Underlying block device for db DRBD |
| `drbd_device_app` | `/dev/drbd10` | DRBD virtual device for app |
| `drbd_device_db` | `/dev/drbd11` | DRBD virtual device for db |
| `npm_image_version` | `2.14.0` | NPM Docker image tag |
| `mariadb_image_version` | `10.11.16` | MariaDB Docker image tag (pinned to the version running in production) |
| `drbd_resync_rate` | `10M` | DRBD initial-sync rate limit |
| `npm_admin_port` | `15625` | Host port for NPM admin UI |
| `drbd_stop_timeout` | `90s` | Pacemaker DRBD stop timeout |
| `npm_service_timeout` | `120s` | Pacemaker npm-stack start/stop timeout |
| `timezone` | `Africa/Casablanca` | Container timezone |
```

Replace with:
```markdown
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
```

- [ ] **Step 9: Verify Key Defaults table**

```bash
grep -c "drbd_disk_app\|drbd_disk_db\|timezone" README.md
```

Expected: `0` (removed from table).

```bash
grep -c "drbd_port_app\|npm_compose_dir\|npm_mount_app" README.md
```

Expected: `3` (new entries present).

- [ ] **Step 10: Update Future Considerations section**

Find the `## Future Considerations` section and append a STONITH entry. The section currently ends with:

```markdown
  - Docker CE migration: ...
```

After the last bullet, add:

```markdown
- **STONITH (`fence_pve`)**: The original design spec included STONITH via `fence-agents-pve`
  against the Proxmox hypervisor. It was deferred because it requires Proxmox API credentials,
  VM ID mapping, and a dedicated task file. Until implemented, DRBD Protocol C provides
  split-brain protection but a two-node cluster without STONITH cannot safely recover from
  a partial network partition — both nodes may attempt primary. Track as a separate spec.
```

- [ ] **Step 11: Verify STONITH entry**

```bash
grep -c "fence_pve\|STONITH" README.md
```

Expected: at least `2` (one in Architecture table, one in Future Considerations).

- [ ] **Step 12: Update example commands in Selective Execution section**

The "Selective Execution (Tags)" section has two example commands that still include `--ask-vault-pass`:

```bash
ansible-playbook main.yml --ask-vault-pass --tags app
ansible-playbook main.yml --ask-vault-pass --tags cluster
```

Replace both to drop the flag (vault is now handled by `.vault_pass`):

```bash
ansible-playbook main.yml --tags app
ansible-playbook main.yml --tags cluster
```

- [ ] **Step 13: Verify Selective Execution commands updated**

```bash
grep -c "ask-vault-pass" README.md
```

Expected: `0`

- [ ] **Step 14: Commit**

```bash
git add README.md
git commit -m "$(cat <<'EOF'
docs: update README for centralized config and new-deployment quick-start

- Prerequisites: add vault_pass setup note
- Setup: update all vault_vars/ paths to inventory/group_vars/ha_nodes/
- Add New Deployment quick-start section
- Key Defaults: remove deployment-specific vars, add previously undocumented defaults
- Future Considerations: add STONITH/fence_pve entry

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: Final verification

**Files:** none (verification only)

This task confirms the full set of changes produces a syntactically valid playbook with zero ansible-lint findings.

### Background on verification tools

**ansible-playbook --syntax-check**: Parses the playbook and all imported task files, resolves variable references, and validates Jinja2 templates. Requires vault to be decrypted (it may reference vault variables in templates). Runs against the local inventory without connecting to any hosts.

**ansible-lint**: Static analysis for Ansible best practices and style. Config is in `.ansible-lint` at project root. The current skip_list is: `var-naming[no-role-prefix], fqcn[action-core], fqcn[action], no-changed-when, no-handler, ignore-errors, risky-shell-pipe`.

**Important**: `ansible.cfg` now references `vault_password_file = .vault_pass`. If `.vault_pass` does not exist, Ansible errors before running the syntax check. You must create it first.

- [ ] **Step 1: Retrieve the vault password from git history and write .vault_pass**

```bash
git show 6d03396 --format="%B" --no-patch
```

This commit's body contains the vault password. Write it to `.vault_pass`:

```bash
echo -n '<vault-password-from-commit-body>' > .vault_pass
chmod 600 .vault_pass
```

Do NOT commit `.vault_pass` — it is gitignored and must stay out of git.

- [ ] **Step 2: Confirm .vault_pass is gitignored**

```bash
git status
```

Expected: `.vault_pass` does NOT appear in the output (it is ignored).

- [ ] **Step 3: Run syntax check**

```bash
ansible-playbook main.yml --syntax-check
```

Expected output ends with:
```
playbook: main.yml
```

If it errors with "ERROR! A vault password file was specified... does not exist" — `.vault_pass` was not written correctly. Re-check Step 1.

If it errors with "ERROR! 'node1_hostname' is undefined" — `inventory/group_vars/ha_nodes/vars.yml` was not created or has a typo. Check Task 2.

If it errors with "ERROR! 'hacluster_password' is undefined" — vault.yml was not moved or cannot be decrypted. Check Task 3 and that the vault password in `.vault_pass` is correct.

- [ ] **Step 4: Run ansible-lint**

```bash
ansible-lint roles/npm_ha
```

Expected: exits 0 with `Passed: 0 failure(s), 0 warning(s)` (or similar clean output).

If lint fails: check the `.ansible-lint` skip_list at the project root. Known skips are in place from the hardening pass. Any new failures are genuine issues introduced by this pass — fix them before proceeding.

- [ ] **Step 5: Confirm vault_vars/ is fully gone from git**

```bash
git ls-files vault_vars/
```

Expected: no output (no tracked files remain under vault_vars/).

- [ ] **Step 6: Confirm no remaining references to vault_vars/**

```bash
grep -r "vault_vars" . --include="*.yml" --include="*.ini" --include="*.md" --include="*.cfg"
```

Expected: no output.

- [ ] **Step 7: Confirm vars/main.yml is truly empty (only `---`)**

```bash
wc -l roles/npm_ha/vars/main.yml && cat roles/npm_ha/vars/main.yml
```

Expected: `1 roles/npm_ha/vars/main.yml` and content `---`.

- [ ] **Step 8: Final status check**

```bash
git log --oneline master..HEAD
```

Expected: 5 commits (Tasks 2–6), all on `feature/npm-ha-config-centralization`.

All checks pass — the branch is ready for review and merge.
