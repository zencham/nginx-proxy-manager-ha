# NPM HA Role Enterprise Overhaul — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert the flat NPM HA Ansible playbook into a production-grade role with encrypted vault, Proxmox STONITH, pre-flight checks, execution tags, handlers, and full Molecule test coverage.

**Architecture:** A single Ansible role `roles/npm_ha/` replaces the flat task-file structure. All hardcoded values move to `defaults/main.yml`. STONITH is added via `fence_pve`. Molecule tests run in Docker containers against a Debian Bookworm image, mocking kernel-dependent operations.

**Tech Stack:** Ansible >= 2.14, Molecule + molecule-docker, Pacemaker/Corosync/DRBD, Docker Compose, MariaDB 10.11, Nginx Proxy Manager 2.14.0, fence-agents-pve

---

## File Map

### Create
| File | Purpose |
|---|---|
| `roles/npm_ha/meta/main.yml` | Role metadata, min Ansible version, platform |
| `roles/npm_ha/defaults/main.yml` | All overridable vars (disks, ports, versions, timeouts) |
| `roles/npm_ha/handlers/main.yml` | reload systemd, restart pcsd |
| `roles/npm_ha/vars/main.yml` | Fixed cluster identity (migrated from `vars/main.yml`) |
| `roles/npm_ha/tasks/main.yml` | import_tasks with execution tags |
| `roles/npm_ha/tasks/preflight.yml` | Pre-flight validation (new) |
| `roles/npm_ha/tasks/prepare.yml` | Packages + services (migrated) |
| `roles/npm_ha/tasks/drbd.yml` | DRBD config + init (migrated, var-substituted) |
| `roles/npm_ha/tasks/prepare_app.yml` | Mounts, compose, systemd unit (migrated, handler-wired) |
| `roles/npm_ha/tasks/cluster.yml` | Corosync/Pacemaker (migrated, var-substituted) |
| `roles/npm_ha/tasks/resources.yml` | Pacemaker resources (migrated, var-substituted) |
| `roles/npm_ha/tasks/stonith.yml` | fence_pve STONITH (new) |
| `roles/npm_ha/templates/npm-ha.res.j2` | DRBD resource template (migrated, var-substituted) |
| `roles/npm_ha/templates/docker-compose.yml.j2` | Compose template (migrated, var-substituted) |
| `roles/npm_ha/molecule/default/{molecule,converge,verify}.yml` | Idempotency scenario |
| `roles/npm_ha/molecule/preflight/{molecule,converge,verify}.yml` | Preflight failure scenario |
| `roles/npm_ha/molecule/stonith/{molecule,converge,verify}.yml` | STONITH config scenario |
| `vault_vars/vault.yml.example` | Plaintext template with all vars + new proxmox_* entries |
| `.gitignore` | Block plaintext vault commit, ignore *.retry |
| `ansible.cfg` | roles_path, inventory, stdout_callback, pipelining |
| `README.md` | Full rewrite with vault, tags, molecule, STONITH docs |

### Modify
| File | Change |
|---|---|
| `main.yml` | Rewrite to import `npm_ha` role with vault_vars included |
| `vault_vars/vault.yml` | Add proxmox_* vars, then encrypt |

### Delete
| File | Reason |
|---|---|
| `tasks/systemd.yml` | Dead code — 100% duplicate of prepare-app.yml tasks |
| `tasks/main.yml` | Replaced by role structure |
| `tasks/prepare.yml` | Migrated to role |
| `tasks/drbd.yml` | Migrated to role |
| `tasks/prepare-app.yml` | Migrated to role |
| `tasks/cluster.yml` | Migrated to role |
| `tasks/resources.yml` | Migrated to role |
| `templates/npm-ha.res.j2` | Migrated to role |
| `templates/docker-compose.yml.j2` | Migrated to role |
| `vars/main.yml` | Migrated to role |

---

## Task 1: Scaffold Role Directory Structure

**Files:** Create `roles/npm_ha/` tree

- [ ] **Step 1: Create all role directories**

```bash
cd /home/zencham/_ZENSEC/_NPM/ansible
mkdir -p roles/npm_ha/{meta,defaults,vars,handlers,tasks,templates}
mkdir -p roles/npm_ha/molecule/{default,preflight,stonith}
```

- [ ] **Step 2: Verify structure**

```bash
find roles/ -type d | sort
```
Expected output:
```
roles/
roles/npm_ha
roles/npm_ha/defaults
roles/npm_ha/handlers
roles/npm_ha/meta
roles/npm_ha/molecule
roles/npm_ha/molecule/default
roles/npm_ha/molecule/preflight
roles/npm_ha/molecule/stonith
roles/npm_ha/tasks
roles/npm_ha/templates
roles/npm_ha/vars
```

- [ ] **Step 3: Commit scaffold**

```bash
git add roles/
git commit -m "chore: scaffold npm_ha role directory structure"
```

---

## Task 2: Create `meta/main.yml`

**Files:** Create `roles/npm_ha/meta/main.yml`

- [ ] **Step 1: Write meta**

```yaml
# roles/npm_ha/meta/main.yml
---
galaxy_info:
  author: HICHAM KARABANE
  description: 2-node HA Nginx Proxy Manager cluster — Pacemaker, Corosync, DRBD on Proxmox
  min_ansible_version: "2.14"
  platforms:
    - name: Debian
      versions:
        - bookworm
dependencies: []
```

- [ ] **Step 2: Commit**

```bash
git add roles/npm_ha/meta/main.yml
git commit -m "feat(npm_ha): add role meta — Debian Bookworm, Ansible 2.14+"
```

---

## Task 3: Create `defaults/main.yml`

**Files:** Create `roles/npm_ha/defaults/main.yml`

Note: Two extra variables added vs spec — `drbd_device_app` and `drbd_device_db` (the DRBD virtual devices `/dev/drbd10`, `/dev/drbd11`) which are referenced in both the resource template and resources.yml but were hardcoded in the original.

- [ ] **Step 1: Write defaults**

```yaml
# roles/npm_ha/defaults/main.yml
---
# DRBD underlying block devices (physical disks)
drbd_disk_app: /dev/sdb1
drbd_disk_db: /dev/sdb2

# DRBD virtual device paths (created by DRBD from the above)
drbd_device_app: /dev/drbd10
drbd_device_db: /dev/drbd11

# DRBD replication ports
drbd_port_app: 7790
drbd_port_db: 7791

# DRBD resource names (must match npm-ha.res.j2)
drbd_resource_app: mib_npm_ha_drbd_npm
drbd_resource_db: mib_npm_ha_drbd_db

# Application paths
npm_compose_dir: /opt/npm/compose
npm_mount_app: /mnt/npm_app
npm_mount_db: /mnt/npm_db

# Container image versions
npm_image_version: "2.14.0"
mariadb_image_version: "10.11"

# NPM admin UI host port (mapped to container port 81)
npm_admin_port: 15625

# Pacemaker resource timeouts
drbd_stop_timeout: 90s
npm_service_timeout: 120s

# Seconds to pause after cluster/resource operations settle
cluster_settle_wait: 15

# Container timezone
timezone: Africa/Casablanca
```

- [ ] **Step 2: Commit**

```bash
git add roles/npm_ha/defaults/main.yml
git commit -m "feat(npm_ha): add defaults — parametrize all hardcoded values"
```

---

## Task 4: Create `handlers/main.yml`

**Files:** Create `roles/npm_ha/handlers/main.yml`

- [ ] **Step 1: Write handlers**

```yaml
# roles/npm_ha/handlers/main.yml
---
- name: reload systemd
  systemd:
    daemon_reload: yes

- name: restart pcsd
  systemd:
    name: pcsd
    state: restarted
```

- [ ] **Step 2: Commit**

```bash
git add roles/npm_ha/handlers/main.yml
git commit -m "feat(npm_ha): add handlers — reload systemd, restart pcsd"
```

---

## Task 5: Migrate `vars/main.yml`

**Files:** Create `roles/npm_ha/vars/main.yml`

- [ ] **Step 1: Write vars (fixed cluster identity)**

```yaml
# roles/npm_ha/vars/main.yml
---
cluster_name: "npm_ha_cluster"
vip_address: "192.168.206.220"
vip_cidr: "24"
node1_hostname: "MIBTECH-NPM-PROD-01"
node1_ip: "192.168.206.33"
node2_hostname: "MIBTECH-NPM-PROD-02"
node2_ip: "192.168.206.40"
```

- [ ] **Step 2: Commit**

```bash
git add roles/npm_ha/vars/main.yml
git commit -m "feat(npm_ha): add vars — fixed cluster identity"
```

---

## Task 6: Create `tasks/preflight.yml`

**Files:** Create `roles/npm_ha/tasks/preflight.yml`

- [ ] **Step 1: Write preflight tasks**

```yaml
# roles/npm_ha/tasks/preflight.yml
---
- name: Assert minimum Ansible version
  assert:
    that: ansible_version.full is version('2.14', '>=')
    fail_msg: "Ansible >= 2.14 required, found {{ ansible_version.full }}"
  run_once: true
  delegate_to: localhost

- name: Check DRBD kernel module is loadable
  command: modprobe --dry-run drbd
  changed_when: false

- name: Check app block device exists
  stat:
    path: "{{ drbd_disk_app }}"
  register: drbd_disk_app_stat

- name: Assert app block device exists
  assert:
    that: drbd_disk_app_stat.stat.exists
    fail_msg: "Block device {{ drbd_disk_app }} does not exist on {{ inventory_hostname }}"

- name: Check db block device exists
  stat:
    path: "{{ drbd_disk_db }}"
  register: drbd_disk_db_stat

- name: Assert db block device exists
  assert:
    that: drbd_disk_db_stat.stat.exists
    fail_msg: "Block device {{ drbd_disk_db }} does not exist on {{ inventory_hostname }}"

- name: Check free disk space on /
  shell: df --output=avail / | tail -1
  register: root_free_kb
  changed_when: false

- name: Assert at least 2GB free on /
  assert:
    that: root_free_kb.stdout | trim | int >= 2097152
    fail_msg: >
      Only {{ (root_free_kb.stdout | trim | int / 1024 / 1024) | round(1) }}GB free on /
      of {{ inventory_hostname }} — 2GB minimum required

- name: Check peer node is reachable via SSH
  wait_for:
    host: "{{ node2_ip if inventory_hostname == node1_hostname else node1_ip }}"
    port: 22
    timeout: 10
    state: started
```

- [ ] **Step 2: Commit**

```bash
git add roles/npm_ha/tasks/preflight.yml
git commit -m "feat(npm_ha): add preflight — disk, module, space, peer checks"
```

---

## Task 7: Migrate `tasks/prepare.yml`

**Files:** Create `roles/npm_ha/tasks/prepare.yml`

- [ ] **Step 1: Write prepare tasks (logic unchanged from original)**

```yaml
# roles/npm_ha/tasks/prepare.yml
---
- name: Install prerequisite packages
  apt:
    name:
      - ca-certificates
      - curl
      - gnupg
      - docker.io
      - docker-compose-plugin
      - pacemaker
      - corosync
      - pcs
      - drbd-utils
    state: present
    update_cache: yes

- name: Ensure Docker service is enabled and started
  systemd:
    name: docker
    state: started
    enabled: yes

- name: Ensure pcsd service is enabled and started
  systemd:
    name: pcsd
    state: started
    enabled: yes

- name: Set hacluster user password
  user:
    name: hacluster
    password: "{{ hacluster_password | password_hash('sha512') }}"

- name: Ensure DRBD kernel module is loaded
  modprobe:
    name: drbd
    state: present
```

- [ ] **Step 2: Commit**

```bash
git add roles/npm_ha/tasks/prepare.yml
git commit -m "feat(npm_ha): migrate prepare tasks into role"
```

---

## Task 8: Migrate `tasks/drbd.yml`

**Files:** Create `roles/npm_ha/tasks/drbd.yml`

Changes from original: replace hardcoded resource name `mib_npm_ha_drbd_npm` with `{{ drbd_resource_app }}`, replace `/dev/drbd10`/`/dev/drbd11` with `{{ drbd_device_app }}`/`{{ drbd_device_db }}`.

- [ ] **Step 1: Write drbd tasks**

```yaml
# roles/npm_ha/tasks/drbd.yml
---
- name: Deploy DRBD configuration file
  template:
    src: npm-ha.res.j2
    dest: /etc/drbd.d/npm-ha.res
    owner: root
    group: root
    mode: '0644'

- name: Check if DRBD metadata already exists
  shell: >
    drbdadm role {{ drbd_resource_app }} 2>/dev/null ||
    drbdadm dump-md {{ drbd_resource_app }} 2>/dev/null
  register: drbd_md_check
  ignore_errors: true
  changed_when: false

- name: Initialize DRBD metadata (only if not already created)
  command: drbdadm create-md all --force
  when: drbd_md_check.rc != 0
  register: drbd_init

- name: Bring DRBD resources up
  command: drbdadm up all
  ignore_errors: true
  when: drbd_init.changed or drbd_md_check.rc != 0

- name: Force primary role on node 1 to initiate first sync
  command: drbdadm primary --force all
  run_once: true
  delegate_to: "{{ node1_hostname }}"
  when: drbd_init.changed

- name: Format app DRBD device as ext4
  filesystem:
    fstype: ext4
    dev: "{{ drbd_device_app }}"
    force: no
  run_once: true
  delegate_to: "{{ node1_hostname }}"
  when: drbd_init.changed

- name: Format db DRBD device as ext4
  filesystem:
    fstype: ext4
    dev: "{{ drbd_device_db }}"
    force: no
  run_once: true
  delegate_to: "{{ node1_hostname }}"
  when: drbd_init.changed
```

- [ ] **Step 2: Commit**

```bash
git add roles/npm_ha/tasks/drbd.yml
git commit -m "feat(npm_ha): migrate drbd tasks — parametrize device and resource names"
```

---

## Task 9: Migrate `tasks/prepare_app.yml`

**Files:** Create `roles/npm_ha/tasks/prepare_app.yml`

Changes from original: replace hardcoded paths with vars, replace inline `daemon_reload` with `notify: reload systemd` handler, use `{{ npm_compose_dir }}` / `{{ npm_mount_app }}` / `{{ npm_mount_db }}`.

- [ ] **Step 1: Write prepare_app tasks**

```yaml
# roles/npm_ha/tasks/prepare_app.yml
---
- name: Ensure mount points and compose directory exist
  file:
    path: "{{ item }}"
    state: directory
    owner: root
    group: root
    mode: '0755'
  loop:
    - "{{ npm_mount_app }}"
    - "{{ npm_mount_db }}"
    - "{{ npm_compose_dir }}"

- name: Template docker-compose.yml to nodes
  template:
    src: docker-compose.yml.j2
    dest: "{{ npm_compose_dir }}/docker-compose.yml"
    owner: root
    group: root
    mode: '0644'

- name: Create NPM Docker Compose systemd unit
  copy:
    dest: /etc/systemd/system/npm-stack.service
    content: |
      [Unit]
      Description=NPM HA Docker Compose Stack
      Requires=docker.service
      After=docker.service

      [Service]
      Type=oneshot
      RemainAfterExit=yes
      WorkingDirectory={{ npm_compose_dir }}
      ExecStart=/usr/bin/docker compose up -d
      ExecStop=/usr/bin/docker compose down

      [Install]
      WantedBy=multi-user.target
    owner: root
    group: root
    mode: '0644'
  notify: reload systemd
```

- [ ] **Step 2: Commit**

```bash
git add roles/npm_ha/tasks/prepare_app.yml
git commit -m "feat(npm_ha): migrate prepare_app — use vars, wire handler notification"
```

---

## Task 10: Migrate `tasks/cluster.yml`

**Files:** Create `roles/npm_ha/tasks/cluster.yml`

Changes from original: replace hardcoded `cluster_name`, `node1_hostname`, `node1_ip`, `node2_hostname`, `node2_ip` with vars (already vars in original, verify unchanged), replace hardcoded `cluster_settle_wait` integer with `{{ cluster_settle_wait }}`.

- [ ] **Step 1: Write cluster tasks**

```yaml
# roles/npm_ha/tasks/cluster.yml
---
- name: Check if our cluster is already configured
  command: grep -q "{{ cluster_name }}" /etc/corosync/corosync.conf
  register: corosync_conf
  ignore_errors: true
  changed_when: false

- name: Remove dummy Debian corosync config if present
  file:
    path: /etc/corosync/corosync.conf
    state: absent
  when: corosync_conf.rc != 0

- name: Authenticate cluster nodes
  command: >
    pcs host auth {{ node1_hostname }} {{ node2_hostname }}
    -u hacluster -p {{ hacluster_password }}
  run_once: true
  delegate_to: "{{ node1_hostname }}"
  when: corosync_conf.rc != 0

- name: Setup the cluster
  command: >
    pcs cluster setup {{ cluster_name }}
    {{ node1_hostname }} addr={{ node1_ip }}
    {{ node2_hostname }} addr={{ node2_ip }}
    --force
  run_once: true
  delegate_to: "{{ node1_hostname }}"
  when: corosync_conf.rc != 0

- name: Start and enable cluster services
  command: "{{ item }}"
  loop:
    - pcs cluster start --all
    - pcs cluster enable --all
  run_once: true
  delegate_to: "{{ node1_hostname }}"
  when: corosync_conf.rc != 0

- name: Wait for cluster to stabilise
  pause:
    seconds: "{{ cluster_settle_wait }}"
  when: corosync_conf.rc != 0

- name: Set global cluster properties
  command: "{{ item }}"
  loop:
    - pcs property set stonith-enabled=false
    - pcs property set no-quorum-policy=ignore
  run_once: true
  delegate_to: "{{ node1_hostname }}"
  when: corosync_conf.rc != 0
```

- [ ] **Step 2: Commit**

```bash
git add roles/npm_ha/tasks/cluster.yml
git commit -m "feat(npm_ha): migrate cluster tasks — use settle_wait var"
```

---

## Task 11: Migrate `tasks/resources.yml`

**Files:** Create `roles/npm_ha/tasks/resources.yml`

Changes from original: replace hardcoded DRBD resource names, device paths, mount points, VIP, timeouts with vars from `defaults/` and `vars/`.

- [ ] **Step 1: Write resources tasks**

```yaml
# roles/npm_ha/tasks/resources.yml
---
- name: Check if npm_group resource exists
  command: pcs resource config npm_group
  register: group_check
  ignore_errors: true
  run_once: true
  delegate_to: "{{ node1_hostname }}"
  changed_when: false

- name: Configure DRBD promotable clones
  command: "{{ item }}"
  loop:
    - >
      pcs resource create drbd_app ocf:linbit:drbd
      drbd_resource={{ drbd_resource_app }}
      promotable notify=true
      promoted-max=1 promoted-node-max=1
      clone-max=2 clone-node-max=1
    - >
      pcs resource create drbd_db ocf:linbit:drbd
      drbd_resource={{ drbd_resource_db }}
      promotable notify=true
      promoted-max=1 promoted-node-max=1
      clone-max=2 clone-node-max=1
  run_once: true
  delegate_to: "{{ node1_hostname }}"
  when: group_check.rc != 0

- name: Create application resources
  command: "{{ item }}"
  loop:
    - >
      pcs resource create fs_app ocf:heartbeat:Filesystem
      device="{{ drbd_device_app }}"
      directory="{{ npm_mount_app }}"
      fstype="ext4"
    - >
      pcs resource create fs_db ocf:heartbeat:Filesystem
      device="{{ drbd_device_db }}"
      directory="{{ npm_mount_db }}"
      fstype="ext4"
    - >
      pcs resource create npm_vip ocf:heartbeat:IPaddr2
      ip={{ vip_address }}
      cidr_netmask={{ vip_cidr }}
      op monitor interval=30s
    - pcs resource create npm_service systemd:npm-stack
  run_once: true
  delegate_to: "{{ node1_hostname }}"
  when: group_check.rc != 0

- name: Group application resources
  command: pcs resource group add npm_group fs_app fs_db npm_vip npm_service
  run_once: true
  delegate_to: "{{ node1_hostname }}"
  when: group_check.rc != 0

- name: Set colocation and order constraints
  command: "{{ item }}"
  loop:
    - pcs constraint colocation add promoted drbd_db-clone with promoted drbd_app-clone INFINITY
    - pcs constraint order promote drbd_app-clone then promote drbd_db-clone
    - pcs constraint colocation add npm_group with promoted drbd_db-clone INFINITY
    - pcs constraint order promote drbd_db-clone then start npm_group
  run_once: true
  delegate_to: "{{ node1_hostname }}"
  when: group_check.rc != 0

- name: Update resource timeouts
  command: "{{ item }}"
  loop:
    - pcs resource update drbd_app op stop timeout={{ drbd_stop_timeout }}
    - pcs resource update drbd_db op stop timeout={{ drbd_stop_timeout }}
    - >
      pcs resource update npm_service
      op start timeout={{ npm_service_timeout }}
      op stop timeout={{ npm_service_timeout }}
  run_once: true
  delegate_to: "{{ node1_hostname }}"
  when: group_check.rc != 0

- name: Wait for Pacemaker to mount DRBD drives
  pause:
    seconds: "{{ cluster_settle_wait }}"
  run_once: true
  when: group_check.rc != 0

- name: Ensure application subdirectories exist on DRBD mounts
  file:
    path: "{{ item }}"
    state: directory
    owner: root
    group: root
    mode: '0755'
  loop:
    - "{{ npm_mount_app }}/data"
    - "{{ npm_mount_app }}/letsencrypt"
    - "{{ npm_mount_db }}/db/mysql"
  run_once: true
  delegate_to: "{{ node1_hostname }}"
  when: group_check.rc != 0

- name: Final cleanup — reset any Pacemaker failure states
  command: pcs resource cleanup
  run_once: true
  delegate_to: "{{ node1_hostname }}"
  changed_when: false
```

- [ ] **Step 2: Commit**

```bash
git add roles/npm_ha/tasks/resources.yml
git commit -m "feat(npm_ha): migrate resources — parametrize devices, mounts, timeouts"
```

---

## Task 12: Create `tasks/stonith.yml`

**Files:** Create `roles/npm_ha/tasks/stonith.yml`

- [ ] **Step 1: Write stonith tasks**

```yaml
# roles/npm_ha/tasks/stonith.yml
---
- name: Install fence-agents-pve
  apt:
    name: fence-agents-pve
    state: present

- name: Check if STONITH resources already exist
  command: pcs stonith config stonith-{{ node1_hostname }} stonith-{{ node2_hostname }}
  register: stonith_check
  ignore_errors: true
  run_once: true
  delegate_to: "{{ node1_hostname }}"
  changed_when: false

- name: Create STONITH resource for node 1
  command: >
    pcs stonith create stonith-{{ node1_hostname }} fence_pve
    pcmk_host_list={{ node1_hostname }}
    ip={{ proxmox_api_host }}
    username={{ proxmox_api_user }}
    password={{ proxmox_api_password }}
    plug={{ proxmox_node1_vmid }}
    ssl_insecure=1
    op monitor interval=60s
  run_once: true
  delegate_to: "{{ node1_hostname }}"
  when: stonith_check.rc != 0

- name: Create STONITH resource for node 2
  command: >
    pcs stonith create stonith-{{ node2_hostname }} fence_pve
    pcmk_host_list={{ node2_hostname }}
    ip={{ proxmox_api_host }}
    username={{ proxmox_api_user }}
    password={{ proxmox_api_password }}
    plug={{ proxmox_node2_vmid }}
    ssl_insecure=1
    op monitor interval=60s
  run_once: true
  delegate_to: "{{ node1_hostname }}"
  when: stonith_check.rc != 0

- name: Enable STONITH in cluster properties
  command: pcs property set stonith-enabled=true
  run_once: true
  delegate_to: "{{ node1_hostname }}"
  when: stonith_check.rc != 0
```

- [ ] **Step 2: Commit**

```bash
git add roles/npm_ha/tasks/stonith.yml
git commit -m "feat(npm_ha): add stonith — fence_pve STONITH via Proxmox API"
```

---

## Task 13: Create `tasks/main.yml` (with tags)

**Files:** Create `roles/npm_ha/tasks/main.yml`

- [ ] **Step 1: Write tasks entrypoint with tags**

```yaml
# roles/npm_ha/tasks/main.yml
---
- import_tasks: preflight.yml
  tags: [preflight, always]

- import_tasks: prepare.yml
  tags: prepare

- import_tasks: drbd.yml
  tags: drbd

- import_tasks: prepare_app.yml
  tags: app

- import_tasks: cluster.yml
  tags: cluster

- import_tasks: resources.yml
  tags: resources

- import_tasks: stonith.yml
  tags: stonith
```

- [ ] **Step 2: Commit**

```bash
git add roles/npm_ha/tasks/main.yml
git commit -m "feat(npm_ha): add tasks/main.yml — import all tasks with execution tags"
```

---

## Task 14: Migrate Templates

**Files:** Create `roles/npm_ha/templates/npm-ha.res.j2`, `roles/npm_ha/templates/docker-compose.yml.j2`

Changes to `npm-ha.res.j2`: replace hardcoded `/dev/drbd10`, `/dev/sdb1`, `/dev/drbd11`, `/dev/sdb2` and ports with defaults vars.

`docker-compose.yml.j2`: replace hardcoded image versions and admin port with defaults vars (logic and volumes unchanged).

- [ ] **Step 1: Write npm-ha.res.j2**

```
# roles/npm_ha/templates/npm-ha.res.j2
# Generated by Ansible for the NPM HA cluster.
resource {{ drbd_resource_app }} {
  protocol C;
  meta-disk internal;

  net {
    cram-hmac-alg sha256;
    shared-secret "{{ drbd_secret }}";
  }

  on {{ node1_hostname }} {
    device {{ drbd_device_app }};
    disk {{ drbd_disk_app }};
    address {{ node1_ip }}:{{ drbd_port_app }};
  }
  on {{ node2_hostname }} {
    device {{ drbd_device_app }};
    disk {{ drbd_disk_app }};
    address {{ node2_ip }}:{{ drbd_port_app }};
  }
}

resource {{ drbd_resource_db }} {
  protocol C;
  meta-disk internal;

  net {
    cram-hmac-alg sha256;
    shared-secret "{{ drbd_secret }}";
  }

  on {{ node1_hostname }} {
    device {{ drbd_device_db }};
    disk {{ drbd_disk_db }};
    address {{ node1_ip }}:{{ drbd_port_db }};
  }
  on {{ node2_hostname }} {
    device {{ drbd_device_db }};
    disk {{ drbd_disk_db }};
    address {{ node2_ip }}:{{ drbd_port_db }};
  }
}
```

- [ ] **Step 2: Write docker-compose.yml.j2**

```yaml
# roles/npm_ha/templates/docker-compose.yml.j2
services:
  db:
    image: "mariadb:{{ mariadb_image_version }}"
    container_name: "npm_db"
    restart: "no"
    command:
      - --bind-address=0.0.0.0
      - --log-basename="npm"
    environment:
      MARIADB_ROOT_PASSWORD: "{{ mysql_root_password }}"
      MARIADB_DATABASE: "npm_edge"
      MARIADB_USER: "npm_adm"
      MARIADB_PASSWORD: "{{ mysql_npm_password }}"
      TZ: "{{ timezone }}"
    volumes:
      - "{{ npm_mount_db }}/db/mysql:/var/lib/mysql"
    healthcheck:
      test: ["CMD-SHELL", "mariadb -uroot --password={{ mysql_root_password }} -Nse 'SELECT 1' >/dev/null 2>&1 || exit 1"]
      interval: 20s
      timeout: 10s
      retries: 15
      start_period: 60s
  app:
    image: "jc21/nginx-proxy-manager:{{ npm_image_version }}"
    container_name: "npm_app"
    restart: "no"
    ports:
      - "80:80"
      - "443:443"
      - "{{ npm_admin_port }}:81"
    environment:
      DB_MYSQL_HOST: "db"
      DB_MYSQL_PORT: "3306"
      DB_MYSQL_USER: "npm_adm"
      DB_MYSQL_PASSWORD: "{{ mysql_npm_password }}"
      DB_MYSQL_NAME: "npm_edge"
      TZ: "{{ timezone }}"
    volumes:
      - "{{ npm_mount_app }}/data:/data"
      - "{{ npm_mount_app }}/letsencrypt:/etc/letsencrypt"
    depends_on:
      - db
    healthcheck:
      test: ["CMD", "curl", "-f", "http://127.0.0.1:81/"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 40s
```

- [ ] **Step 3: Commit**

```bash
git add roles/npm_ha/templates/
git commit -m "feat(npm_ha): migrate templates — parametrize all hardcoded values"
```

---

## Task 15: Write Molecule Default Scenario (Idempotency)

**Files:** `roles/npm_ha/molecule/default/{molecule.yml,converge.yml,verify.yml}`

This scenario runs in Docker (Debian Bookworm), skips hardware-dependent tags (`drbd`, `cluster`, `resources`, `stonith`) and verifies that file artifacts are correctly created and that the role is idempotent.

- [ ] **Step 1: Install Molecule and Docker driver (if not already installed)**

```bash
pip install molecule molecule-docker
molecule --version
```
Expected: `molecule 6.x.x` (or similar)

- [ ] **Step 2: Write molecule.yml**

```yaml
# roles/npm_ha/molecule/default/molecule.yml
---
dependency:
  name: galaxy
driver:
  name: docker
platforms:
  - name: npm-node1
    image: debian:bookworm
    pre_build_image: true
    privileged: true
    groups:
      - ha_nodes
  - name: npm-node2
    image: debian:bookworm
    pre_build_image: true
    privileged: true
    groups:
      - ha_nodes
provisioner:
  name: ansible
  inventory:
    group_vars:
      ha_nodes:
        node1_hostname: npm-node1
        node2_hostname: npm-node2
        node1_ip: "{{ hostvars['npm-node1']['ansible_default_ipv4']['address'] }}"
        node2_ip: "{{ hostvars['npm-node2']['ansible_default_ipv4']['address'] }}"
        drbd_disk_app: /dev/sda
        drbd_disk_db: /dev/sda
        hacluster_password: test-hacluster-pass
        drbd_secret: test-drbd-secret
        mysql_root_password: test-root-pass
        mysql_npm_password: test-npm-pass
        proxmox_api_host: 192.168.1.1
        proxmox_api_user: root@pam
        proxmox_api_password: test-proxmox-pass
        proxmox_node1_vmid: 100
        proxmox_node2_vmid: 101
  options:
    skip-tags: drbd,cluster,resources,stonith
verifier:
  name: ansible
lint: |
  set -e
  ansible-lint
```

- [ ] **Step 3: Write converge.yml**

```yaml
# roles/npm_ha/molecule/default/converge.yml
---
- name: Converge
  hosts: ha_nodes
  become: yes
  roles:
    - role: npm_ha
```

- [ ] **Step 4: Write verify.yml**

```yaml
# roles/npm_ha/molecule/default/verify.yml
---
- name: Verify npm_ha file artifacts
  hosts: ha_nodes
  become: yes
  tasks:
    - name: Check docker-compose.yml is deployed
      stat:
        path: "{{ npm_compose_dir }}/docker-compose.yml"
      register: compose_file

    - name: Assert docker-compose.yml exists
      assert:
        that: compose_file.stat.exists
        fail_msg: "docker-compose.yml was not created at {{ npm_compose_dir }}"

    - name: Check npm-stack.service exists
      stat:
        path: /etc/systemd/system/npm-stack.service
      register: service_file

    - name: Assert npm-stack.service exists
      assert:
        that: service_file.stat.exists
        fail_msg: "npm-stack.service systemd unit was not created"

    - name: Check compose dir has correct permissions
      stat:
        path: "{{ npm_compose_dir }}"
      register: compose_dir

    - name: Assert compose dir is mode 0755
      assert:
        that: compose_dir.stat.mode == '0755'
        fail_msg: "{{ npm_compose_dir }} has wrong permissions: {{ compose_dir.stat.mode }}"

    - name: Verify docker-compose.yml contains correct image versions
      slurp:
        src: "{{ npm_compose_dir }}/docker-compose.yml"
      register: compose_content

    - name: Assert NPM image version is present
      assert:
        that: "'nginx-proxy-manager:' ~ npm_image_version in (compose_content.content | b64decode)"
        fail_msg: "NPM image version {{ npm_image_version }} not found in docker-compose.yml"
```

- [ ] **Step 5: Run scenario — expect it to pass (preflight skipped in molecule because /dev/sda exists)**

```bash
cd /home/zencham/_ZENSEC/_NPM/ansible/roles/npm_ha
molecule test -s default
```
Expected: All tasks green, verify assertions pass.

- [ ] **Step 6: Commit**

```bash
cd /home/zencham/_ZENSEC/_NPM/ansible
git add roles/npm_ha/molecule/default/
git commit -m "test(npm_ha): add molecule default scenario — idempotency + file assertions"
```

---

## Task 16: Write Molecule Preflight Scenario

**Files:** `roles/npm_ha/molecule/preflight/{molecule.yml,converge.yml,verify.yml}`

This scenario overrides `drbd_disk_app` with a non-existent path and asserts the role stops before creating any artifacts.

- [ ] **Step 1: Write molecule.yml**

```yaml
# roles/npm_ha/molecule/preflight/molecule.yml
---
dependency:
  name: galaxy
driver:
  name: docker
platforms:
  - name: npm-preflight-node1
    image: debian:bookworm
    pre_build_image: true
    privileged: true
    groups:
      - ha_nodes
  - name: npm-preflight-node2
    image: debian:bookworm
    pre_build_image: true
    privileged: true
    groups:
      - ha_nodes
provisioner:
  name: ansible
  inventory:
    group_vars:
      ha_nodes:
        node1_hostname: npm-preflight-node1
        node2_hostname: npm-preflight-node2
        node1_ip: "{{ hostvars['npm-preflight-node1']['ansible_default_ipv4']['address'] }}"
        node2_ip: "{{ hostvars['npm-preflight-node2']['ansible_default_ipv4']['address'] }}"
        drbd_disk_app: /dev/nonexistent_app_disk
        drbd_disk_db: /dev/nonexistent_db_disk
        hacluster_password: test-hacluster-pass
        drbd_secret: test-drbd-secret
        mysql_root_password: test-root-pass
        mysql_npm_password: test-npm-pass
        proxmox_api_host: 192.168.1.1
        proxmox_api_user: root@pam
        proxmox_api_password: test-proxmox-pass
        proxmox_node1_vmid: 100
        proxmox_node2_vmid: 101
verifier:
  name: ansible
```

- [ ] **Step 2: Write converge.yml (wraps role to capture expected failure)**

```yaml
# roles/npm_ha/molecule/preflight/converge.yml
---
- name: Converge — expect preflight failure on missing disks
  hosts: ha_nodes
  become: yes
  tasks:
    - block:
        - include_role:
            name: npm_ha
          vars:
            ansible_assert_fail_on_missing_handler: true
      rescue:
        - name: Preflight failed as expected — capture state
          set_fact:
            preflight_failed: true
```

- [ ] **Step 3: Write verify.yml**

```yaml
# roles/npm_ha/molecule/preflight/verify.yml
---
- name: Verify preflight stopped execution before creating artifacts
  hosts: ha_nodes
  become: yes
  tasks:
    - name: Check that docker-compose.yml was NOT created
      stat:
        path: "{{ npm_compose_dir }}/docker-compose.yml"
      register: compose_file

    - name: Assert docker-compose.yml does not exist
      assert:
        that: not compose_file.stat.exists
        fail_msg: >
          docker-compose.yml exists at {{ npm_compose_dir }} —
          preflight did not stop role execution as expected

    - name: Check that npm-stack.service was NOT created
      stat:
        path: /etc/systemd/system/npm-stack.service
      register: service_file

    - name: Assert npm-stack.service does not exist
      assert:
        that: not service_file.stat.exists
        fail_msg: >
          npm-stack.service exists — preflight did not stop role execution as expected
```

- [ ] **Step 4: Run scenario — expect verify to pass (artifacts absent)**

```bash
cd /home/zencham/_ZENSEC/_NPM/ansible/roles/npm_ha
molecule test -s preflight
```
Expected: converge fails at assert (expected), verify assertions pass.

- [ ] **Step 5: Commit**

```bash
cd /home/zencham/_ZENSEC/_NPM/ansible
git add roles/npm_ha/molecule/preflight/
git commit -m "test(npm_ha): add molecule preflight scenario — assert fails on missing disks"
```

---

## Task 17: Write Molecule STONITH Scenario

**Files:** `roles/npm_ha/molecule/stonith/{molecule.yml,converge.yml,verify.yml}`

This scenario mocks `pcs` with a stub script to test STONITH task idempotency without a real cluster.

- [ ] **Step 1: Write molecule.yml**

```yaml
# roles/npm_ha/molecule/stonith/molecule.yml
---
dependency:
  name: galaxy
driver:
  name: docker
platforms:
  - name: npm-stonith-node1
    image: debian:bookworm
    pre_build_image: true
    privileged: true
    groups:
      - ha_nodes
  - name: npm-stonith-node2
    image: debian:bookworm
    pre_build_image: true
    privileged: true
    groups:
      - ha_nodes
provisioner:
  name: ansible
  inventory:
    group_vars:
      ha_nodes:
        node1_hostname: npm-stonith-node1
        node2_hostname: npm-stonith-node2
        node1_ip: "{{ hostvars['npm-stonith-node1']['ansible_default_ipv4']['address'] }}"
        node2_ip: "{{ hostvars['npm-stonith-node2']['ansible_default_ipv4']['address'] }}"
        drbd_disk_app: /dev/sda
        drbd_disk_db: /dev/sda
        hacluster_password: test-hacluster-pass
        drbd_secret: test-drbd-secret
        mysql_root_password: test-root-pass
        mysql_npm_password: test-npm-pass
        proxmox_api_host: 192.168.1.1
        proxmox_api_user: root@pam
        proxmox_api_password: test-proxmox-pass
        proxmox_node1_vmid: 100
        proxmox_node2_vmid: 101
  options:
    skip-tags: drbd,cluster,resources
  playbooks:
    prepare: prepare.yml
verifier:
  name: ansible
```

- [ ] **Step 2: Write prepare.yml (installs pcs mock before converge)**

```yaml
# roles/npm_ha/molecule/stonith/prepare.yml
---
- name: Prepare — install pcs mock and fence-agents stub
  hosts: ha_nodes
  become: yes
  tasks:
    - name: Create pcs mock binary
      copy:
        dest: /usr/bin/pcs
        content: |
          #!/bin/bash
          # Molecule pcs mock — records calls and simulates idempotency
          MOCK_STATE_DIR="/tmp/pcs_mock_state"
          mkdir -p "$MOCK_STATE_DIR"
          CMD="$*"
          STATE_FILE="$MOCK_STATE_DIR/$(echo "$CMD" | md5sum | cut -d' ' -f1)"

          if [[ "$CMD" == *"stonith config"* ]]; then
            # Return non-zero on first call (not configured), zero on second (idempotent)
            if [ -f "$STATE_FILE" ]; then
              cat "$MOCK_STATE_DIR/stonith_state" 2>/dev/null
              exit 0
            fi
            exit 1
          fi

          if [[ "$CMD" == *"stonith create"* ]]; then
            echo "$CMD" >> "$MOCK_STATE_DIR/stonith_state"
            touch "$STATE_FILE"
            exit 0
          fi

          if [[ "$CMD" == *"property set stonith-enabled=true"* ]]; then
            echo "stonith-enabled=true" > "$MOCK_STATE_DIR/stonith_enabled"
            exit 0
          fi

          exit 0
        mode: '0755'
        owner: root
        group: root

    - name: Create fence-agents-pve stub package marker
      file:
        path: /tmp/fence-agents-pve-installed
        state: touch
```

- [ ] **Step 3: Write converge.yml**

```yaml
# roles/npm_ha/molecule/stonith/converge.yml
---
- name: Converge — test STONITH configuration
  hosts: ha_nodes
  become: yes
  roles:
    - role: npm_ha
```

- [ ] **Step 4: Write verify.yml**

```yaml
# roles/npm_ha/molecule/stonith/verify.yml
---
- name: Verify STONITH resources were configured
  hosts: npm-stonith-node1
  become: yes
  tasks:
    - name: Read pcs mock STONITH state
      slurp:
        src: /tmp/pcs_mock_state/stonith_state
      register: stonith_state
      ignore_errors: true

    - name: Assert STONITH resource for node1 was created
      assert:
        that: "'stonith-npm-stonith-node1' in (stonith_state.content | b64decode)"
        fail_msg: "STONITH resource for node1 not found in pcs mock state"

    - name: Assert STONITH resource for node2 was created
      assert:
        that: "'stonith-npm-stonith-node2' in (stonith_state.content | b64decode)"
        fail_msg: "STONITH resource for node2 not found in pcs mock state"

    - name: Read stonith-enabled state
      slurp:
        src: /tmp/pcs_mock_state/stonith_enabled
      register: stonith_enabled_state

    - name: Assert STONITH was enabled
      assert:
        that: "'stonith-enabled=true' in (stonith_enabled_state.content | b64decode)"
        fail_msg: "STONITH was not enabled in cluster properties"
```

- [ ] **Step 5: Run scenario**

```bash
cd /home/zencham/_ZENSEC/_NPM/ansible/roles/npm_ha
molecule test -s stonith
```
Expected: All assertions pass.

- [ ] **Step 6: Commit**

```bash
cd /home/zencham/_ZENSEC/_NPM/ansible
git add roles/npm_ha/molecule/stonith/
git commit -m "test(npm_ha): add molecule stonith scenario — verify fence_pve config via pcs mock"
```

---

## Task 18: Update Top-Level `main.yml`

**Files:** Modify `main.yml`

- [ ] **Step 1: Rewrite main.yml to use role**

```yaml
# main.yml
---
- name: Deploy HA Cluster for NPM (Pacemaker, Corosync, DRBD)
  hosts: ha_nodes
  become: yes
  vars_files:
    - vault_vars/vault.yml
  roles:
    - role: npm_ha
```

- [ ] **Step 2: Commit**

```bash
git add main.yml
git commit -m "feat: rewrite main.yml to import npm_ha role"
```

---

## Task 19: Configure `ansible.cfg`

**Files:** Modify `ansible.cfg` (full rewrite — current file is the default template, all commented out)

- [ ] **Step 1: Rewrite ansible.cfg**

```ini
# ansible.cfg
[defaults]
inventory           = inventory/hosts
roles_path          = roles
stdout_callback     = yaml
retry_files_enabled = False
host_key_checking   = True
timeout             = 30

[ssh_connection]
pipelining          = True
```

- [ ] **Step 2: Commit**

```bash
git add ansible.cfg
git commit -m "chore: configure ansible.cfg — inventory, roles_path, yaml output, pipelining"
```

---

## Task 20: Add `.gitignore`

**Files:** Create `.gitignore`

- [ ] **Step 1: Write .gitignore**

```
# Plaintext vault — remove this line after encrypting vault_vars/vault.yml
vault_vars/vault.yml

# Ansible retry files
*.retry
```

- [ ] **Step 2: Commit**

```bash
git add .gitignore
git commit -m "chore: add .gitignore — block plaintext vault commit, ignore retry files"
```

---

## Task 21: Create `vault.yml.example` and Add Proxmox Vars to `vault.yml`

**Files:** Create `vault_vars/vault.yml.example`, modify `vault_vars/vault.yml`

- [ ] **Step 1: Write vault.yml.example**

```yaml
# vault_vars/vault.yml.example
# Copy to vault_vars/vault.yml, fill in real values, then:
#   ansible-vault encrypt vault_vars/vault.yml
---
hacluster_password: "CHANGE_ME"
drbd_secret: "CHANGE_ME"
mysql_root_password: "CHANGE_ME"
mysql_npm_password: "CHANGE_ME"
proxmox_api_host: "192.168.x.x"
proxmox_api_user: "root@pam"
proxmox_api_password: "CHANGE_ME"
proxmox_node1_vmid: 100
proxmox_node2_vmid: 101
```

- [ ] **Step 2: Add Proxmox vars to plaintext vault.yml (before encryption)**

Open `vault_vars/vault.yml` and append the five new Proxmox variables with real values:

```yaml
proxmox_api_host: "FILL_IN_PROXMOX_IP"
proxmox_api_user: "root@pam"
proxmox_api_password: "FILL_IN_PROXMOX_PASSWORD"
proxmox_node1_vmid: FILL_IN_NODE1_VMID
proxmox_node2_vmid: FILL_IN_NODE2_VMID
```

- [ ] **Step 3: Commit example file only (vault.yml is gitignored)**

```bash
git add vault_vars/vault.yml.example
git commit -m "chore: add vault.yml.example — documents all required secrets including proxmox_*"
```

---

## Task 22: Encrypt `vault.yml` and Commit

**Files:** Encrypt `vault_vars/vault.yml`

- [ ] **Step 1: Verify proxmox vars are filled in**

```bash
grep proxmox vault_vars/vault.yml
```
Expected: 5 lines with real values (not FILL_IN placeholders).

- [ ] **Step 2: Encrypt the vault**

```bash
ansible-vault encrypt vault_vars/vault.yml
```
Enter a strong vault password when prompted. Store this password securely (password manager).

- [ ] **Step 3: Verify encryption**

```bash
head -1 vault_vars/vault.yml
```
Expected: `$ANSIBLE_VAULT;1.1;AES256`

- [ ] **Step 4: Remove vault.yml from .gitignore (now safe to commit)**

Edit `.gitignore` — remove the `vault_vars/vault.yml` line, leaving:
```
# Ansible retry files
*.retry
```

- [ ] **Step 5: Commit encrypted vault and updated .gitignore**

```bash
git add vault_vars/vault.yml .gitignore
git commit -m "security: encrypt vault.yml with ansible-vault AES256, add proxmox_* secrets"
```

---

## Task 23: Delete Old Flat Structure and Dead Code

**Files:** Delete `tasks/`, `templates/`, `vars/` (old locations)

- [ ] **Step 1: Delete all old files**

```bash
cd /home/zencham/_ZENSEC/_NPM/ansible
rm -rf tasks/ templates/ vars/
```

- [ ] **Step 2: Verify old files are gone and role files remain**

```bash
ls -la
find roles/npm_ha/tasks/ -name "*.yml" | sort
```
Expected: `tasks/`, `templates/`, `vars/` absent at project root. Role tasks all present.

- [ ] **Step 3: Commit deletion**

```bash
git add -A
git commit -m "chore: remove flat task/template/var files — fully migrated to npm_ha role"
```

---

## Task 24: Update `README.md`

**Files:** Modify `README.md`

- [ ] **Step 1: Rewrite README.md**

```markdown
# NPM HA Cluster — Ansible Role

2-node High Availability Nginx Proxy Manager cluster using Pacemaker + Corosync + DRBD on Proxmox.

## Architecture

| Component | Detail |
|---|---|
| Nodes | MIBTECH-NPM-PROD-01 (192.168.206.33), MIBTECH-NPM-PROD-02 (192.168.206.40) |
| VIP | 192.168.206.220/24 |
| DRBD | /dev/sdb1 → /dev/drbd10 (app), /dev/sdb2 → /dev/drbd11 (db) |
| STONITH | fence_pve via Proxmox API |

## Prerequisites

1. Two Proxmox VMs running Debian Bookworm with:
   - `/dev/sdb` partitioned as `/dev/sdb1` (app) and `/dev/sdb2` (db)
   - DRBD kernel module available (`modprobe drbd`)
2. Ansible >= 2.14 on the controller
3. At least 2GB free disk space on each node
4. Proxmox API credentials with VM power management permissions

## Setup

### 1. Configure secrets

```bash
cp vault_vars/vault.yml.example vault_vars/vault.yml
# Edit vault_vars/vault.yml with real values
ansible-vault encrypt vault_vars/vault.yml
```

### 2. Configure inventory

Edit `inventory/hosts` if node hostnames/IPs differ from defaults.
Override any `defaults/main.yml` variable in `inventory/group_vars/ha_nodes.yml`.

### 3. DRBD prerequisite

Before running the playbook, initialize and sync DRBD block devices manually on both nodes.
The playbook handles `create-md` and `up` but requires the underlying partitions to exist.

### 4. Run the playbook

```bash
ansible-playbook main.yml --ask-vault-pass
```

## Selective Execution (Tags)

| Tag | Scope |
|---|---|
| `preflight` | Pre-flight checks only (always runs) |
| `prepare` | Package install, service enable |
| `drbd` | DRBD config, init, format |
| `app` | Mounts, compose file, systemd unit |
| `cluster` | Corosync/Pacemaker setup |
| `resources` | Pacemaker resources + constraints |
| `stonith` | fence_pve STONITH setup |

```bash
# Re-deploy compose config only
ansible-playbook main.yml --ask-vault-pass --tags app

# Re-configure STONITH after VMID change
ansible-playbook main.yml --ask-vault-pass --tags stonith
```

## Testing (Molecule)

```bash
pip install molecule molecule-docker

# Idempotency scenario
cd roles/npm_ha && molecule test -s default

# Preflight failure scenario
molecule test -s preflight

# STONITH configuration scenario
molecule test -s stonith
```

## STONITH Notes

`fence_pve` uses the Proxmox API to power-cycle a VM when it becomes unresponsive.
Each node has a dedicated STONITH resource that fences itself — the peer triggers it.
Verify the `fence_pve` parameter name `plug` matches your installed `fence-agents-pve` version:

```bash
pcs stonith describe fence_pve | grep -A2 plug
```
If the parameter is named differently (e.g., `vmid`), update `roles/npm_ha/tasks/stonith.yml` accordingly.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: full README rewrite — vault, tags, molecule, STONITH prerequisites"
```

---

## Task 25: Final Verification

- [ ] **Step 1: Verify complete role structure**

```bash
find /home/zencham/_ZENSEC/_NPM/ansible -not -path '*/.git/*' | sort
```
Confirm: no stray `tasks/`, `templates/`, `vars/` at project root. Role structure complete.

- [ ] **Step 2: Syntax check**

```bash
cd /home/zencham/_ZENSEC/_NPM/ansible
ansible-playbook main.yml --syntax-check --ask-vault-pass
```
Expected: `playbook: main.yml` with no errors.

- [ ] **Step 3: Run full Molecule suite**

```bash
cd roles/npm_ha
molecule test -s default
molecule test -s preflight
molecule test -s stonith
```
Expected: All three scenarios pass.

- [ ] **Step 4: Verify git log is clean**

```bash
cd /home/zencham/_ZENSEC/_NPM/ansible
git log --oneline
```
Expected: All commits present, no dirty state.

---

## Self-Review Checklist

- [x] **Spec goal: role conversion** → Tasks 1–14, 18 (scaffold + all task files + templates + top-level playbook)
- [x] **Spec goal: vault encryption** → Tasks 21–22
- [x] **Spec goal: fence_pve STONITH** → Task 12 (stonith.yml) + Task 17 (molecule stonith)
- [x] **Spec goal: pre-flight validation** → Task 6 (preflight.yml) + Task 16 (molecule preflight)
- [x] **Spec goal: parametrize defaults** → Task 3 (defaults/main.yml) + Tasks 8, 9, 10, 11, 14 (var substitution in migrated tasks and templates)
- [x] **Spec goal: execution tags** → Task 13 (tasks/main.yml)
- [x] **Spec goal: handlers** → Task 4 (handlers/main.yml) + Task 9 (notify in prepare_app.yml)
- [x] **Spec goal: Molecule** → Tasks 15–17
- [x] **Spec goal: ansible.cfg** → Task 19
- [x] **Spec goal: .gitignore** → Task 20
- [x] **Spec goal: vault.yml.example** → Task 21
- [x] **Spec goal: README** → Task 24
- [x] **Spec goal: delete dead code** → Task 23 (systemd.yml + all old flat files)
- [x] **Extra: drbd_device_app/db vars** → Task 3 + Tasks 8, 11, 14 (missing from spec, caught during planning)
