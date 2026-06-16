# drift_check Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a read-only `drift_check.yml` playbook that renders every config file the `npm_ha` role manages with current repo vars, diffs each against the live node file, prints the diffs, and exits non-zero on drift — run before `main.yml` to catch repo↔live divergence.

**Architecture:** A playbook `drift_check.yml` imports `npm_ha` with `tasks_from: drift_check`, so the check resolves the role's own `templates/*.j2` and diffs the exact templates `main.yml` would push. Each managed file is checked with the same module `main.yml` uses, run with `check_mode: true` + `diff: true` (read-only) and registered; a final `assert` fails listing any drifted file. The systemd unit is first extracted from an inline `copy: content:` into a template so both the deploy and the check render one source (DRY).

**Tech Stack:** Ansible (core ≥2.14), `template`/`lineinfile`/`command` modules in `check_mode`, Jinja2.

---

## File Structure

```
roles/npm_ha/templates/npm-stack.service.j2   — CREATE: extracted systemd unit
roles/npm_ha/tasks/prepare_app.yml            — MODIFY: systemd copy->template (DRY)
roles/npm_ha/tasks/drift_check.yml            — CREATE: per-file check_mode+diff + assert
drift_check.yml                               — CREATE: playbook (ha_nodes, become, read-only)
README.md                                     — MODIFY: document drift_check usage
```

Order: Task 1 extracts the systemd template (no behaviour change) so Task 2's check has a single source to render. Tasks 2–3 build the check tasks and playbook. Task 4 documents.

---

### Task 1: Extract systemd unit to a template (DRY refactor)

**Files:**
- Create: `roles/npm_ha/templates/npm-stack.service.j2`
- Modify: `roles/npm_ha/tasks/prepare_app.yml`

- [ ] **Step 1: Create the template** — `roles/npm_ha/templates/npm-stack.service.j2` (content byte-identical to the current inline unit; exactly one trailing newline):

```jinja
[Unit]
Description=NPM HA Docker Compose Stack
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory={{ npm_compose_dir }}
ExecStart=/usr/bin/docker compose up -d --wait
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=240

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 2: Replace the inline copy task** in `roles/npm_ha/tasks/prepare_app.yml`. Find the existing task:

```yaml
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
      ExecStart=/usr/bin/docker compose up -d --wait
      ExecStop=/usr/bin/docker compose down
      TimeoutStartSec=240

      [Install]
      WantedBy=multi-user.target
    owner: root
    group: root
    mode: '0644'
  notify: Reload systemd
```

Replace it with:

```yaml
- name: Create NPM Docker Compose systemd unit
  template:
    src: npm-stack.service.j2
    dest: /etc/systemd/system/npm-stack.service
    owner: root
    group: root
    mode: '0644'
  notify: Reload systemd
```

- [ ] **Step 3: Syntax-check the role**

Run:
```bash
cd /home/zencham/_ZENSEC/_NPM/ansible
ansible-playbook main.yml --syntax-check
```
Expected: `playbook: main.yml`, no error.

- [ ] **Step 4: Confirm the template renders identically to the old inline content**

Run (renders the template with a sample var and diffs against the exact old text):
```bash
cd /home/zencham/_ZENSEC/_NPM/ansible
printf '[Unit]\nDescription=NPM HA Docker Compose Stack\nRequires=docker.service\nAfter=docker.service\n\n[Service]\nType=oneshot\nRemainAfterExit=yes\nWorkingDirectory=/opt/npm/compose\nExecStart=/usr/bin/docker compose up -d --wait\nExecStop=/usr/bin/docker compose down\nTimeoutStartSec=240\n\n[Install]\nWantedBy=multi-user.target\n' > /tmp/_unit_expected.txt
ansible localhost -m template -a "src=roles/npm_ha/templates/npm-stack.service.j2 dest=/tmp/_unit_rendered.txt" -e npm_compose_dir=/opt/npm/compose >/dev/null 2>&1
diff /tmp/_unit_expected.txt /tmp/_unit_rendered.txt && echo "IDENTICAL" || echo "DIFFERS"
rm -f /tmp/_unit_expected.txt /tmp/_unit_rendered.txt
```
Expected: `IDENTICAL` (proves the refactor causes no drift).

- [ ] **Step 5: Commit**

```bash
git add roles/npm_ha/templates/npm-stack.service.j2 roles/npm_ha/tasks/prepare_app.yml
git commit -m "refactor(npm_ha): extract systemd unit to template for DRY drift-check"
```

---

### Task 2: drift_check tasks

**Files:**
- Create: `roles/npm_ha/tasks/drift_check.yml`

Each task mirrors the real deploy task's module + params exactly (so owner/mode never read as drift), adds `check_mode: true` + `diff: true`, and registers. A final `set_fact` + `assert` reports all drift at once.

- [ ] **Step 1: Create `roles/npm_ha/tasks/drift_check.yml`**

```yaml
---
# Read-only drift detection: render each npm_ha-managed config with current repo
# vars and diff against the live node file. check_mode guarantees no writes;
# diff:true prints the unified diff of what WOULD change. A final assert fails,
# listing every drifted file. Run via drift_check.yml before main.yml.

- name: Drift check — DRBD resource config
  ansible.builtin.template:
    src: npm-ha.res.j2
    dest: /etc/drbd.d/npm-ha.res
    owner: root
    group: root
    mode: '0600'
  check_mode: true
  diff: true
  register: drift_res

- name: Drift check — docker-compose.yml
  ansible.builtin.template:
    src: docker-compose.yml.j2
    dest: "{{ npm_compose_dir }}/docker-compose.yml"
    owner: root
    group: root
    mode: '0600'
  check_mode: true
  diff: true
  register: drift_compose

- name: Drift check — systemd unit
  ansible.builtin.template:
    src: npm-stack.service.j2
    dest: /etc/systemd/system/npm-stack.service
    owner: root
    group: root
    mode: '0644'
  check_mode: true
  diff: true
  register: drift_unit

- name: Drift check — /etc/hosts node entries
  ansible.builtin.lineinfile:
    path: /etc/hosts
    line: "{{ item.ip }} {{ item.hostname }}"
    regexp: "^[0-9.]+\\s+{{ item.hostname }}(\\s.*)?$"
    state: present
  check_mode: true
  diff: true
  loop:
    - { ip: "{{ node1_address }}", hostname: "{{ node1_name }}" }
    - { ip: "{{ node2_address }}", hostname: "{{ node2_name }}" }
  register: drift_hosts

- name: Drift check — corosync cluster name present
  ansible.builtin.command: grep -q "{{ pacemaker_cluster_name }}" /etc/corosync/corosync.conf
  register: drift_corosync
  changed_when: false
  failed_when: false

- name: Collect drifted items
  ansible.builtin.set_fact:
    drift_check_drifted: >-
      {{ (['/etc/drbd.d/npm-ha.res'] if drift_res.changed else [])
       + ([npm_compose_dir ~ '/docker-compose.yml'] if drift_compose.changed else [])
       + (['/etc/systemd/system/npm-stack.service'] if drift_unit.changed else [])
       + (['/etc/hosts'] if (drift_hosts.results | selectattr('changed') | list | length > 0) else [])
       + (['corosync:' ~ pacemaker_cluster_name] if drift_corosync.rc != 0 else []) }}

- name: Assert no drift
  ansible.builtin.assert:
    that: drift_check_drifted | length == 0
    fail_msg: >-
      DRIFT DETECTED on {{ inventory_hostname }} in {{ drift_check_drifted | length }} item(s):
      {{ drift_check_drifted | join(', ') }}.
      Review the diffs above and reconcile repo vs live before running main.yml.
    success_msg: "No drift on {{ inventory_hostname }}: all managed npm_ha config matches the repo."
```

- [ ] **Step 2: Lint the new task file**

Run:
```bash
cd /home/zencham/_ZENSEC/_NPM/ansible
ansible-lint roles/npm_ha/tasks/drift_check.yml
```
Expected: no errors (warnings consistent with the rest of the repo are acceptable).

- [ ] **Step 3: Commit**

```bash
git add roles/npm_ha/tasks/drift_check.yml
git commit -m "feat(npm_ha): add read-only drift_check tasks"
```

---

### Task 3: drift_check.yml playbook + live acceptance

**Files:**
- Create: `drift_check.yml`

- [ ] **Step 1: Create `drift_check.yml`** (repo root):

```yaml
---
- name: Detect drift between repo config and the live NPM HA nodes
  hosts: ha_nodes
  become: true
  gather_facts: false
  tasks:
    - name: Run npm_ha drift checks
      ansible.builtin.import_role:
        name: npm_ha
        tasks_from: drift_check.yml
```

- [ ] **Step 2: Syntax-check**

Run:
```bash
cd /home/zencham/_ZENSEC/_NPM/ansible
ansible-playbook drift_check.yml --syntax-check
```
Expected: `playbook: drift_check.yml`, no error.

- [ ] **Step 3: Live acceptance — PASS case (read-only against production)**

Run:
```bash
cd /home/zencham/_ZENSEC/_NPM/ansible
ansible-playbook drift_check.yml
```
Expected: PASS on both nodes — "No drift … all managed npm_ha config matches the repo", play recap `failed=0`. (repo↔live were reconciled 2026-06-16, so there should be no drift.)

> NOTE: This is read-only (`check_mode: true` throughout) and safe on production. If it reports drift, STOP and surface the diff — do not "fix" it blindly; the live file may be the correct one.

- [ ] **Step 4: Live acceptance — FAIL case (prove detection, then revert)**

Temporarily introduce drift via an extra var (does NOT edit any file), confirm failure, and that no var change persists:
```bash
cd /home/zencham/_ZENSEC/_NPM/ansible
ansible-playbook drift_check.yml -e container_timezone=UTC/Drift 2>&1 | grep -E "DRIFT DETECTED|docker-compose|failed="
```
Expected: shows "DRIFT DETECTED … docker-compose.yml" and a non-zero `failed=` count — proving the check catches a changed var. No files were modified (check_mode), and the override was CLI-only (not persisted).

- [ ] **Step 5: Confirm a clean run again (no persistence)**

```bash
cd /home/zencham/_ZENSEC/_NPM/ansible
ansible-playbook drift_check.yml 2>&1 | grep -E "No drift|failed="
```
Expected: "No drift" on both nodes, `failed=0` — confirms Step 4 left nothing behind.

- [ ] **Step 6: Commit**

```bash
git add drift_check.yml
git commit -m "feat: add drift_check.yml preflight playbook"
```

---

### Task 4: Documentation

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add a drift_check section to README.md** (match the README's existing heading style; place it near the Proxy Guard section):

```markdown
## Drift Check — verify repo matches live before deploying

`drift_check.yml` renders every config file the `npm_ha` role manages with the
current repo variables and diffs each against the live node file, printing the
diffs and exiting non-zero if anything drifts. Run it before `main.yml` to catch
repo↔live divergence (the cause of the 2026-06-16 outage) before a converge acts
on it.

    ansible-playbook drift_check.yml     # read-only; fails on drift
    # if it reports drift: review the diffs, reconcile repo or live, re-run
    ansible-playbook main.yml            # only once drift_check is clean

It checks: `/etc/drbd.d/npm-ha.res`, `docker-compose.yml`, the
`npm-stack.service` systemd unit, `/etc/hosts` node entries, and the corosync
cluster name. The check is entirely `check_mode` (read-only) and safe to run
against production. It does not modify `main.yml`.
```

- [ ] **Step 2: Lint everything new/changed**

Run:
```bash
cd /home/zencham/_ZENSEC/_NPM/ansible
ansible-lint roles/npm_ha/ drift_check.yml
```
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: document drift_check preflight"
```

---

## Acceptance (full)

1. `ansible-playbook drift_check.yml` → PASS on both nodes ("No drift").
2. `ansible-playbook drift_check.yml -e container_timezone=UTC/Drift` → FAIL, naming `docker-compose.yml` with a printed diff.
3. `ansible-playbook drift_check.yml` again → PASS (no persistence).
4. `ansible-playbook main.yml --syntax-check` → OK (systemd refactor didn't break the role).

## Self-Review Notes

- **Spec coverage:** all 5 managed files → Task 2 tasks (res/compose/unit templates, hosts lineinfile, corosync grep); systemd DRY extraction → Task 1; standalone playbook, main.yml unchanged → Task 3; read-only/check_mode + non-zero exit → Task 2 assert; docs → Task 4; PASS-then-FAIL acceptance → Task 3 Steps 3–5.
- **Placeholder scan:** every step has complete, runnable content; no TBD/TODO; the systemd template content is given in full (not "same as inline").
- **Name consistency:** registers `drift_res`/`drift_compose`/`drift_unit`/`drift_hosts`/`drift_corosync` and fact `drift_check_drifted` are used identically in the `set_fact` and `assert`.
