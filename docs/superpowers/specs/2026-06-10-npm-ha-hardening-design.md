# NPM HA Role — Hardening Pass Design

## Overview

Following the enterprise overhaul on `feature/npm-ha-role-overhaul`, a live
verification pass against both production nodes (MIBTECH-NPM-PROD-01/02)
produced a 21-item findings report covering one undefined-variable bug, one
syntax-compatibility question, security exposure, operational gaps, and
optimizations. This spec defines the fixes for that report, to be implemented
on the same branch.

**Critical #2 (pcs 0.12 syntax audit) is resolved by live verification — no
code change required.** Confirmed on MIBTECH-NPM-PROD-01:
`pcs resource update <id> op <action> timeout=Xs` correctly updates operation
timeouts under pcs 0.12.0.2-1 — `drbd_app`'s stop timeout shows
`timeout=90s` and `npm_service`'s start/stop timeouts both show `timeout=120s`,
matching the role's defaults. The existing `cluster.yml`/`resources.yml`
syntax is compatible as-is.

## Scope Decisions

- **Gap #7 (firewall rules)**: documentation-only. Neither `ufw` nor
  `firewalld` is present on either node; `nft`/`iptables` only contain
  Docker-managed chains. Adding host firewall rules to a live 2-node
  Corosync/DRBD cluster risks blocking cluster heartbeat or DRBD replication
  traffic and causing split-brain. Out of scope for an Ansible role targeting
  hosts with no firewall framework — document required ports in README for
  whoever manages the perimeter/host firewall instead.
- **Enhancement #21 (Docker CE migration)**: documentation-only. Both nodes
  currently run `docker.io` (Debian package). Swapping to `docker-ce` on
  already-deployed nodes requires careful in-place package replacement
  (conflicting packages, daemon restart) — too risky for this pass. Note as a
  future consideration in README.
- **Enhancements #16/#17/#18** restate Gaps #5/#9/#11 — folded into those
  items, not duplicated.
- **Enhancement #19** (`.ansible-lint` config) and **#20** (explicit Docker
  network) are small and in scope.

## Implementation Tasks

Grouped by file/theme so each task is a coherent, reviewable unit. Order
follows severity: critical → security → gaps → optimizations → enhancements.

### Task 1 — DRBD task hardening (`roles/npm_ha/tasks/drbd.yml`, `roles/npm_ha/templates/npm-ha.res.j2`, `roles/npm_ha/defaults/main.yml`)

**Critical #1 — fix `drbd_init` undefined variable.** `drbd_init` is only
registered when `drbd_md_check.rc != 0`. On every re-run against the
already-deployed nodes (`drbd_md_check.rc == 0`), referencing
`drbd_init.changed` raises `AnsibleUndefinedVariable` and halts the play. Add
`| default(false)` to all 4 occurrences:
- "Bring DRBD resources up": `when: drbd_init.changed | default(false) or drbd_md_check.rc != 0`
- "Force primary role on node 1 to initiate first sync": `when: drbd_init.changed | default(false)`
- "Format app DRBD device as ext4": `when: drbd_init.changed | default(false)`
- "Format db DRBD device as ext4": `when: drbd_init.changed | default(false)`

**Gap #8 — wait for DRBD device nodes before formatting.** After
`drbdadm primary --force all`, the kernel attaches `/dev/drbd10`/`/dev/drbd11`
asynchronously. Add `wait_for: path: <device> timeout: 60` for both devices
(gated on the same `drbd_init.changed | default(false)` condition), placed
after the "Force primary role" task and before the two `filesystem` tasks.

**Gap #10 — DRBD sync rate limiting.** `npm-ha.res.j2` has no resync rate
control, so initial full sync after `drbdadm primary --force all` can
saturate the replication link. Add a new default
`drbd_resync_rate: "10M"` to `defaults/main.yml`, and add to both resource
blocks in `npm-ha.res.j2`:

```
disk {
  resync-rate {{ drbd_resync_rate }};
}
```

(DRBD 9's `disk { resync-rate ... }` is the current syntax; the legacy
top-level `syncer { rate ... }` block is deprecated.)

### Task 2 — Prepare/app/security hardening (`roles/npm_ha/tasks/prepare.yml`, `roles/npm_ha/tasks/prepare_app.yml`, `roles/npm_ha/templates/docker-compose.yml.j2`)

**Security #4 — `no_log` on password task.** "Set hacluster user password" in
`prepare.yml` logs the hashed password to Ansible output. Add `no_log: true`.

**Security #5 — disable `pacemaker_remote`.** Verified live: the `pacemaker`
package enables `pacemaker_remote.service` (currently `enabled`/`inactive` on
both nodes). It's unused in this full-cluster (non-Pacemaker-Remote)
topology and listens on tcp/3121 if started. Add to `prepare.yml`:

```yaml
- name: Ensure pacemaker_remote service is disabled (unused in this topology)
  systemd:
    name: pacemaker_remote
    state: stopped
    enabled: no
```

**Gap #6 — apt cache freshness.** Add `cache_valid_time: 3600` to the
"Install prerequisite packages" apt task in `prepare.yml`.

**Gap #11 — `/etc/hosts` entries.** Verified live: `/etc/hosts` only has
loopback entries; cluster/DRBD configs use IPs directly so this isn't
functionally required, but it aids troubleshooting (ssh/logs by hostname).
Add to `prepare.yml` (runs before `cluster.yml`):

```yaml
- name: Ensure cluster node hostnames are resolvable via /etc/hosts
  ansible.builtin.lineinfile:
    path: /etc/hosts
    line: "{{ item.ip }} {{ item.hostname }}"
    regexp: "^[0-9.]+\\s+{{ item.hostname }}\\s*$"
    state: present
  loop:
    - { ip: "{{ node1_ip }}", hostname: "{{ node1_hostname }}" }
    - { ip: "{{ node2_ip }}", hostname: "{{ node2_hostname }}" }
```

**Security #3 — secret file permissions + healthcheck exposure.** Verified
live: `docker-compose.yml` is templated with `mode: '0644'`
(world-readable) and contains plaintext `MARIADB_ROOT_PASSWORD`/
`MARIADB_PASSWORD`. Tighten to `mode: '0600'` in `prepare_app.yml`'s
"Template docker-compose.yml to nodes" task. Also tighten
`/etc/drbd.d/npm-ha.res` (contains `drbd_secret`) to `mode: '0600'` in
`drbd.yml`'s "Deploy DRBD configuration file" task (part of Task 1's file,
but listed here since it's the same theme — implementer should make this
one-line change in `drbd.yml` as part of Task 1 instead to keep file edits
grouped; noted here for completeness of the security review).

In `docker-compose.yml.j2`, change the `db` healthcheck from
`--password={{ mysql_root_password }}` (plaintext CLI arg, visible via
`ps`/`docker top`) to the `MYSQL_PWD` env-var convention:

```yaml
healthcheck:
  test: ["CMD-SHELL", "MYSQL_PWD=$$MARIADB_ROOT_PASSWORD mariadb-admin ping --silent || exit 1"]
```

(`$$` escapes to a literal `$` for the container's shell, per Compose
variable-interpolation rules; `MARIADB_ROOT_PASSWORD` is already set in the
container's `environment:` block.)

**Enhancement #20 — explicit Docker network.** Currently Compose
auto-creates `compose_default`. Add a named network for clarity:

```yaml
networks:
  npm_ha_net:
    name: npm_ha_net
    driver: bridge
```

at the top level, and `networks: [npm_ha_net]` to both the `db` and `app`
services.

### Task 3 — Cluster setup hardening (`roles/npm_ha/tasks/cluster.yml`)

**Optimization #13 — retry `pcs host auth`.** Add `register`, `until`,
`retries: 3`, `delay: 5` to "Authenticate cluster nodes" in case `pcsd` on
the peer isn't ready yet. Also add `no_log: true` (it includes
`-p {{ hacluster_password }}`).

**Optimization #14 (cluster half) — replace fixed pause with polling.**
Verified live output format of `pcs status nodes corosync`:

```
Corosync Nodes:
 Online: MIBTECH-NPM-PROD-01 MIBTECH-NPM-PROD-02
 Offline:
```

Replace "Wait for cluster to stabilise" (`pause: seconds: cluster_settle_wait`)
with:

```yaml
- name: Wait for both cluster nodes to be online
  command: pcs status nodes corosync
  register: corosync_nodes
  until: node1_hostname in corosync_nodes.stdout and node2_hostname in corosync_nodes.stdout and "Offline:\n" not in (corosync_nodes.stdout + "\n")
  retries: 24
  delay: 5
  changed_when: false
  run_once: true
  delegate_to: "{{ node1_hostname }}"
  when: corosync_conf.rc != 0
```

Simplify the `until` condition if needed — the goal is: both hostnames appear
in the `Online:` line. A simpler, equally correct check:

```yaml
  until: (node1_hostname + ' ' + node2_hostname) in corosync_nodes.stdout or (node2_hostname + ' ' + node1_hostname) in corosync_nodes.stdout
```

Use whichever the implementer finds clearer — both must handle either node
ordering in the `Online:` line.

### Task 4 — Resources hardening (`roles/npm_ha/tasks/resources.yml`)

**Optimization #12 — split `pcs resource create` loops into named tasks.**
Replace the two `loop`-based "Configure DRBD promotable clones" (2 items) and
"Create application resources" (4 items) tasks with 6 individual named
`command` tasks (one per resource: `drbd_app`, `drbd_db`, `fs_app`, `fs_db`,
`npm_vip`, `npm_service`), each keeping the same `when: group_check.rc != 0`,
`run_once: true`, `delegate_to: "{{ node1_hostname }}"`. This gives clearer
task names in `ansible-playbook` output and isolates failures per resource.

**Optimization #14 (resources half) — replace fixed pause with polling.**
Verified live: `pcs status resources | grep npm_service` outputs:

```
    * npm_service	(systemd:npm-stack):	 Started MIBTECH-NPM-PROD-02
```

Replace "Wait for Pacemaker to mount DRBD drives"
(`pause: seconds: cluster_settle_wait`) with:

```yaml
- name: Wait for npm_group resources to start
  shell: pcs status resources | grep npm_service
  register: npm_service_status
  until: "'Started' in npm_service_status.stdout"
  retries: 24
  delay: 5
  changed_when: false
  run_once: true
  delegate_to: "{{ node1_hostname }}"
  when: group_check.rc != 0
```

### Task 5 — Post-deployment health verification (new `roles/npm_ha/tasks/verify.yml`, `roles/npm_ha/tasks/main.yml`)

**Gap #9 — cluster health verification.** New file
`roles/npm_ha/tasks/verify.yml`:

```yaml
---
- name: Wait for npm_group resources to be started
  shell: pcs status resources | grep npm_service
  register: npm_service_final_status
  until: "'Started' in npm_service_final_status.stdout"
  retries: 24
  delay: 5
  changed_when: false
  run_once: true
  delegate_to: "{{ node1_hostname }}"

- name: Check full cluster status for failed actions
  command: pcs status --full
  register: cluster_status
  changed_when: false
  run_once: true
  delegate_to: "{{ node1_hostname }}"

- name: Assert no failed resource actions
  assert:
    that: "'Failed Resource Actions' not in cluster_status.stdout"
    fail_msg: "Pacemaker reports failed resource actions:\n{{ cluster_status.stdout }}"
  run_once: true

- name: Check DRBD replication status
  command: drbdadm status all
  register: drbd_final_status
  changed_when: false

- name: Assert DRBD disks are healthy
  assert:
    that:
      - "'Diskless' not in drbd_final_status.stdout"
      - "'Inconsistent' not in drbd_final_status.stdout"
    fail_msg: "DRBD disk state is not healthy on {{ inventory_hostname }}:\n{{ drbd_final_status.stdout }}"
```

Add to `main.yml`:

```yaml
- import_tasks: verify.yml
  tags: [verify, resources]
```

(runs whenever `resources` runs, i.e. at the end of a full deploy; also
independently runnable via `--tags verify`.)

### Task 6 — Defaults, lint config, and docs (`roles/npm_ha/defaults/main.yml`, new `.ansible-lint`, `README.md`)

**Optimization #15 — pin MariaDB image version.** Verified live: both nodes
run `mariadb:10.11` resolving to `10.11.16-MariaDB`. Change
`mariadb_image_version: "10.11"` → `"10.11.16"` in `defaults/main.yml` so
`docker compose up -d` re-runs don't silently pull a newer untested patch.

**Enhancement #19 — `.ansible-lint` config.** New file `.ansible-lint` at
project root with a baseline skip list for intentional patterns already in
this role:

```yaml
---
profile: production
exclude_paths:
  - .cache/
  - roles/npm_ha/molecule/

skip_list:
  # pcs/drbdadm have no Ansible module equivalents
  - command-instead-of-module
  - no-changed-when
  # pcs status output piped through grep is intentional
  - risky-shell-pipe
```

**Gap #7 — network requirements (docs only).** Add a "Network Requirements"
section to `README.md` listing: Corosync (UDP 5404/5405), pcsd (TCP 2224),
DRBD app (TCP {{ drbd_port_app }} = 7790), DRBD db (TCP {{ drbd_port_db }} =
7791), HTTP/HTTPS (80/443), NPM admin UI ({{ npm_admin_port }} = 15625).
Note that no host firewall is currently managed on these nodes — this table
is for whoever configures perimeter/host firewalls.

**Enhancement #21 — Docker CE note (docs only).** Add a short "Future
Considerations" note: nodes currently run `docker.io`; migrating to
`docker-ce` would need a planned in-place package swap, out of scope here.

Also update the "Key Defaults" table and tag reference table in `README.md`
to include `drbd_resync_rate` and the new `verify` tag.

## Testing Notes

- Tasks 1 and 2 are exercised by `molecule test -s default` and
  `molecule test -s preflight` (both run `prepare`/`app`/`drbd` tags or are
  gated before them — `default` skips `drbd,cluster,resources` but Task 1's
  `npm-ha.res.j2`/`defaults` changes don't affect skipped tags, and Task 2's
  changes are in `prepare`/`app` which `default` does run).
- Tasks 3, 4, and 5 touch `cluster`/`resources`/`verify` tags, which
  `molecule test -s default` explicitly skips (`skip-tags: drbd,cluster,resources`)
  and which cannot be safely re-exercised against the live, already-configured
  production cluster (the `when: corosync_conf.rc != 0` / `when: group_check.rc != 0`
  guards mean the new code paths only run on a *fresh* cluster setup).
  Validate these via `ansible-playbook main.yml --syntax-check` and
  `ansible-lint`, plus careful review against the live `pcs` output formats
  already verified in this spec. Do not attempt to live-test against
  MIBTECH-NPM-PROD-01/02 — both are in active production use.
- Task 6 is config/docs — validate `.ansible-lint` runs cleanly
  (`ansible-lint roles/npm_ha`) and README renders correctly.
