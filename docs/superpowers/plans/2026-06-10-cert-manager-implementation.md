# cert_manager Role Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `cert_manager` Ansible role that installs acme.sh on the controller, issues/renews wildcard TLS certs for multiple domains via Cloudflare DNS-01, and distributes them to DMZ-isolated NPM nodes via the NPM HTTP API.

**Architecture:** The role runs exclusively on `localhost` (new `[controller]` inventory group) via a dedicated `cert_manager.yml` playbook separate from `main.yml`. acme.sh handles ACME challenges from the controller; Ansible's `uri` module handles all NPM API calls. Per-domain Cloudflare tokens are a vault dict keyed by wildcard domain string.

**Tech Stack:** Ansible ≥ 2.14, acme.sh (shell-installed by role), Let's Encrypt, Cloudflare DNS-01 (`dns_cf` hook), NPM REST API (JWT auth, `form-multipart` cert upload)

---

## File Map

| Path | Action | Purpose |
|---|---|---|
| `inventory/hosts` | Modify | Add `[controller]` group |
| `inventory/group_vars/controller/vars.yml` | Create | Domains, NPM API URL, ACME email |
| `inventory/group_vars/controller/vault.yml` | Create (encrypt) | Per-domain CF tokens + NPM admin password |
| `inventory/group_vars/controller/vault.yml.example` | Create | Plaintext template for new deployments |
| `cert_manager.yml` | Create | Top-level playbook (hosts: controller) |
| `roles/cert_manager/defaults/main.yml` | Create | `acme_sh_dir`, `acme_server`, `cert_renew_days` |
| `roles/cert_manager/vars/main.yml` | Create | Empty (project pattern) |
| `roles/cert_manager/meta/main.yml` | Create | Role metadata |
| `roles/cert_manager/tasks/main.yml` | Create | Orchestrator: install + NPM auth + domain loop |
| `roles/cert_manager/tasks/install.yml` | Create | Idempotent acme.sh install |
| `roles/cert_manager/tasks/issue.yml` | Create | Issue or renew cert per domain |
| `roles/cert_manager/tasks/upload.yml` | Create | Push cert to NPM API |
| `README.md` | Modify | Add cert_manager section |

---

## Task 1: Inventory and controller group_vars

**Files:**
- Modify: `inventory/hosts`
- Create: `inventory/group_vars/controller/vars.yml`
- Create: `inventory/group_vars/controller/vault.yml.example`
- Create: `inventory/group_vars/controller/vault.yml`

Ansible auto-loads `group_vars/controller/` for all hosts in the `[controller]` group. `ansible_connection=local` makes Ansible run tasks directly on the controller without SSH.

- [ ] **Step 1: Add [controller] group to inventory/hosts**

Replace the full content of `inventory/hosts` with:

```ini
[ha_nodes]
MIBTECH-NPM-PROD-01 ansible_host=192.168.206.33
MIBTECH-NPM-PROD-02 ansible_host=192.168.206.40

[controller]
localhost ansible_connection=local
```

- [ ] **Step 2: Create inventory/group_vars/controller/vars.yml**

```yaml
---
npm_api_base_url: "http://192.168.206.220:15625"
npm_admin_email: "admin@mibtech.ma"
acme_email: "admin@mibtech.ma"

cert_domains:
  - "*.mibtech.ma"
  - "*.visionhis.ma"
  - "*.myakdital.ma"

cert_renew_days: 30
```

`npm_api_base_url` is standalone (not derived from `ha_nodes` vars) so cert_manager works independently of the HA role.

- [ ] **Step 3: Create inventory/group_vars/controller/vault.yml.example**

```yaml
# inventory/group_vars/controller/vault.yml.example
# Copy to inventory/group_vars/controller/vault.yml, fill in real values, then:
#   ansible-vault encrypt inventory/group_vars/controller/vault.yml --encrypt-vault-id default
---
cloudflare_tokens:
  "*.mibtech.ma": "CHANGE_ME"
  "*.visionhis.ma": "CHANGE_ME"
  "*.myakdital.ma": "CHANGE_ME"

npm_admin_password: "CHANGE_ME"
```

- [ ] **Step 4: Create inventory/group_vars/controller/vault.yml (plaintext placeholder)**

```yaml
---
cloudflare_tokens:
  "*.mibtech.ma": "CHANGE_ME"
  "*.visionhis.ma": "CHANGE_ME"
  "*.myakdital.ma": "CHANGE_ME"

npm_admin_password: "CHANGE_ME"
```

- [ ] **Step 5: Encrypt vault.yml**

```bash
ansible-vault encrypt inventory/group_vars/controller/vault.yml --encrypt-vault-id default
```

Expected: `Encryption successful`

- [ ] **Step 6: Verify vault.yml is encrypted**

```bash
head -1 inventory/group_vars/controller/vault.yml
```

Expected: `$ANSIBLE_VAULT;1.1;AES256`

- [ ] **Step 7: Commit**

```bash
git add inventory/hosts inventory/group_vars/controller/
git commit -m "feat: add controller inventory group and group_vars scaffold"
```

---

## Task 2: Role scaffold

**Files:**
- Create: `roles/cert_manager/defaults/main.yml`
- Create: `roles/cert_manager/vars/main.yml`
- Create: `roles/cert_manager/meta/main.yml`
- Create: `roles/cert_manager/tasks/main.yml` (stub)
- Create: `roles/cert_manager/tasks/install.yml` (stub)
- Create: `roles/cert_manager/tasks/issue.yml` (stub)
- Create: `roles/cert_manager/tasks/upload.yml` (stub)

All task files are created as stubs (`---` only) so `--syntax-check` passes incrementally as each is filled in. The project pattern: `vars/main.yml` stays empty; role-level defaults go in `defaults/main.yml`.

- [ ] **Step 1: Create roles/cert_manager/defaults/main.yml**

```yaml
---
acme_sh_dir: "/root/.acme.sh"
acme_server: "letsencrypt"
cert_renew_days: 30
```

- [ ] **Step 2: Create roles/cert_manager/vars/main.yml**

```yaml
---
```

- [ ] **Step 3: Create roles/cert_manager/meta/main.yml**

```yaml
---
galaxy_info:
  author: MIBTECH
  description: Wildcard cert lifecycle via acme.sh + Cloudflare DNS-01 to NPM API
  license: MIT
  min_ansible_version: "2.14"
dependencies: []
```

- [ ] **Step 4: Create stub task files**

Create each of the following files with only `---` as content:

- `roles/cert_manager/tasks/main.yml`
- `roles/cert_manager/tasks/install.yml`
- `roles/cert_manager/tasks/issue.yml`
- `roles/cert_manager/tasks/upload.yml`

Each file:
```yaml
---
```

- [ ] **Step 5: Commit**

```bash
git add roles/cert_manager/
git commit -m "feat: scaffold cert_manager role structure"
```

---

## Task 3: cert_manager.yml playbook and tasks/main.yml

**Files:**
- Create: `cert_manager.yml`
- Modify: `roles/cert_manager/tasks/main.yml`

`cert_manager.yml` targets `hosts: controller` only — running it never touches ha_nodes. `tasks/main.yml` is the orchestrator: install acme.sh once (static `import_tasks`), get NPM JWT once (reused for all domains), then loop `cert_domains` calling `issue.yml` per domain. `include_tasks` is required for the domain loop — `import_tasks` cannot be used inside a loop.

- [ ] **Step 1: Create cert_manager.yml**

```yaml
---
- name: Manage wildcard TLS certificates
  hosts: controller
  gather_facts: false
  roles:
    - role: cert_manager
```

- [ ] **Step 2: Write roles/cert_manager/tasks/main.yml**

```yaml
---
- name: Install acme.sh on controller
  import_tasks: install.yml

- name: Authenticate to NPM API
  uri:
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
  set_fact:
    npm_token: "{{ npm_auth.json.token }}"
  no_log: true

- name: Issue and upload cert per domain
  include_tasks: issue.yml
  loop: "{{ cert_domains }}"
  loop_control:
    loop_var: cert_domain
    label: "{{ cert_domain }}"
```

- [ ] **Step 3: Run syntax-check**

```bash
ansible-playbook cert_manager.yml --syntax-check
```

Expected: `playbook: cert_manager.yml` (no errors)

- [ ] **Step 4: Commit**

```bash
git add cert_manager.yml roles/cert_manager/tasks/main.yml
git commit -m "feat: add cert_manager playbook and orchestrator task"
```

---

## Task 4: tasks/install.yml — acme.sh installation

**Files:**
- Modify: `roles/cert_manager/tasks/install.yml`

acme.sh is downloaded from `https://get.acme.sh` and installed via its own install script. `--no-cron` prevents acme.sh from registering a cron job (the operator handles scheduling). The `stat` check makes the install idempotent. `risky-shell-pipe` is already in the project's ansible-lint skip_list (`.ansible-lint`), so the curl-pipe pattern is acceptable.

- [ ] **Step 1: Write roles/cert_manager/tasks/install.yml**

```yaml
---
- name: Check if acme.sh is already installed
  stat:
    path: "{{ acme_sh_dir }}/acme.sh"
  register: acme_sh_stat

- name: Download and install acme.sh
  shell: >
    curl -sSL https://get.acme.sh |
    sh -s --
    --install-online
    --home {{ acme_sh_dir }}
    --accountemail {{ acme_email }}
    --no-cron
  args:
    creates: "{{ acme_sh_dir }}/acme.sh"
  when: not acme_sh_stat.stat.exists

- name: Set default ACME CA
  command: "{{ acme_sh_dir }}/acme.sh --set-default-ca --server {{ acme_server }}"
  when: not acme_sh_stat.stat.exists
  changed_when: true
```

- [ ] **Step 2: Run syntax-check**

```bash
ansible-playbook cert_manager.yml --syntax-check
```

Expected: `playbook: cert_manager.yml` (no errors)

- [ ] **Step 3: Commit**

```bash
git add roles/cert_manager/tasks/install.yml
git commit -m "feat: add idempotent acme.sh install task"
```

---

## Task 5: tasks/issue.yml — issue and renew certs

**Files:**
- Modify: `roles/cert_manager/tasks/issue.yml`

Two code paths based on whether a cert file exists on disk:
- **First run** (no cert): `acme.sh --issue` with `-d "*.domain.ma" -d "domain.ma"` (apex SAN included so the cert covers both wildcard subdomains and the root domain). Sets `cert_renewed=true`.
- **Subsequent runs** (cert exists): `acme.sh --renew --days N`. rc=0 → renewed → `cert_renewed=true`. rc=2 → not due → `cert_renewed=false` → upload skipped.

`cert_domain` is the loop_var from `main.yml` (e.g. `"*.mibtech.ma"`). `_domain_base` strips `*.` to get `"mibtech.ma"`. On Linux, `*` is a valid directory name character — acme.sh stores files at `~/.acme.sh/*.mibtech.ma/` literally. Ansible's `stat` and `slurp` modules use literal paths with no glob expansion.

- [ ] **Step 1: Write roles/cert_manager/tasks/issue.yml**

```yaml
---
- name: "Set domain facts for {{ cert_domain }}"
  set_fact:
    _domain_base: "{{ cert_domain | regex_replace('^\\*\\.', '') }}"
    _cert_fullchain: "{{ acme_sh_dir }}/{{ cert_domain }}/fullchain.cer"
    _cert_key: "{{ acme_sh_dir }}/{{ cert_domain }}/{{ cert_domain }}.key"

- name: "Check if cert already exists for {{ cert_domain }}"
  stat:
    path: "{{ _cert_fullchain }}"
  register: cert_file_stat

- name: "Issue cert for {{ cert_domain }} (first run)"
  shell: >
    {{ acme_sh_dir }}/acme.sh --issue
    -d "{{ cert_domain }}"
    -d "{{ _domain_base }}"
    --dns dns_cf
    --server {{ acme_server }}
    --home {{ acme_sh_dir }}
  environment:
    CF_Token: "{{ cloudflare_tokens[cert_domain] }}"
  when: not cert_file_stat.stat.exists
  register: acme_issue
  changed_when: acme_issue.rc == 0

- name: "Renew cert for {{ cert_domain }} (subsequent runs)"
  shell: >
    {{ acme_sh_dir }}/acme.sh --renew
    -d "{{ cert_domain }}"
    --days {{ cert_renew_days }}
    --home {{ acme_sh_dir }}
  environment:
    CF_Token: "{{ cloudflare_tokens[cert_domain] }}"
  when: cert_file_stat.stat.exists
  register: acme_renew
  failed_when: acme_renew.rc not in [0, 2]
  changed_when: acme_renew.rc == 0

- name: "Set cert_renewed fact for {{ cert_domain }}"
  set_fact:
    cert_renewed: >-
      {{ (not cert_file_stat.stat.exists and acme_issue.rc | default(-1) == 0)
         or (cert_file_stat.stat.exists and acme_renew.rc | default(-1) == 0) }}

- name: "Upload cert to NPM for {{ cert_domain }}"
  include_tasks: upload.yml
  when: cert_renewed | bool
```

- [ ] **Step 2: Run syntax-check**

```bash
ansible-playbook cert_manager.yml --syntax-check
```

Expected: `playbook: cert_manager.yml` (no errors)

- [ ] **Step 3: Commit**

```bash
git add roles/cert_manager/tasks/issue.yml
git commit -m "feat: add cert issue/renew task with first-run and renewal split"
```

---

## Task 6: tasks/upload.yml — push cert to NPM API

**Files:**
- Modify: `roles/cert_manager/tasks/upload.yml`

NPM custom cert flow: read cert files from disk (slurp → b64decode) → list existing certs → search by `nice_name` == `cert_domain` → create entry if missing → upload cert+key as `form-multipart`. `npm_token` was set as a fact in `main.yml` before the loop. `_cert_fullchain` and `_cert_key` were set as facts in `issue.yml` before this file is included. `no_log: true` on any task that handles cert or key content.

The `'id' not in _existing_cert` check is used (safer than `is not defined` when defaulting to `{}`).

- [ ] **Step 1: Write roles/cert_manager/tasks/upload.yml**

```yaml
---
- name: "Read fullchain cert for {{ cert_domain }}"
  slurp:
    src: "{{ _cert_fullchain }}"
  register: cert_pem_b64
  no_log: true

- name: "Read private key for {{ cert_domain }}"
  slurp:
    src: "{{ _cert_key }}"
  register: key_pem_b64
  no_log: true

- name: "Set cert content facts for {{ cert_domain }}"
  set_fact:
    _cert_pem: "{{ cert_pem_b64.content | b64decode }}"
    _key_pem: "{{ key_pem_b64.content | b64decode }}"
  no_log: true

- name: "List existing NPM certificates"
  uri:
    url: "{{ npm_api_base_url }}/api/nginx/certificates"
    method: GET
    headers:
      Authorization: "Bearer {{ npm_token }}"
    status_code: 200
  register: npm_certs_list

- name: "Find existing cert entry for {{ cert_domain }}"
  set_fact:
    _existing_cert: >-
      {{ npm_certs_list.json
         | selectattr('nice_name', 'equalto', cert_domain)
         | list | first | default({}) }}

- name: "Create new NPM cert entry for {{ cert_domain }}"
  uri:
    url: "{{ npm_api_base_url }}/api/nginx/certificates"
    method: POST
    headers:
      Authorization: "Bearer {{ npm_token }}"
    body_format: json
    body:
      provider: "other"
      nice_name: "{{ cert_domain }}"
    status_code: [200, 201]
  register: npm_cert_create
  when: "'id' not in _existing_cert"

- name: "Set cert ID fact for {{ cert_domain }}"
  set_fact:
    _cert_id: "{{ _existing_cert.id if 'id' in _existing_cert else npm_cert_create.json.id }}"

- name: "Upload cert files to NPM for {{ cert_domain }}"
  uri:
    url: "{{ npm_api_base_url }}/api/nginx/certificates/{{ _cert_id }}/upload"
    method: POST
    headers:
      Authorization: "Bearer {{ npm_token }}"
    body_format: form-multipart
    body:
      certificate:
        content: "{{ _cert_pem }}"
        filename: "cert.pem"
        mime_type: "application/x-pem-file"
      certificate_key:
        content: "{{ _key_pem }}"
        filename: "key.pem"
        mime_type: "application/x-pem-file"
    status_code: [200, 201]
  no_log: true
```

- [ ] **Step 2: Run syntax-check**

```bash
ansible-playbook cert_manager.yml --syntax-check
```

Expected: `playbook: cert_manager.yml` (no errors)

- [ ] **Step 3: Run ansible-lint on the full role**

```bash
ansible-lint roles/cert_manager
```

Expected: 0 findings (skipped rules from `.ansible-lint` don't count as findings)

- [ ] **Step 4: Commit**

```bash
git add roles/cert_manager/tasks/upload.yml
git commit -m "feat: add NPM API cert upload task with search and create-or-update"
```

---

## Task 7: README update

**Files:**
- Modify: `README.md`

Insert the `cert_manager` section before the existing `## Future Considerations` section (line 147).

- [ ] **Step 1: Insert cert_manager section into README.md**

Open `README.md`. Insert the following block immediately before the `## Future Considerations` heading:

````markdown
## Certificate Management (cert_manager)

Wildcard TLS certificates are issued on the controller via [acme.sh](https://github.com/acmesh-official/acme.sh) + Cloudflare DNS-01 and pushed to NPM nodes via the NPM HTTP API. NPM nodes have no outbound internet access — all ACME traffic originates from the controller.

### Prerequisites

- Cloudflare API token per domain (DNS:Edit permission on that specific zone)
- NPM admin UI password

### Setup

1. Copy and populate the controller vault:

```bash
cp inventory/group_vars/controller/vault.yml.example /tmp/ctrl_vault.yml
# Edit /tmp/ctrl_vault.yml: fill in each cloudflare_tokens entry and npm_admin_password
ansible-vault decrypt inventory/group_vars/controller/vault.yml
cp /tmp/ctrl_vault.yml inventory/group_vars/controller/vault.yml
ansible-vault encrypt inventory/group_vars/controller/vault.yml --encrypt-vault-id default
rm /tmp/ctrl_vault.yml
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

````

- [ ] **Step 2: Run final checks**

```bash
ansible-playbook cert_manager.yml --syntax-check
ansible-lint roles/cert_manager
```

Expected: no errors, 0 lint findings.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: add cert_manager setup and usage to README"
```
