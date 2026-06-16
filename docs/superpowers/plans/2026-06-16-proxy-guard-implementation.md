# proxy_guard Role Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `proxy_guard` Ansible role + `proxy_backup.yml`/`proxy_verify.yml` playbooks that snapshot NPM reverse-proxy config to a file, verify nothing is lost after re-running `main.yml` on the live cluster, and restore missing proxy hosts on demand.

**Architecture:** A controller-only role (local connection) reusing `cert_manager`'s NPM API auth (`POST /api/tokens` → Bearer token) and the `id/timestamp`-stripping write pattern from `cert_manager/tasks/sync_proxy_hosts.yml`. The "missing host" computation is factored into a pure, offline-testable task file keyed on the **sorted `domain_names` set** (not `id`, which is unstable across restore). Backup and verify are GET-only and safe to run against live production; restore is the only writer and is manually triggered via `--tags restore`.

**Tech Stack:** Ansible (core ≥2.14), `ansible.builtin.uri` for the NPM REST API, Jinja2 for data assembly. No new dependencies, no new secrets (reuses `controller` group_vars + vault).

---

## File Structure

```
proxy_backup.yml                       — CREATE: thin playbook, hosts: controller, tag-driven
proxy_verify.yml                       — CREATE: thin playbook, hosts: controller, tags verify/restore
.gitignore                             — MODIFY: add backups/
README.md                              — MODIFY: document proxy_guard usage

roles/proxy_guard/
  meta/main.yml                        — CREATE: galaxy_info (match cert_manager)
  vars/main.yml                        — CREATE: empty (project pattern)
  defaults/main.yml                    — CREATE: backup_dir, capture list, sample_domain
  tasks/main.yml                       — CREATE: auth, then dispatch by tag
  tasks/auth.yml                       — CREATE: POST /api/tokens -> npm_token
  tasks/backup.yml                     — CREATE: GET all types -> assemble JSON -> write
  tasks/compute_missing.yml            — CREATE: pure logic, snapshot vs live -> proxy_guard_missing
  tasks/verify.yml                     — CREATE: GET live, load snapshot, compute, assert
  tasks/restore.yml                    — CREATE: compute, POST missing proxy hosts
  templates/snapshot.json.j2           — CREATE: snapshot document template

tests/
  test_compute_missing.yml             — CREATE: offline test of compute_missing logic
  fixtures/snapshot_sample.json        — CREATE: fixture snapshot for the test
```

---

### Task 1: Scaffold role skeleton + gitignore

**Files:**
- Create: `roles/proxy_guard/meta/main.yml`
- Create: `roles/proxy_guard/vars/main.yml`
- Create: `roles/proxy_guard/defaults/main.yml`
- Modify: `.gitignore`

- [ ] **Step 1: Create meta/main.yml**

```yaml
---
galaxy_info:
  author: MIBTECH
  description: Snapshot, verify, and restore NPM reverse-proxy config via the NPM API
  license: MIT
  min_ansible_version: "2.14"
dependencies: []
```

- [ ] **Step 2: Create vars/main.yml**

```yaml
---
```

- [ ] **Step 3: Create defaults/main.yml**

```yaml
---
# Where snapshots are written on the controller.
proxy_guard_backup_dir: "{{ playbook_dir }}/backups"

# NPM API resource types captured in each snapshot.
proxy_guard_capture:
  - proxy-hosts
  - redirection-hosts
  - dead-hosts
  - streams
  - access-lists
  - certificates

# Optional end-to-end check in verify: a domain expected to return 2xx/3xx
# through the VIP. Empty string disables the live-HTTP check.
proxy_guard_sample_domain: ""
```

- [ ] **Step 4: Add backups/ to .gitignore**

Append to `.gitignore`:

```
# NPM proxy-config snapshots — live data, not source
backups/
```

- [ ] **Step 5: Verify YAML is valid**

Run: `ansible-lint roles/proxy_guard/ 2>&1 | tail -20`
Expected: no syntax errors (warnings about empty tasks are fine; tasks come later).

- [ ] **Step 6: Commit**

```bash
git add roles/proxy_guard/meta/main.yml roles/proxy_guard/vars/main.yml roles/proxy_guard/defaults/main.yml .gitignore
git commit -m "feat(proxy_guard): scaffold role defaults and gitignore backups"
```

---

### Task 2: API auth + tag dispatcher

**Files:**
- Create: `roles/proxy_guard/tasks/auth.yml`
- Create: `roles/proxy_guard/tasks/main.yml`

- [ ] **Step 1: Create tasks/auth.yml**

```yaml
---
- name: Authenticate to NPM API
  ansible.builtin.uri:
    url: "{{ npm_api_base_url }}/api/tokens"
    method: POST
    body_format: json
    body:
      identity: "{{ npm_admin_email }}"
      secret: "{{ npm_admin_password }}"
    status_code: 200
  register: npm_auth
  no_log: true

- name: Set NPM token fact
  ansible.builtin.set_fact:
    npm_token: "{{ npm_auth.json.token }}"
  no_log: true
```

- [ ] **Step 2: Create tasks/main.yml**

```yaml
---
- name: Authenticate to NPM API
  ansible.builtin.import_tasks: auth.yml
  tags: [backup, verify, restore]

- name: Snapshot NPM proxy configuration
  ansible.builtin.import_tasks: backup.yml
  tags: backup

- name: Verify proxy hosts survived
  ansible.builtin.import_tasks: verify.yml
  tags: verify

- name: Restore missing proxy hosts from snapshot
  ansible.builtin.import_tasks: restore.yml
  tags: restore
```

- [ ] **Step 3: Create placeholder task files so import resolves**

Create `roles/proxy_guard/tasks/backup.yml`, `verify.yml`, `restore.yml` each containing only:

```yaml
---
```

- [ ] **Step 4: Verify syntax (playbooks come in later tasks, so test the role via a temp play)**

Run:
```bash
printf -- '---\n- hosts: localhost\n  connection: local\n  gather_facts: false\n  roles: [proxy_guard]\n' > /tmp/_pg_syntax.yml
ansible-playbook /tmp/_pg_syntax.yml --syntax-check
```
Expected: `playbook: /tmp/_pg_syntax.yml` with no error.

- [ ] **Step 5: Commit**

```bash
git add roles/proxy_guard/tasks/auth.yml roles/proxy_guard/tasks/main.yml roles/proxy_guard/tasks/backup.yml roles/proxy_guard/tasks/verify.yml roles/proxy_guard/tasks/restore.yml
git commit -m "feat(proxy_guard): add API auth and tag dispatcher"
```

---

### Task 3: compute_missing core logic (TDD, offline)

A proxy host's stable identity is the **sorted set of its `domain_names`**. `compute_missing.yml` takes two pre-set facts — `_pg_live_hosts` (current live proxy-hosts) and `_pg_snapshot_hosts` (proxy-hosts from the snapshot) — and produces `proxy_guard_missing`: the list of snapshot hosts whose domain set is not present-and-enabled in live. This file performs **no I/O**, so it is tested fully offline.

**Files:**
- Create: `tests/fixtures/snapshot_sample.json`
- Create: `tests/test_compute_missing.yml`
- Create: `roles/proxy_guard/tasks/compute_missing.yml`

- [ ] **Step 1: Create the test fixture**

`tests/fixtures/snapshot_sample.json`:

```json
{
  "captured_at": "2026-06-16T12:00:00Z",
  "proxy-hosts": [
    {"id": 14, "domain_names": ["app.mibtech.ma"], "enabled": 1},
    {"id": 22, "domain_names": ["portal.visionhis.ma"], "enabled": 1},
    {"id": 31, "domain_names": ["api.myakdital.ma", "api2.myakdital.ma"], "enabled": 1}
  ]
}
```

- [ ] **Step 2: Write the failing test**

`tests/test_compute_missing.yml`:

```yaml
---
# Offline unit test for roles/proxy_guard/tasks/compute_missing.yml.
# Run: ansible-playbook tests/test_compute_missing.yml
- name: Test compute_missing logic
  hosts: localhost
  connection: local
  gather_facts: false
  vars:
    _snapshot: "{{ lookup('file', 'tests/fixtures/snapshot_sample.json') | from_json }}"
  tasks:
    # Case 1: one host deleted (id 22 gone), one disabled (id 31 enabled=0).
    # Expect both 22 and 31 reported missing; 14 present.
    - name: Arrange live state with a deletion and a disable
      ansible.builtin.set_fact:
        _pg_snapshot_hosts: "{{ _snapshot['proxy-hosts'] }}"
        _pg_live_hosts:
          - {id: 14, domain_names: ["app.mibtech.ma"], enabled: 1}
          - {id: 99, domain_names: ["api.myakdital.ma", "api2.myakdital.ma"], enabled: 0}

    - name: Run logic under test
      ansible.builtin.include_tasks: ../roles/proxy_guard/tasks/compute_missing.yml

    - name: Collect missing domain sets for assertion
      ansible.builtin.set_fact:
        _missing_domains: "{{ proxy_guard_missing | map(attribute='domain_names') | map('sort') | list }}"

    - name: Assert deleted and disabled hosts are reported missing, present host is not
      ansible.builtin.assert:
        that:
          - proxy_guard_missing | length == 2
          - "['portal.visionhis.ma'] in _missing_domains"
          - "['api.myakdital.ma', 'api2.myakdital.ma'] in _missing_domains"
          - "['app.mibtech.ma'] not in _missing_domains"
        fail_msg: "compute_missing produced wrong set: {{ proxy_guard_missing }}"
        success_msg: "compute_missing OK"

    # Case 2: live fully matches snapshot -> nothing missing.
    - name: Arrange live state identical to snapshot
      ansible.builtin.set_fact:
        _pg_live_hosts: "{{ _snapshot['proxy-hosts'] }}"

    - name: Run logic under test (happy path)
      ansible.builtin.include_tasks: ../roles/proxy_guard/tasks/compute_missing.yml

    - name: Assert nothing missing when live matches snapshot
      ansible.builtin.assert:
        that:
          - proxy_guard_missing | length == 0
        fail_msg: "Expected no missing hosts, got: {{ proxy_guard_missing }}"
        success_msg: "compute_missing happy-path OK"
```

- [ ] **Step 3: Run the test, verify it fails**

Run: `ansible-playbook tests/test_compute_missing.yml`
Expected: FAIL — `Could not find or access '.../roles/proxy_guard/tasks/compute_missing.yml'` (file not created yet).

- [ ] **Step 4: Implement compute_missing.yml**

`roles/proxy_guard/tasks/compute_missing.yml`:

```yaml
---
# Pure logic: given _pg_snapshot_hosts and _pg_live_hosts (lists of NPM
# proxy-host objects), set proxy_guard_missing to the snapshot hosts whose
# sorted domain_names set is not present AND enabled in the live list.
# Identity = sorted(domain_names), because NPM ids are not stable across restore.
- name: Build signatures of enabled live proxy hosts
  ansible.builtin.set_fact:
    _pg_live_signatures: >-
      {{ _pg_live_hosts
         | selectattr('enabled', 'in', [1, true])
         | map(attribute='domain_names')
         | map('sort') | map('join', ',')
         | list }}

- name: Initialize missing list
  ansible.builtin.set_fact:
    proxy_guard_missing: []

- name: Collect snapshot hosts absent from enabled live signatures
  ansible.builtin.set_fact:
    proxy_guard_missing: "{{ proxy_guard_missing + [item] }}"
  loop: "{{ _pg_snapshot_hosts }}"
  loop_control:
    label: "{{ item.domain_names | default([]) | join(',') }}"
  when:
    - item.domain_names is defined
    - (item.domain_names | sort | join(',')) not in _pg_live_signatures
```

- [ ] **Step 5: Run the test, verify it passes**

Run: `ansible-playbook tests/test_compute_missing.yml`
Expected: PASS — both "compute_missing OK" and "compute_missing happy-path OK" asserts succeed, play recap shows `failed=0`.

- [ ] **Step 6: Commit**

```bash
git add tests/fixtures/snapshot_sample.json tests/test_compute_missing.yml roles/proxy_guard/tasks/compute_missing.yml
git commit -m "feat(proxy_guard): add offline-tested compute_missing logic"
```

---

### Task 4: Backup task + snapshot template + playbook

**Files:**
- Create: `roles/proxy_guard/templates/snapshot.json.j2`
- Create: `roles/proxy_guard/tasks/backup.yml` (replace placeholder)
- Create: `proxy_backup.yml`

- [ ] **Step 1: Create the snapshot template**

`roles/proxy_guard/templates/snapshot.json.j2`:

```jinja
{
  "captured_at": "{{ ansible_date_time.iso8601 }}",
  "npm_api_base_url": "{{ npm_api_base_url }}",
{% for type in proxy_guard_capture %}
  "{{ type }}": {{ _pg_results[type] | to_json }}{{ "," if not loop.last else "" }}
{% endfor %}
}
```

- [ ] **Step 2: Implement backup.yml**

`roles/proxy_guard/tasks/backup.yml`:

```yaml
---
- name: Gather facts for timestamp
  ansible.builtin.setup:
    gather_subset: ["min"]

- name: Fetch each NPM resource type
  ansible.builtin.uri:
    url: "{{ npm_api_base_url }}/api/nginx/{{ item }}"
    method: GET
    headers:
      Authorization: "Bearer {{ npm_token }}"
    status_code: 200
  loop: "{{ proxy_guard_capture }}"
  register: _pg_fetch

- name: Assemble results map keyed by resource type
  ansible.builtin.set_fact:
    _pg_results: "{{ dict(proxy_guard_capture | zip(_pg_fetch.results | map(attribute='json') | list)) }}"

- name: Guard against an empty proxy-hosts snapshot clobbering a good one
  ansible.builtin.assert:
    that:
      - _pg_results['proxy-hosts'] | length > 0
    fail_msg: "Refusing to write snapshot: NPM returned zero proxy-hosts (transient API issue?)"
    success_msg: "{{ _pg_results['proxy-hosts'] | length }} proxy-hosts fetched"

- name: Ensure backup directory exists
  ansible.builtin.file:
    path: "{{ proxy_guard_backup_dir }}"
    state: directory
    mode: "0700"

- name: Write timestamped snapshot
  ansible.builtin.template:
    src: snapshot.json.j2
    dest: "{{ proxy_guard_backup_dir }}/npm-{{ ansible_date_time.iso8601_basic_short }}.json"
    mode: "0600"
  register: _pg_snapshot_file

- name: Update latest snapshot pointer
  ansible.builtin.copy:
    src: "{{ _pg_snapshot_file.dest }}"
    dest: "{{ proxy_guard_backup_dir }}/npm-latest.json"
    mode: "0600"
    remote_src: true

- name: Report snapshot contents
  ansible.builtin.debug:
    msg: >-
      Snapshot written to {{ _pg_snapshot_file.dest }} —
      {% for type in proxy_guard_capture %}{{ type }}={{ _pg_results[type] | length }}{{ " " if not loop.last else "" }}{% endfor %}
```

- [ ] **Step 3: Create the proxy_backup.yml playbook**

`proxy_backup.yml`:

```yaml
---
- name: Snapshot NPM reverse-proxy configuration
  hosts: controller
  gather_facts: false
  roles:
    - role: proxy_guard
  tags: backup
```

- [ ] **Step 4: Syntax-check the playbook**

Run: `ansible-playbook proxy_backup.yml --syntax-check`
Expected: `playbook: proxy_backup.yml` with no error.

- [ ] **Step 5: Live acceptance run (GET-only, safe on production)**

Run: `ansible-playbook proxy_backup.yml`
Expected: PASS; `backups/npm-latest.json` exists. Verify:
```bash
test -s backups/npm-latest.json && python3 -c "import json;d=json.load(open('backups/npm-latest.json'));print('proxy-hosts:',len(d['proxy-hosts']))"
```
Expected: prints a non-zero proxy-host count.

- [ ] **Step 6: Commit**

```bash
git add roles/proxy_guard/templates/snapshot.json.j2 roles/proxy_guard/tasks/backup.yml proxy_backup.yml
git commit -m "feat(proxy_guard): snapshot NPM config to timestamped JSON"
```

---

### Task 5: Verify task + playbook

**Files:**
- Create: `roles/proxy_guard/tasks/verify.yml` (replace placeholder)
- Create: `proxy_verify.yml`

- [ ] **Step 1: Implement verify.yml**

`roles/proxy_guard/tasks/verify.yml`:

```yaml
---
- name: Fail if no snapshot exists yet
  ansible.builtin.stat:
    path: "{{ proxy_guard_backup_dir }}/npm-latest.json"
  register: _pg_latest_stat

- name: Assert a snapshot is present
  ansible.builtin.assert:
    that: _pg_latest_stat.stat.exists
    fail_msg: "No snapshot found. Run: ansible-playbook proxy_backup.yml"

- name: Load latest snapshot
  ansible.builtin.set_fact:
    _pg_snapshot: "{{ lookup('file', proxy_guard_backup_dir + '/npm-latest.json') | from_json }}"

- name: Fetch current live proxy hosts
  ansible.builtin.uri:
    url: "{{ npm_api_base_url }}/api/nginx/proxy-hosts"
    method: GET
    headers:
      Authorization: "Bearer {{ npm_token }}"
    status_code: 200
  register: _pg_live

- name: Set inputs for compute_missing
  ansible.builtin.set_fact:
    _pg_snapshot_hosts: "{{ _pg_snapshot['proxy-hosts'] }}"
    _pg_live_hosts: "{{ _pg_live.json }}"

- name: Compute missing proxy hosts
  ansible.builtin.include_tasks: compute_missing.yml

- name: Assert no proxy hosts were lost
  ansible.builtin.assert:
    that:
      - proxy_guard_missing | length == 0
    fail_msg: >-
      VERIFY FAILED: {{ proxy_guard_missing | length }} proxy host(s) missing:
      {% for h in proxy_guard_missing %}
        - {{ h.domain_names | join(', ') }}{% endfor %}

      To restore: ansible-playbook proxy_verify.yml --tags restore
    success_msg: "VERIFY OK: all {{ _pg_snapshot_hosts | length }} snapshot proxy hosts present and enabled"

- name: Live HTTP check through the VIP (optional)
  ansible.builtin.uri:
    url: "https://{{ proxy_guard_sample_domain }}"
    method: GET
    validate_certs: false
    status_code: [200, 201, 204, 301, 302, 307, 308, 401, 403]
  when: proxy_guard_sample_domain | length > 0
```

- [ ] **Step 2: Create the proxy_verify.yml playbook**

`proxy_verify.yml`:

```yaml
---
- name: Verify (and optionally restore) NPM reverse-proxy configuration
  hosts: controller
  gather_facts: false
  roles:
    - role: proxy_guard
  # Default run = verify only. `--tags restore` runs the restore path.
  tags: verify
```

- [ ] **Step 3: Syntax-check**

Run: `ansible-playbook proxy_verify.yml --syntax-check`
Expected: `playbook: proxy_verify.yml` with no error.

- [ ] **Step 4: Live acceptance run (GET-only, safe on production)**

Run: `ansible-playbook proxy_verify.yml`
Expected: PASS with "VERIFY OK: all N snapshot proxy hosts present and enabled" (run immediately after a fresh backup, so snapshot == live).

- [ ] **Step 5: Commit**

```bash
git add roles/proxy_guard/tasks/verify.yml proxy_verify.yml
git commit -m "feat(proxy_guard): verify proxy hosts survived re-converge"
```

---

### Task 6: Restore task

**Files:**
- Create: `roles/proxy_guard/tasks/restore.yml` (replace placeholder)

- [ ] **Step 1: Implement restore.yml**

`roles/proxy_guard/tasks/restore.yml`:

```yaml
---
- name: Load latest snapshot
  ansible.builtin.set_fact:
    _pg_snapshot: "{{ lookup('file', proxy_guard_backup_dir + '/npm-latest.json') | from_json }}"

- name: Fetch current live proxy hosts
  ansible.builtin.uri:
    url: "{{ npm_api_base_url }}/api/nginx/proxy-hosts"
    method: GET
    headers:
      Authorization: "Bearer {{ npm_token }}"
    status_code: 200
  register: _pg_live

- name: Set inputs for compute_missing
  ansible.builtin.set_fact:
    _pg_snapshot_hosts: "{{ _pg_snapshot['proxy-hosts'] }}"
    _pg_live_hosts: "{{ _pg_live.json }}"

- name: Compute missing proxy hosts
  ansible.builtin.include_tasks: compute_missing.yml

- name: Report restore scope
  ansible.builtin.debug:
    msg: "Restoring {{ proxy_guard_missing | length }} missing proxy host(s)"

- name: Re-create each missing proxy host
  ansible.builtin.uri:
    url: "{{ npm_api_base_url }}/api/nginx/proxy-hosts"
    method: POST
    headers:
      Authorization: "Bearer {{ npm_token }}"
    body_format: json
    body: >-
      {{ host | dict2items
         | rejectattr('key', 'in', ['id', 'created_on', 'modified_on', 'owner_user_id'])
         | list | items2dict }}
    status_code: 201
  loop: "{{ proxy_guard_missing }}"
  loop_control:
    loop_var: host
    label: "{{ host.domain_names | join(', ') }}"
  register: _pg_restored

- name: Report restore result
  ansible.builtin.debug:
    msg: "Restored {{ _pg_restored.results | default([]) | length }} proxy host(s). Re-run verify to confirm."
```

- [ ] **Step 2: Syntax-check (restore tag is already wired in tasks/main.yml from Task 2)**

Run: `ansible-playbook proxy_verify.yml --tags restore --syntax-check`
Expected: `playbook: proxy_verify.yml` with no error.

- [ ] **Step 3: Commit**

```bash
git add roles/proxy_guard/tasks/restore.yml
git commit -m "feat(proxy_guard): restore missing proxy hosts from snapshot"
```

---

### Task 7: Documentation + lint

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add a proxy_guard section to README.md**

Append under the existing role/playbook documentation (match the README's existing heading style):

```markdown
## Proxy Guard — safe re-converge of the live cluster

`proxy_guard` snapshots the NPM reverse-proxy configuration so `main.yml` can be
re-run against the already-deployed cluster to prove idempotency without risking
the live proxy hosts.

Procedure:

    ansible-playbook proxy_backup.yml      # snapshot proxies -> backups/npm-latest.json
    ansible-playbook main.yml              # re-converge (DRBD/cluster/resource steps skip)
    ansible-playbook proxy_verify.yml      # assert nothing was lost

If verify reports missing hosts, restore them from the snapshot:

    ansible-playbook proxy_verify.yml --tags restore

Snapshots are written to `backups/` (gitignored — they contain live domain
config). `proxy_backup.yml` and `proxy_verify.yml` are GET-only and safe to run
against production; `--tags restore` is the only path that writes to NPM.

Set `proxy_guard_sample_domain` (role default) to a real domain to also probe a
live site through the VIP during verify.
```

- [ ] **Step 2: Run ansible-lint on the finished role**

Run: `ansible-lint roles/proxy_guard/ proxy_backup.yml proxy_verify.yml`
Expected: no errors (resolve any reported issues before committing).

- [ ] **Step 3: Re-run the offline logic test to confirm nothing regressed**

Run: `ansible-playbook tests/test_compute_missing.yml`
Expected: PASS, `failed=0`.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs(proxy_guard): document backup/verify/restore procedure"
```

---

## Acceptance (full live validation, in order)

1. `ansible-playbook proxy_backup.yml` → `backups/npm-latest.json` has expected proxy-host count.
2. `ansible-playbook proxy_verify.yml` → PASS (snapshot == live).
3. `ansible-playbook main.yml` → DRBD/cluster/resource steps report `skipping`; play `failed=0`.
4. `ansible-playbook proxy_verify.yml` → still PASS (proxies survived the re-run).

This sequence is the definition of done: it proves `main.yml` is idempotent on the live cluster and the reverse proxies are intact.

## Self-Review Notes

- **Spec coverage:** snapshot scope (all 6 types) → Task 4; manual-confirm restore → Tasks 5 (verify fails loudly with command) + 6 (manual `--tags restore`); empty-snapshot guard → Task 4 Step 2; gitignored backups → Task 1; identity-by-domain fix → Task 3.
- **Placeholder scan:** the only multi-variant block is Task 3 Step 4, where the experimental Jinja is explicitly marked dead-end and the implementer is directed to the final loop-based block. All other steps contain complete, runnable content.
- **Type consistency:** `proxy_guard_missing`, `_pg_snapshot_hosts`, `_pg_live_hosts`, `_pg_live_signatures` are named identically across compute_missing, verify, restore, and the test.
