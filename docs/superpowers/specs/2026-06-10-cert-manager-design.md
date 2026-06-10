# cert_manager Role Design

## Goal

Add a `cert_manager` Ansible role that runs on the controller, issues and renews wildcard TLS certificates for multiple domains via acme.sh + Cloudflare DNS-01, and distributes them to DMZ-isolated NPM nodes via the NPM HTTP API. The project must remain fully self-contained — a fresh `git clone` followed by vault population is the only required setup.

## Context

NPM nodes live in a DMZ with no outbound internet access. The Ansible controller has internet access and Cloudflare API credentials. NPM exposes a REST API on the VIP (`http://192.168.206.220:15625`). NPM's data volume is DRBD-backed (`/mnt/npm_app/data`) — certs uploaded to the active node are available after any failover with no extra steps.

---

## Architecture

```
cert_manager.yml          — new playbook, hosts: controller
main.yml                  — unchanged (ha_nodes only)

inventory/
  hosts                   — add [controller] group with localhost
  group_vars/
    controller/
      vars.yml            — domains list, NPM API URL, ACME email, renew threshold
      vault.yml           — per-domain CF tokens + NPM admin credentials (encrypted)
      vault.yml.example   — plaintext template for new deployments

roles/
  cert_manager/
    defaults/main.yml     — acme_sh_dir, acme_server, cert_renew_days
    vars/main.yml         — empty (project pattern)
    meta/main.yml
    tasks/
      main.yml            — get NPM token once, loop cert_domains → issue + upload
      install.yml         — idempotent acme.sh install on controller
      issue.yml           — acme.sh renew per domain (Cloudflare DNS-01)
      upload.yml          — push cert to NPM API (search → create-or-update)
```

`cert_manager.yml` runs on `hosts: controller`. The `ha_nodes` playbook (`main.yml`) is untouched. Both playbooks share the same `ansible.cfg` and `.vault_pass`.

---

## Variables

### `inventory/group_vars/controller/vars.yml`

```yaml
npm_api_base_url: "http://192.168.206.220:15625"
npm_admin_email: "admin@mibtech.ma"
acme_email: "admin@mibtech.ma"

cert_domains:
  - "*.mibtech.ma"
  - "*.visionhis.ma"
  - "*.myakdital.ma"

cert_renew_days: 30
```

`npm_api_base_url` is deliberately standalone (not derived from `vip_address` in `ha_nodes` group_vars) so the cert_manager works independently when pointed at any NPM instance.

### `inventory/group_vars/controller/vault.yml` (encrypted)

```yaml
cloudflare_tokens:
  "*.mibtech.ma":   "CF_TOKEN_HERE"
  "*.visionhis.ma": "CF_TOKEN_HERE"
  "*.myakdital.ma": "CF_TOKEN_HERE"

npm_admin_password: "CHANGE_ME"
```

Each domain has its own Cloudflare API token (DNS:Edit on that zone only). `cloudflare_tokens[item]` resolves the correct token during the domain loop.

### `roles/cert_manager/defaults/main.yml`

```yaml
acme_sh_dir: "/root/.acme.sh"
acme_server: "letsencrypt"       # use "letsencrypt_test" for staging
cert_renew_days: 30              # overridable per deployment via controller/vars.yml
```

### `inventory/group_vars/controller/vault.yml.example`

```yaml
# inventory/group_vars/controller/vault.yml.example
# Copy to vault.yml, fill in real values, then:
#   ansible-vault encrypt inventory/group_vars/controller/vault.yml
---
cloudflare_tokens:
  "*.mibtech.ma":   "CHANGE_ME"
  "*.visionhis.ma": "CHANGE_ME"

npm_admin_password: "CHANGE_ME"
```

---

## Cert Lifecycle

### Per-domain flow (looped over `cert_domains`)

```
1. install.yml  — check if acme.sh exists at {{ acme_sh_dir }}/acme.sh
                   if not: download and install via install script (shell, localhost)

2. issue.yml    — check if {{ acme_sh_dir }}/*.domain.ma/fullchain.cer exists
                   if NOT exists (first run):
                     acme.sh --issue -d "*.domain.ma" -d "domain.ma"
                             --dns dns_cf
                     set renewed=true
                   if EXISTS (subsequent runs):
                     acme.sh --renew -d "*.domain.ma" --days {{ cert_renew_days }}
                     env: CF_Token={{ cloudflare_tokens[item] }}
                     rc=0  → cert renewed → set renewed=true
                     rc=2  → cert still valid → set renewed=false (skip upload)

                   Note: both -d "*.domain.ma" and -d "domain.ma" (apex) are passed
                   on issue so the cert covers both wildcard and root domain.

3. upload.yml   — skip if renewed=false
                   otherwise:
                     a. read fullchain.cer and domain.key from acme_sh_dir
                     b. POST /api/tokens → JWT (obtained once, reused for all domains)
                     c. GET  /api/nginx/certificates → search nice_name == item
                        found    → POST /api/nginx/certificates/{id}/upload
                        not found → POST /api/nginx/certificates (create entry)
                                  → POST /api/nginx/certificates/{id}/upload
```

### acme.sh cert paths (per domain, e.g. `*.mibtech.ma`)

```
{{ acme_sh_dir }}/*.mibtech.ma/fullchain.cer   → certificate field (full chain)
{{ acme_sh_dir }}/*.mibtech.ma/*.mibtech.ma.key → certificate_key field
```

### NPM API upload (multipart)

```yaml
uri:
  url: "{{ npm_api_base_url }}/api/nginx/certificates/{{ cert_id }}/upload"
  method: POST
  headers:
    Authorization: "Bearer {{ npm_token }}"
  body_format: form-multipart
  body:
    certificate:
      content: "{{ cert_pem }}"
      filename: "cert.pem"
      mime_type: "application/x-pem-file"
    certificate_key:
      content: "{{ key_pem }}"
      filename: "key.pem"
      mime_type: "application/x-pem-file"
```

Requires Ansible >= 2.10 (`form-multipart` support). Project already enforces >= 2.14 via `preflight.yml`.

---

## Inventory Change

```ini
[ha_nodes]
MIBTECH-NPM-PROD-01 ansible_host=192.168.206.33
MIBTECH-NPM-PROD-02 ansible_host=192.168.206.40

[controller]
localhost ansible_connection=local
```

---

## Scheduling

Manual by default. To automate later, one cron entry on the controller:

```
0 3 * * * cd /path/to/ansible && ansible-playbook cert_manager.yml
```

Nothing in the role needs to change — the `--days` threshold already makes runs idempotent.

---

## Project Autonomy (git-clone contract)

| Requirement | How met |
|---|---|
| acme.sh not pre-assumed | `install.yml` installs it idempotently |
| All secrets documented | `vault.yml.example` covers every key |
| No manual pre-steps | README covers vault creation + one-time run |
| Scheduling optional | Manual playbook, cron-ready by design |
| Failover-safe | Certs on DRBD; upload to VIP reaches active node |

---

## File Summary

| Path | Action |
|---|---|
| `inventory/hosts` | Add `[controller]` group + localhost |
| `inventory/group_vars/controller/vars.yml` | Create — domains, NPM URL, ACME email |
| `inventory/group_vars/controller/vault.yml` | Create — per-domain CF tokens + NPM password (encrypt) |
| `inventory/group_vars/controller/vault.yml.example` | Create — plaintext template |
| `roles/cert_manager/defaults/main.yml` | Create |
| `roles/cert_manager/vars/main.yml` | Create (empty) |
| `roles/cert_manager/meta/main.yml` | Create |
| `roles/cert_manager/tasks/main.yml` | Create |
| `roles/cert_manager/tasks/install.yml` | Create |
| `roles/cert_manager/tasks/issue.yml` | Create |
| `roles/cert_manager/tasks/upload.yml` | Create |
| `cert_manager.yml` | Create — top-level playbook |
| `README.md` | Update — add cert_manager section |
