# NPM Update Role Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the `npm_update` Ansible role — a Pacemaker-aware rolling update for the MIBTECH HA NPM cluster covering OS packages, NPM app image, and MariaDB image with zero uncontrolled downtime.

**Architecture:** Fixed HA orchestration shell (preflight → detect active → update passive → migrate → update old active → cleanup) wrapping a reusable `update_node.yml` called twice with `target_node`. All pcs commands delegate to `node1_name`; node-specific work (apt, docker pull, reboot) is scoped with `when: inventory_hostname == target_node`.

**Tech Stack:** Ansible 2.20, Pacemaker (`pcs`), Docker Compose v2, DRBD (`drbdadm`), systemd, apt.

---

## File Map

| Action | Path | Purpose |
|---|---|---|
| Modify | `inventory/group_vars/ha_nodes/vars.yml` | Add `npm_image_version` + `mariadb_image_version` as authoritative source |
| Modify | `roles/npm_ha/defaults/main.yml` | Add comment; versions remain as fallback defaults |
| Create | `roles/npm_update/meta/main.yml` | Role metadata |
| Create | `roles/npm_update/defaults/main.yml` | Boolean flags + tuning vars |
| Create | `roles/npm_update/tasks/main.yml` | Orchestrator — imports all task files in order |
| Create | `roles/npm_update/tasks/preflight.yml` | Cluster health gate |
| Create | `roles/npm_update/tasks/detect_active.yml` | Sets `_npm_active_node` / `_npm_passive_node` facts |
| Create | `roles/npm_update/tasks/update_node.yml` | Reusable: template + pull + apt + reboot on one node |
| Create | `roles/npm_update/tasks/migrate.yml` | pcs move → wait → verify |
| Create | `roles/npm_update/tasks/cleanup.yml` | pcs clear + final health + prune |
| Create | `npm_update.yml` | Top-level playbook |

---

## Task 1: Version vars + role scaffold

**Files:**
- Modify: `inventory/group_vars/ha_nodes/vars.yml`
- Modify: `roles/npm_ha/defaults/main.yml`
- Create: `roles/npm_update/meta/main.yml`
- Create: `roles/npm_update/defaults/main.yml`
- Create: `npm_update.yml`

- [ ] **Step 1: Add version vars to group_vars**

Add to the bottom of `inventory/group_vars/ha_nodes/vars.yml`:

```yaml
# Container image versions — authoritative source for both npm_ha and npm_update roles.
# Bump these values here, then run npm_update.yml to apply.
npm_image_version: "2.15.1"
mariadb_image_version: "10.11.16"
```

- [ ] **Step 2: Comment the fallback in npm_ha defaults**

In `roles/npm_ha/defaults/main.yml`, replace the version lines:

```yaml
# Container image versions (pinned)
# Authoritative values live in group_vars/ha_nodes/vars.yml.
# These defaults act as fallback for molecule/isolated test runs only.
npm_image_version: "2.15.1"
mariadb_image_version: "10.11.16"
```

- [ ] **Step 3: Create role directories**

```bash
mkdir -p roles/npm_update/{defaults,meta,tasks}
```

- [ ] **Step 4: Write meta/main.yml**

```yaml
---
galaxy_info:
  author: HICHAM KARABANE
  description: HA-aware rolling update for MIBTECH NPM cluster — OS packages, app image, MariaDB image
  license: MIT
  min_ansible_version: "2.14"
  platforms:
    - name: Debian
      versions:
        - trixie
dependencies: []
```

- [ ] **Step 5: Write defaults/main.yml**

```yaml
---
# What to update — all false by default, caller enables what's needed.
# At least one must be true or preflight will abort.
npm_update_os: false
npm_update_app: false
npm_update_db: false
npm_update_prune: true

# Migration health check tuning
npm_update_migrate_retries: 24    # × npm_update_migrate_delay = 4 min max
npm_update_migrate_delay: 10
npm_update_port_timeout: 120      # seconds to wait for VIP TCP port

# Reboot + DRBD resync tuning
npm_update_reboot_timeout: 300    # seconds to wait for SSH after reboot
npm_update_drbd_sync_retries: 60  # × npm_update_drbd_sync_delay = 30 min max
npm_update_drbd_sync_delay: 30
```

- [ ] **Step 6: Write npm_update.yml playbook**

```yaml
---
- name: Rolling update of MIBTECH HA NPM cluster
  hosts: ha_nodes
  become: true
  gather_facts: true
  roles:
    - role: npm_update
```

- [ ] **Step 7: Syntax-check**

```bash
ansible-playbook npm_update.yml --syntax-check
```

Expected: `playbook: npm_update.yml` with no errors (role tasks don't exist yet but scaffold should parse).

- [ ] **Step 8: Commit**

```bash
git add inventory/group_vars/ha_nodes/vars.yml \
        roles/npm_ha/defaults/main.yml \
        roles/npm_update/ \
        npm_update.yml
git commit -m "feat: scaffold npm_update role with defaults and playbook"
```

---

## Task 2: preflight.yml

**Files:**
- Create: `roles/npm_update/tasks/preflight.yml`

- [ ] **Step 1: Write preflight.yml**

```yaml
---
- name: Assert at least one update type is selected
  assert:
    that: npm_update_os | bool or npm_update_app | bool or npm_update_db | bool
    fail_msg: >
      Nothing to do. Set at least one of:
      npm_update_os=true, npm_update_app=true, npm_update_db=true
  run_once: true
  delegate_to: localhost

- name: Get cluster node status
  command: pcs status nodes corosync
  register: pcs_nodes_status
  changed_when: false
  run_once: true
  delegate_to: "{{ node1_name }}"

- name: Assert both nodes are online
  assert:
    that:
      - node1_name in pcs_nodes_status.stdout
      - node2_name in pcs_nodes_status.stdout
    fail_msg: >
      Not all cluster nodes are online.
      Expected {{ node1_name }} and {{ node2_name }} in corosync output.
      Got: {{ pcs_nodes_status.stdout }}
  run_once: true
  delegate_to: "{{ node1_name }}"

- name: Get full cluster status
  command: pcs status --full
  register: pcs_full_status
  changed_when: false
  run_once: true
  delegate_to: "{{ node1_name }}"

- name: Assert no failed resource actions
  assert:
    that: "'Failed Resource Actions' not in pcs_full_status.stdout"
    fail_msg: >
      Pacemaker reports failed resource actions. Resolve before updating.
      Run `pcs resource cleanup` and check `pcs status --full`.
  run_once: true
  delegate_to: "{{ node1_name }}"

- name: Get resource status
  command: pcs status resources
  register: pcs_resources_status
  changed_when: false
  run_once: true
  delegate_to: "{{ node1_name }}"

- name: Assert npm_service is started
  assert:
    that: "'npm_service' in pcs_resources_status.stdout and 'Started' in pcs_resources_status.stdout"
    fail_msg: >
      npm_service is not in Started state. Check `pcs status resources`.
  run_once: true
  delegate_to: "{{ node1_name }}"

- name: Get DRBD status
  command: drbdadm status all
  register: drbd_preflight_status
  changed_when: false
  run_once: true
  delegate_to: "{{ node1_name }}"

- name: Assert DRBD is healthy
  assert:
    that:
      - "'Inconsistent' not in drbd_preflight_status.stdout"
      - "'Diskless' not in drbd_preflight_status.stdout"
    fail_msg: >
      DRBD is not healthy (Inconsistent or Diskless state detected).
      Wait for DRBD to finish syncing before updating.
      Run `drbdadm status all` to check.
  run_once: true
  delegate_to: "{{ node1_name }}"
```

- [ ] **Step 2: Write a placeholder tasks/main.yml to import preflight**

```yaml
---
- name: Pre-flight checks
  import_tasks: preflight.yml
```

- [ ] **Step 3: Syntax-check**

```bash
ansible-playbook npm_update.yml --syntax-check
```

Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add roles/npm_update/tasks/preflight.yml roles/npm_update/tasks/main.yml
git commit -m "feat: add npm_update preflight checks"
```

---

## Task 3: detect_active.yml

**Files:**
- Create: `roles/npm_update/tasks/detect_active.yml`
- Modify: `roles/npm_update/tasks/main.yml`

- [ ] **Step 1: Write detect_active.yml**

```yaml
---
- name: Get npm_service resource status
  command: pcs status resources
  register: _pcs_resources_raw
  changed_when: false
  run_once: true
  delegate_to: "{{ node1_name }}"

- name: Broadcast active and passive node facts to all hosts
  set_fact:
    _npm_active_node: >-
      {{ hostvars[node1_name]._pcs_resources_raw.stdout
         | regex_search('npm_service.*Started\s+(\S+)', '\1')
         | first }}
    _npm_passive_node: >-
      {{ node2_name
         if (hostvars[node1_name]._pcs_resources_raw.stdout
             | regex_search('npm_service.*Started\s+(\S+)', '\1')
             | first) == node1_name
         else node1_name }}

- name: Assert active node is a known cluster member
  assert:
    that: _npm_active_node in [node1_name, node2_name]
    fail_msg: >
      Could not determine active node from pcs output.
      Parsed: '{{ _npm_active_node }}'.
      Full output: {{ hostvars[node1_name]._pcs_resources_raw.stdout }}
  run_once: true
  delegate_to: "{{ node1_name }}"

- name: Report active and passive nodes
  debug:
    msg: "Active node: {{ _npm_active_node }} | Passive node: {{ _npm_passive_node }}"
  run_once: true
  delegate_to: "{{ node1_name }}"
```

- [ ] **Step 2: Update tasks/main.yml**

```yaml
---
- name: Pre-flight checks
  import_tasks: preflight.yml

- name: Detect active and passive nodes
  import_tasks: detect_active.yml
```

- [ ] **Step 3: Syntax-check**

```bash
ansible-playbook npm_update.yml --syntax-check
```

Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add roles/npm_update/tasks/detect_active.yml roles/npm_update/tasks/main.yml
git commit -m "feat: add npm_update active node detection"
```

---

## Task 4: update_node.yml

**Files:**
- Create: `roles/npm_update/tasks/update_node.yml`
- Modify: `roles/npm_update/tasks/main.yml`

The `docker-compose.yml.j2` template lives in `roles/npm_ha/templates/`. Reference it
via `playbook_dir` to avoid duplicating it.

The docker inspect `--format` string uses Go template syntax `{{.Config.Image}}` which
conflicts with Jinja2. Use `!unsafe` to prevent Ansible from processing it as a template.

- [ ] **Step 1: Write update_node.yml**

```yaml
---
# Called with: target_node=<hostname>
# Node-specific tasks: when: inventory_hostname == target_node
# Cluster-wide checks (pcs, drbdadm) after reboot: delegate to the OTHER node

- name: "Re-template docker-compose.yml on {{ target_node }}"
  template:
    src: "{{ playbook_dir }}/roles/npm_ha/templates/docker-compose.yml.j2"
    dest: "{{ npm_compose_dir }}/docker-compose.yml"
    owner: root
    group: root
    mode: '0600'
  when:
    - inventory_hostname == target_node
    - npm_update_app | bool or npm_update_db | bool

- name: "Pull NPM app image on {{ target_node }}"
  command: docker compose -f {{ npm_compose_dir }}/docker-compose.yml pull app
  when:
    - inventory_hostname == target_node
    - npm_update_app | bool
  changed_when: true

- name: "Pull MariaDB image on {{ target_node }}"
  command: docker compose -f {{ npm_compose_dir }}/docker-compose.yml pull db
  when:
    - inventory_hostname == target_node
    - npm_update_db | bool
  changed_when: true

- name: "Update apt cache on {{ target_node }}"
  apt:
    update_cache: true
    cache_valid_time: 0
  when:
    - inventory_hostname == target_node
    - npm_update_os | bool

- name: "Upgrade packages on {{ target_node }}"
  apt:
    upgrade: safe
  when:
    - inventory_hostname == target_node
    - npm_update_os | bool
  register: _apt_upgrade_result

- name: "Check if reboot is required on {{ target_node }}"
  stat:
    path: /var/run/reboot-required
  register: _reboot_required
  when:
    - inventory_hostname == target_node
    - npm_update_os | bool

- name: "Reboot {{ target_node }} (kernel or libc updated)"
  reboot:
    reboot_timeout: "{{ npm_update_reboot_timeout }}"
  when:
    - inventory_hostname == target_node
    - npm_update_os | bool
    - _reboot_required.stat is defined
    - _reboot_required.stat.exists

- name: "Wait for {{ target_node }} to rejoin Pacemaker after reboot"
  command: pcs status nodes corosync
  register: _corosync_post_reboot
  until: target_node in _corosync_post_reboot.stdout
  retries: 30
  delay: 10
  changed_when: false
  run_once: true
  delegate_to: "{{ node2_name if target_node == node1_name else node1_name }}"
  when:
    - npm_update_os | bool
    - _reboot_required.stat is defined
    - _reboot_required.stat.exists

- name: "Wait for DRBD to finish syncing on {{ target_node }} after reboot"
  command: drbdadm status all
  register: _drbd_post_reboot
  until: >-
    'Inconsistent' not in _drbd_post_reboot.stdout
    and 'Diskless' not in _drbd_post_reboot.stdout
  retries: "{{ npm_update_drbd_sync_retries }}"
  delay: "{{ npm_update_drbd_sync_delay }}"
  changed_when: false
  when:
    - inventory_hostname == target_node
    - npm_update_os | bool
    - _reboot_required.stat is defined
    - _reboot_required.stat.exists
```

- [ ] **Step 2: Update tasks/main.yml**

```yaml
---
- name: Pre-flight checks
  import_tasks: preflight.yml

- name: Detect active and passive nodes
  import_tasks: detect_active.yml

- name: "Update passive node {{ _npm_passive_node }}"
  include_tasks: update_node.yml
  vars:
    target_node: "{{ _npm_passive_node }}"
```

Note: `include_tasks` (not `import_tasks`) is required here because `_npm_passive_node`
is a fact set at runtime — `import_tasks` resolves `vars` at parse time and would fail.

- [ ] **Step 3: Syntax-check**

```bash
ansible-playbook npm_update.yml --syntax-check
```

Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add roles/npm_update/tasks/update_node.yml roles/npm_update/tasks/main.yml
git commit -m "feat: add npm_update node update tasks (image pull, OS upgrade, reboot)"
```

---

## Task 5: migrate.yml

**Files:**
- Create: `roles/npm_update/tasks/migrate.yml`
- Modify: `roles/npm_update/tasks/main.yml`

- [ ] **Step 1: Write migrate.yml**

```yaml
---
- name: Move npm_group to passive node
  command: pcs resource move npm_group {{ _npm_passive_node }}
  run_once: true
  delegate_to: "{{ node1_name }}"
  changed_when: true

- name: Wait for npm_service to start on {{ _npm_passive_node }}
  command: pcs status resources
  register: _migrate_status
  until: >-
    'npm_service' in _migrate_status.stdout
    and 'Started ' + _npm_passive_node in _migrate_status.stdout
  retries: "{{ npm_update_migrate_retries }}"
  delay: "{{ npm_update_migrate_delay }}"
  changed_when: false
  run_once: true
  delegate_to: "{{ node1_name }}"
  failed_when: >-
    _migrate_status.attempts | default(0) >= npm_update_migrate_retries
    and ('Started ' + _npm_passive_node) not in _migrate_status.stdout

- name: Assert migration succeeded
  assert:
    that: "'Started ' + _npm_passive_node in _migrate_status.stdout"
    fail_msg: >
      Migration failed — npm_group did not start on {{ _npm_passive_node }}
      within {{ npm_update_migrate_retries * npm_update_migrate_delay }}s.
      RECOVERY: Run `pcs resource clear npm_group` then `pcs resource cleanup npm_group`.
      Old active node {{ _npm_active_node }} is unmodified and still healthy.
  run_once: true
  delegate_to: "{{ node1_name }}"

- name: Wait for NPM to accept connections on VIP
  wait_for:
    host: "{{ vip_address }}"
    port: "{{ npm_admin_port }}"
    timeout: "{{ npm_update_port_timeout }}"
  run_once: true
  delegate_to: localhost

- name: Verify npm_app container is running the new image
  command: !unsafe "docker inspect npm_app --format '{{.Config.Image}}'"
  register: _npm_app_image
  changed_when: false
  run_once: true
  delegate_to: "{{ _npm_passive_node }}"
  when: npm_update_app | bool

- name: Assert npm_app image matches target version
  assert:
    that: npm_image_version in _npm_app_image.stdout
    fail_msg: >
      Container is running '{{ _npm_app_image.stdout }}' but expected
      image tag to contain '{{ npm_image_version }}'.
  run_once: true
  delegate_to: "{{ node1_name }}"
  when: npm_update_app | bool
```

- [ ] **Step 2: Update tasks/main.yml**

```yaml
---
- name: Pre-flight checks
  import_tasks: preflight.yml

- name: Detect active and passive nodes
  import_tasks: detect_active.yml

- name: "Update passive node {{ _npm_passive_node }}"
  include_tasks: update_node.yml
  vars:
    target_node: "{{ _npm_passive_node }}"

- name: Migrate npm_group to updated passive node
  import_tasks: migrate.yml
```

- [ ] **Step 3: Syntax-check**

```bash
ansible-playbook npm_update.yml --syntax-check
```

Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add roles/npm_update/tasks/migrate.yml roles/npm_update/tasks/main.yml
git commit -m "feat: add npm_update Pacemaker migration with health verification"
```

---

## Task 6: cleanup.yml

**Files:**
- Create: `roles/npm_update/tasks/cleanup.yml`
- Modify: `roles/npm_update/tasks/main.yml` (final form)

- [ ] **Step 1: Write cleanup.yml**

```yaml
---
- name: Clear forced location constraint from migration
  command: pcs resource clear npm_group
  run_once: true
  delegate_to: "{{ node1_name }}"
  changed_when: true

- name: Reset Pacemaker error counts
  command: pcs resource cleanup npm_group
  run_once: true
  delegate_to: "{{ node1_name }}"
  changed_when: false

- name: Wait for cluster to report no failed actions
  command: pcs status --full
  register: _cleanup_status
  until: "'Failed Resource Actions' not in _cleanup_status.stdout"
  retries: 12
  delay: 10
  changed_when: false
  run_once: true
  delegate_to: "{{ node1_name }}"

- name: Wait for DRBD to finish syncing on both nodes
  command: drbdadm status all
  register: _drbd_final
  until: >-
    'Inconsistent' not in _drbd_final.stdout
    and 'Diskless' not in _drbd_final.stdout
  retries: "{{ npm_update_drbd_sync_retries }}"
  delay: "{{ npm_update_drbd_sync_delay }}"
  changed_when: false
  run_once: true
  delegate_to: "{{ node1_name }}"

- name: Prune old Docker images on all nodes
  command: docker image prune -f
  changed_when: true
  when: npm_update_prune | bool

- name: Report final cluster state
  command: pcs status resources
  register: _final_pcs_status
  changed_when: false
  run_once: true
  delegate_to: "{{ node1_name }}"

- name: Show final cluster state
  debug:
    msg: "{{ _final_pcs_status.stdout }}"
  run_once: true
  delegate_to: "{{ node1_name }}"
```

- [ ] **Step 2: Write final tasks/main.yml**

```yaml
---
- name: Pre-flight checks
  import_tasks: preflight.yml

- name: Detect active and passive nodes
  import_tasks: detect_active.yml

- name: "Update passive node {{ _npm_passive_node }}"
  include_tasks: update_node.yml
  vars:
    target_node: "{{ _npm_passive_node }}"

- name: Migrate npm_group to updated passive node
  import_tasks: migrate.yml

- name: "Update old active node {{ _npm_active_node }}"
  include_tasks: update_node.yml
  vars:
    target_node: "{{ _npm_active_node }}"

- name: Cleanup and verify
  import_tasks: cleanup.yml
```

- [ ] **Step 3: Syntax-check and lint**

```bash
ansible-playbook npm_update.yml --syntax-check
ansible-lint roles/npm_update/ npm_update.yml
```

Expected: `playbook: npm_update.yml` no errors; lint passes with 0 failures.

- [ ] **Step 4: Commit**

```bash
git add roles/npm_update/tasks/cleanup.yml roles/npm_update/tasks/main.yml
git commit -m "feat: add npm_update cleanup, DRBD wait, image prune, final report"
```

---

## Task 7: Live validation — app update run

Now that the pending `pcs resource restart npm_group` from the earlier NPM 2.15.1 update
is still outstanding (the pre-pull completed but the container restart was never done),
run `npm_update.yml` with `npm_update_app=true` as the first real test. This exercises the
full flow against the real cluster.

Precondition: `npm_image_version` in `group_vars/ha_nodes/vars.yml` is `2.15.1` (already
set this session). The running container on MIBTECH-NPM-PROD-02 is still `2.14.0`.

- [ ] **Step 1: Dry-run the preflight and detection only (check mode)**

```bash
ansible-playbook npm_update.yml -e npm_update_app=true --check 2>&1 | head -40
```

Expected: preflight passes, active/passive nodes detected and printed, then check-mode
skips through remaining tasks (or errors on shell/command modules that don't support check
mode — both outcomes confirm the role is being exercised).

- [ ] **Step 2: Run for real**

```bash
ansible-playbook npm_update.yml -e npm_update_app=true 2>&1 | tee /tmp/npm_update_run1.log
echo "EXIT=${PIPESTATUS[0]}"
```

Expected flow:
- Preflight: all green
- Detect: active=MIBTECH-NPM-PROD-02, passive=MIBTECH-NPM-PROD-01
- Update passive (01): re-template compose → pull `jc21/nginx-proxy-manager:2.15.1`
- Migrate: npm_group moves to NPM-PROD-01, VIP follows, API port reachable, container
  image verified as 2.15.1
- Update old active (02): re-template compose → pull 2.15.1
- Cleanup: pcs clear, cleanup, DRBD healthy, image prune, final status printed
- EXIT=0

- [ ] **Step 3: Verify container version on active node**

```bash
ssh debian@192.168.206.33 "sudo docker inspect npm_app --format '{{.Config.Image}}' 2>/dev/null || echo 'not running here'" 2>&1
ssh debian@192.168.206.40 "sudo docker inspect npm_app --format '{{.Config.Image}}' 2>/dev/null || echo 'not running here'" 2>&1
```

Expected: one node returns `jc21/nginx-proxy-manager:2.15.1`, the other `not running here`.

- [ ] **Step 4: Commit final state**

```bash
git add roles/npm_update/ npm_update.yml \
        inventory/group_vars/ha_nodes/vars.yml \
        roles/npm_ha/defaults/main.yml
git commit -m "feat: implement npm_update HA rolling update role

Pacemaker-aware rolling update covering OS packages, NPM app image,
and MariaDB image. Uses pcs resource move/clear for zero-downtime
migration, auto-reboot on kernel updates, and boolean flags to select
update scope per run. Verified live against MIBTECH-NPM-PROD-01/02."
```
