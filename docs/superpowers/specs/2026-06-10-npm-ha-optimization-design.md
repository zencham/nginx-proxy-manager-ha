# NPM HA Cluster — Role Optimization & Enterprise Hardening

**Date:** 2026-06-10
**Project:** `_ZENSEC/_NPM/ansible/`
**Scope:** Full overhaul — role conversion, security hardening, operational robustness, Molecule testing

---

## 1. Overview

The current flat Ansible playbook deploys a 2-node High Availability Nginx Proxy Manager cluster
using Pacemaker + Corosync + DRBD on Proxmox VMs. This design converts it to an enterprise-grade
Ansible role (`roles/npm_ha/`) with proper structure, encrypted secrets, Proxmox-native STONITH
fencing, pre-flight validation, execution tags, and Molecule test coverage.

---

## 2. Goals

- Convert flat task files to a proper Ansible role (`roles/npm_ha/`)
- Encrypt `vault_vars/vault.yml` with `ansible-vault` AES256 (currently plaintext)
- Add Proxmox `fence_pve` STONITH to eliminate split-brain risk
- Add pre-flight validation tasks (disks, kernel module, connectivity)
- Parametrize all hardcoded values into `defaults/main.yml`
- Add execution tags for selective day-2 operations
- Add handlers for systemd daemon-reload and pcsd restart
- Add Molecule test scenarios: idempotency, preflight failure, STONITH configuration
- Add meaningful `ansible.cfg`, `.gitignore`, `vault.yml.example`, and updated `README.md`
- Delete confirmed dead code: `tasks/systemd.yml` (100% duplicate of `prepare-app.yml` tasks)

---

## 3. Final Directory Structure

```
ansible/
├── .gitignore                         # blocks accidental commit of plaintext vault.yml
├── ansible.cfg                        # roles_path, inventory, stdout_callback, timeout
├── main.yml                           # top-level playbook — imports npm_ha role
├── inventory/
│   └── hosts                          # [ha_nodes] — unchanged
├── vault_vars/
│   ├── vault.yml                      # ansible-vault AES256 encrypted
│   └── vault.yml.example              # all variables with placeholder values, safe to commit
├── docs/
│   └── superpowers/specs/
│       └── 2026-06-10-npm-ha-optimization-design.md
└── roles/
    └── npm_ha/
        ├── meta/main.yml              # min_ansible_version: 2.14, platform: Debian Bookworm
        ├── defaults/main.yml          # all overridable vars
        ├── vars/main.yml              # fixed cluster identity (names, IPs, VIP)
        ├── handlers/main.yml          # reload systemd, restart pcsd
        ├── tasks/
        │   ├── main.yml               # import_tasks with tags
        │   ├── preflight.yml          # tag: preflight
        │   ├── prepare.yml            # tag: prepare
        │   ├── drbd.yml               # tag: drbd
        │   ├── prepare_app.yml        # tag: app
        │   ├── cluster.yml            # tag: cluster
        │   ├── resources.yml          # tag: resources
        │   └── stonith.yml            # tag: stonith
        ├── templates/
        │   ├── npm-ha.res.j2
        │   └── docker-compose.yml.j2
        └── molecule/
            ├── default/               # idempotency scenario
            │   ├── molecule.yml
            │   ├── converge.yml
            │   └── verify.yml
            ├── preflight/             # preflight failure scenario
            │   ├── molecule.yml
            │   ├── converge.yml
            │   └── verify.yml
            └── stonith/               # STONITH configuration scenario
                ├── molecule.yml
                ├── converge.yml
                └── verify.yml
```

---

## 4. Variables

### `defaults/main.yml` — overridable per deployment

| Variable | Default | Description |
|---|---|---|
| `drbd_disk_app` | `/dev/sdb1` | Block device for app DRBD resource |
| `drbd_disk_db` | `/dev/sdb2` | Block device for db DRBD resource |
| `drbd_port_app` | `7790` | DRBD replication port for app resource |
| `drbd_port_db` | `7791` | DRBD replication port for db resource |
| `drbd_resource_app` | `mib_npm_ha_drbd_npm` | DRBD resource name for app |
| `drbd_resource_db` | `mib_npm_ha_drbd_db` | DRBD resource name for db |
| `npm_compose_dir` | `/opt/npm/compose` | Docker Compose working directory |
| `npm_mount_app` | `/mnt/npm_app` | OS mount point for app DRBD device |
| `npm_mount_db` | `/mnt/npm_db` | OS mount point for db DRBD device |
| `npm_image_version` | `2.14.0` | NPM Docker image tag |
| `mariadb_image_version` | `10.11` | MariaDB Docker image tag |
| `npm_admin_port` | `15625` | Host port mapped to NPM admin UI (81) |
| `drbd_stop_timeout` | `90s` | Pacemaker stop timeout for DRBD resources |
| `npm_service_timeout` | `120s` | Pacemaker start/stop timeout for npm-stack |
| `cluster_settle_wait` | `15` | Seconds to pause after cluster/resource changes |
| `timezone` | `Africa/Casablanca` | Container timezone |

### `vars/main.yml` — fixed cluster identity

| Variable | Value | Description |
|---|---|---|
| `cluster_name` | `npm_ha_cluster` | Pacemaker cluster name |
| `vip_address` | `192.168.206.220` | Floating VIP |
| `vip_cidr` | `24` | VIP subnet mask |
| `node1_hostname` | `MIBTECH-NPM-PROD-01` | Primary node hostname |
| `node1_ip` | `192.168.206.33` | Primary node IP |
| `node2_hostname` | `MIBTECH-NPM-PROD-02` | Secondary node hostname |
| `node2_ip` | `192.168.206.40` | Secondary node IP |

### `vault_vars/vault.yml` — AES256 encrypted secrets

| Variable | Description |
|---|---|
| `hacluster_password` | Pacemaker `hacluster` OS user password |
| `drbd_secret` | DRBD CRAM-HMAC shared secret |
| `mysql_root_password` | MariaDB root password |
| `mysql_npm_password` | MariaDB npm_adm user password |
| `proxmox_api_host` | Proxmox API hostname/IP |
| `proxmox_api_user` | Proxmox API user (e.g., `root@pam`) |
| `proxmox_api_password` | Proxmox API password |
| `proxmox_node1_vmid` | Proxmox VM ID for node 1 |
| `proxmox_node2_vmid` | Proxmox VM ID for node 2 |

---

## 5. Task Design

### `preflight.yml`
Runs first on all nodes. Fails fast with a clear message if prerequisites are not met.
Checks:
- DRBD kernel module is loadable (`modprobe --dry-run drbd`)
- Block devices `{{ drbd_disk_app }}` and `{{ drbd_disk_db }}` exist on each node
- Inter-node TCP connectivity on `{{ drbd_port_app }}` and `{{ drbd_port_db }}`
- Sufficient free disk space on `/` (>2GB)
- Ansible version >= 2.14

### `prepare.yml`
Unchanged logic. Installs packages, enables Docker + pcsd, sets `hacluster` password, loads DRBD module.

### `drbd.yml`
Unchanged logic. Deploys DRBD config template, initializes metadata idempotently, formats ext4 on first run only.

### `prepare_app.yml`
Unchanged logic. Creates mount points and compose dir, templates `docker-compose.yml`, creates `npm-stack.service` systemd unit. The inline `daemon_reload` task is replaced with `notify: reload systemd` on the service unit copy task.

### `cluster.yml`
Unchanged logic. Idempotency guard via `corosync.conf` content check. Sets `stonith-enabled=false` initially — STONITH is configured separately after cluster is stable.

### `resources.yml`
Unchanged logic. Idempotency guard via `pcs resource config npm_group`. Adds resource timeouts from `defaults/main.yml` variables instead of hardcoded strings.

### `stonith.yml`
New task file. Runs after resources are configured.
- Installs `fence-agents-pve` package
- Creates `fence_pve` STONITH resource for node 1 pointing to node 2's VMID
- Creates `fence_pve` STONITH resource for node 2 pointing to node 1's VMID
- Enables STONITH: `pcs property set stonith-enabled=true`
- Idempotency guard: checks if STONITH resources already exist before creating

---

## 6. Handlers

```yaml
# handlers/main.yml
- name: reload systemd
  systemd:
    daemon_reload: yes

- name: restart pcsd
  systemd:
    name: pcsd
    state: restarted
```

`prepare_app.yml` notifies `reload systemd` when `npm-stack.service` changes.

---

## 7. Execution Tags

| Tag | Tasks covered |
|---|---|
| `preflight` | Pre-flight validation only |
| `prepare` | Package install, service enable |
| `drbd` | DRBD config, init, format |
| `app` | Mounts, compose file, systemd unit |
| `cluster` | Corosync/Pacemaker setup |
| `resources` | Pacemaker resources + constraints |
| `stonith` | fence_pve STONITH setup |

Example day-2 usage:
```bash
# Re-deploy only the app compose config
ansible-playbook main.yml --ask-vault-pass --tags app

# Re-run STONITH setup after Proxmox VM ID change
ansible-playbook main.yml --ask-vault-pass --tags stonith
```

---

## 8. `ansible.cfg`

```ini
[defaults]
inventory         = inventory/hosts
roles_path        = roles
stdout_callback   = yaml
retry_files_enabled = False
host_key_checking = True
timeout           = 30

[ssh_connection]
pipelining        = True
```

---

## 9. `.gitignore`

```
vault_vars/vault.yml
*.retry
```

During initial setup, `vault.yml` is gitignored to prevent accidental commit of plaintext secrets.
Once encrypted with `ansible-vault encrypt vault_vars/vault.yml`, the entry must be removed from
`.gitignore` and the encrypted file committed — AES256-encrypted vault files are safe to version control
and required for the team to run the playbook. The `.retry` entry stays permanently.

---

## 10. Molecule Test Scenarios

### `molecule/default/` — Idempotency
- Driver: `docker` (Debian Bookworm container, mocked DRBD/Pacemaker binaries)
- Converge: run the full role
- Verify: run converge a second time, assert zero changed tasks
- Purpose: catch tasks that are not truly idempotent

### `molecule/preflight/` — Preflight Failure
- Driver: `docker`
- Converge: run role with `drbd_disk_app` set to a non-existent device path
- Verify: assert the play fails at `preflight.yml` with the expected error message
- Purpose: confirm preflight catches missing prerequisites before any changes are made

### `molecule/stonith/` — STONITH Configuration
- Driver: `docker`
- Converge: run role with mock Proxmox credentials and mocked `pcs` binary
- Verify: assert STONITH resources exist and `stonith-enabled=true` is set
- Purpose: confirm STONITH setup is idempotent and correctly parametrized

---

## 11. Security Hardening Summary

| Issue | Resolution |
|---|---|
| Plaintext secrets in `vault.yml` | Encrypt with `ansible-vault encrypt vault_vars/vault.yml` |
| STONITH disabled (split-brain risk) | `fence_pve` STONITH resources added via `stonith.yml` |
| No `.gitignore` | Added — blocks plaintext vault commit |
| Dead code (`tasks/systemd.yml`) | Deleted |
| `ansible.cfg` empty | Replaced with meaningful configuration |

---

## 12. Out of Scope

- Changing cluster topology (2-node assumption stays)
- Migrating from `docker.io` to `docker-ce` (separate concern)
- Adding monitoring/alerting (Wazuh integration is a separate project)
- Multi-environment inventory (single `hosts` file is sufficient for this deployment)
