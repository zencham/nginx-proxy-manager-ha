# NPM HA Update Role Design

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** An `npm_update` Ansible role that performs zero-downtime (one brief failover) updates of any combination of OS packages, NPM app image, and MariaDB image on the MIBTECH HA NPM cluster, using Pacemaker-aware migration to ensure no data loss and no uncontrolled restarts.

**Architecture:** The role wraps a fixed HA orchestration shell (preflight → detect active → update passive → migrate → update old active → cleanup) around a reusable `update_node.yml` task file that is called twice — once per node — with a `target_node` variable. All Pacemaker operations are cluster-wide (delegated to node1). Node-specific tasks (apt, docker pull, reboot) are scoped with `when: inventory_hostname == target_node`.

**Tech Stack:** Ansible, Pacemaker (`pcs`), Docker Compose, DRBD (`drbdadm`), systemd (`npm-stack.service`), apt.

---

## Existing Files Modified

- `inventory/group_vars/ha_nodes/vars.yml` — add `npm_image_version` and `mariadb_image_version` (moved from `npm_ha/defaults/main.yml`; group_vars is the authoritative source so both roles read the same values)
- `roles/npm_ha/defaults/main.yml` — keep version vars as fallback defaults only (for molecule/isolated contexts where group_vars may not be set; group_vars take precedence at runtime)

## New Files Created

```
roles/npm_update/
├── defaults/main.yml
├── meta/main.yml
└── tasks/
    ├── main.yml
    ├── preflight.yml
    ├── detect_active.yml
    ├── update_node.yml
    ├── migrate.yml
    └── cleanup.yml
npm_update.yml
```

---

## Variables

### Invocation flags — all default `false`, caller sets what's needed

| Variable | Default | Purpose |
|---|---|---|
| `npm_update_os` | `false` | Run `apt-get upgrade` + auto-reboot if kernel changed |
| `npm_update_app` | `false` | Re-template compose + pull `jc21/nginx-proxy-manager:{{ npm_image_version }}` |
| `npm_update_db` | `false` | Re-template compose + pull `mariadb:{{ mariadb_image_version }}` |
| `npm_update_prune` | `true` | `docker image prune -f` on both nodes after successful run |

At least one flag must be `true` — preflight fails fast otherwise.

### Tuning vars (in `npm_update/defaults/main.yml`)

| Variable | Default | Purpose |
|---|---|---|
| `npm_update_migrate_retries` | `24` | Retries waiting for npm_group to start on new node |
| `npm_update_migrate_delay` | `10` | Seconds between retries (24 × 10 = 4 min max) |
| `npm_update_port_timeout` | `120` | Seconds to wait for VIP TCP port after migrate |
| `npm_update_reboot_timeout` | `300` | Seconds to wait for SSH after passive node reboot |
| `npm_update_drbd_sync_retries` | `60` | Retries waiting for DRBD UpToDate after reboot |
| `npm_update_drbd_sync_delay` | `30` | Seconds between DRBD retries (60 × 30 = 30 min max) |

### Version vars (authoritative in `group_vars/ha_nodes/vars.yml`)

| Variable | Example | Purpose |
|---|---|---|
| `npm_image_version` | `"2.15.1"` | Target NPM container image tag |
| `mariadb_image_version` | `"10.11.16"` | Target MariaDB container image tag |

To update, bump the value in `group_vars/ha_nodes/vars.yml` and run `npm_update.yml`.

---

## Update Sequence

### `npm_update.yml` (top-level playbook)
```yaml
- hosts: ha_nodes
  become: true
  gather_facts: true
  roles:
    - role: npm_update
```

### `tasks/main.yml` — orchestrator
```
import preflight.yml
import detect_active.yml
include update_node.yml  with target_node={{ _npm_passive_node }}
import migrate.yml
include update_node.yml  with target_node={{ _npm_active_node }}
import cleanup.yml
```

### `tasks/preflight.yml`
- Assert `npm_update_os or npm_update_app or npm_update_db` — fail with usage hint if all false
- Assert both nodes online: `pcs status nodes corosync` contains both node names
- Assert no failed resource actions: `pcs status --full` does not contain `Failed Resource Actions`
- Assert npm_group is Started: `pcs status resources` contains `npm_service.*Started`
- Assert DRBD healthy: `drbdadm status all` contains neither `Inconsistent` nor `Diskless`
- All assertions `run_once: true`, `delegate_to: {{ node1_name }}`

### `tasks/detect_active.yml`
- `run_once: true`, `delegate_to: {{ node1_name }}`
- Shell: `pcs status resources | grep 'npm_service'`
- Parse output with regex to extract node name after `Started`
- Set fact `_npm_active_node` = matched node name
- Set fact `_npm_passive_node` = the other node (node1_name if active is node2, else node2_name)
- Assert `_npm_active_node in [node1_name, node2_name]` — fail if parse produces unexpected value

### `tasks/update_node.yml` — called with `target_node`
Node-specific tasks (template, pull, apt, reboot, wait_for_connection):
`when: inventory_hostname == target_node`

Cluster-wide checks after reboot (pcs node Online, DRBD status):
`run_once: true`, `delegate_to: {{ node1_name }}`, but `until` condition
references `target_node` by name so it correctly waits for that specific
node rather than the cluster as a whole.

```
IF npm_update_app or npm_update_db:
  - Template docker-compose.yml to {{ npm_compose_dir }}/docker-compose.yml
    [when: inventory_hostname == target_node]

IF npm_update_app:
  - docker compose -f {{ npm_compose_dir }}/docker-compose.yml pull app
    [when: inventory_hostname == target_node]

IF npm_update_db:
  - docker compose -f {{ npm_compose_dir }}/docker-compose.yml pull db
    [when: inventory_hostname == target_node]

IF npm_update_os:
  - apt-get update + apt-get upgrade -y
    [when: inventory_hostname == target_node]
  - stat /var/run/reboot-required → register reboot_required
    [when: inventory_hostname == target_node]
  IF reboot_required.stat.exists:
    - reboot
      [when: inventory_hostname == target_node]
    - wait_for_connection: timeout={{ npm_update_reboot_timeout }}
      [when: inventory_hostname == target_node]
    - Wait until pcs status nodes shows target_node Online
      [run_once: true, delegate_to: node1_name, until/retries]
    - Wait until drbdadm status all shows no Inconsistent/Diskless
      (retries={{ npm_update_drbd_sync_retries }}, delay={{ npm_update_drbd_sync_delay }})
```

Note: on the passive node, DRBD is Secondary/UpToDate with no mounts active. `docker compose pull` works because `{{ npm_compose_dir }}` (`/opt/npm/compose`) is on local disk, not DRBD.

### `tasks/migrate.yml`
- `run_once: true`, delegate pcs commands to `{{ node1_name }}`
- `pcs resource move npm_group {{ _npm_passive_node }}`
- Wait until `pcs status resources` shows `npm_service.*Started.*{{ _npm_passive_node }}`
  (retries={{ npm_update_migrate_retries }}, delay={{ npm_update_migrate_delay }})
  — on timeout: fail with message "Migration failed. npm_group did not start on {{ _npm_passive_node }}. Run `pcs resource clear npm_group` to restore Pacemaker placement. Old active node {{ _npm_active_node }} is unmodified."
- `wait_for: host={{ vip_address }} port={{ npm_admin_port }} timeout={{ npm_update_port_timeout }}`
  — VIP TCP reachable confirms NPM container is up and nginx is listening
- Verify container image on new active: `docker inspect npm_app --format '{% raw %}{{.Config.Image}}{% endraw %}'`
  delegated to `_npm_passive_node`, assert result contains `npm_image_version`
  (only when `npm_update_app: true`)

### `tasks/cleanup.yml`
- `pcs resource clear npm_group` — removes forced location constraint from migrate step; Pacemaker now manages placement freely (resource stays where it is unless failure occurs)
- `pcs resource cleanup npm_group` — resets error counts and failure history
- Wait: `pcs status --full` contains no `Failed Resource Actions`
- Wait: `drbdadm status all` shows no `Inconsistent` or `Diskless` on either node
- If `npm_update_prune`: `docker image prune -f` on both nodes (runs on all ha_nodes, no delegation needed)

---

## Error Handling

| Failure point | State at failure | Recovery |
|---|---|---|
| Preflight | Cluster untouched | Fix the reported condition and re-run |
| Passive node update | Cluster untouched, passive node may need manual cleanup | Fix and re-run; safe to re-run `update_node.yml` tasks are idempotent |
| Migration timeout | npm_group still on old active, new node may have failed resource | `pcs resource clear npm_group` then `pcs resource cleanup npm_group` |
| Old active update (post-migration) | npm_group healthy on new active; old active needs manual fix | Fix old active, run `pcs resource clear npm_group` to unlock placement |
| Cleanup / pcs clear | npm_group healthy but sticky location constraint remains | Manually run `pcs resource clear npm_group` |

No automatic rollback on migration failure. The old active is untouched at that point and Pacemaker will fail back naturally once the constraint is cleared.

---

## Invocation Examples

```bash
# App image bump (most common)
ansible-playbook npm_update.yml -e npm_update_app=true

# App + DB images together
ansible-playbook npm_update.yml -e "npm_update_app=true npm_update_db=true"

# OS packages only (security patches)
ansible-playbook npm_update.yml -e npm_update_os=true

# Full stack (major maintenance window)
ansible-playbook npm_update.yml -e "npm_update_os=true npm_update_app=true npm_update_db=true"
```

---

## What This Role Does NOT Do

- Does not modify Pacemaker cluster topology or resource constraints beyond the temporary migrate/clear cycle
- Does not manage Docker Engine upgrades (install/update of docker-ce itself)
- Does not manage MariaDB schema migrations — those are handled by NPM on first start
- Does not pin images to digests — version tags are used as-is
