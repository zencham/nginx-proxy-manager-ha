# proxy_guard Role Design

## Goal

Add a `proxy_guard` Ansible role (plus two thin playbooks) that lets us re-run the
`npm_ha` playbook against the **already-deployed, live** MIBTECH cluster to prove the
playbook is fully functional and idempotent — **without losing the reverse-proxy
definitions and without disrupting live traffic**. The safety net is an export of the
NPM reverse-proxy configuration from the NPM HTTP API into a dedicated snapshot file,
plus a verification step that asserts nothing was lost, and a manually-triggered restore
path that re-imports from the snapshot if needed.

## Context

The cluster is already deployed and serving production traffic on
`MIBTECH-NPM-PROD-01` (192.168.206.33) and `MIBTECH-NPM-PROD-02` (192.168.206.40),
VIP `192.168.206.220`, NPM admin API on port `15625`.

A re-run of `main.yml` against the live cluster was traced and is **mostly idempotent**:

- **DRBD init is gated** — `drbd.yml` skips `create-md`, `drbdadm primary --force`, and
  the ext4 `mkfs` steps via `when: drbd_init.changed`, because DRBD metadata already
  exists. `filesystem: force: false` is an additional guard. The replicated data on
  `/mnt/npm_app` and `/mnt/npm_db` is never touched.
- **Cluster setup is gated** — `cluster.yml` skips `pcs cluster setup --force` and the
  whole auth/start/property block because the cluster name is already in
  `/etc/corosync/corosync.conf`.
- **Resource creation is gated** — `resources.yml` skips all `pcs resource create` steps
  because `npm_group` already exists.

The only unconditional mutations on a re-run are: re-rendering `docker-compose.yml`,
the DRBD `.res` file and the systemd unit (only matters under config drift), a
`pcs resource update` of op timeouts (same values), `pcs resource cleanup` (harmless),
and a hacluster password re-hash (same password). None of these write NPM application
data.

The reverse-proxy definitions themselves live **inside the NPM app data** on the
DRBD-backed mounts and are managed via the NPM REST API, not by the playbook. The
playbook cannot lose them on a re-run unless DRBD reformats — which is gated off. The
snapshot is therefore a belt-and-suspenders safety net, not a routine necessity.

The NPM API auth pattern is already established in `cert_manager`:
`POST {{ npm_api_base_url }}/api/tokens` with `{identity, secret}` → `.token`, then
`Authorization: Bearer {{ npm_token }}`. The `GET /api/nginx/proxy-hosts` list shape and
the `id, created_on, modified_on, owner_user_id`-stripping write pattern are already
proven in `cert_manager/tasks/sync_proxy_hosts.yml`.

---

## Architecture

```
proxy_backup.yml          — new playbook, hosts: controller (connection: local)
proxy_verify.yml          — new playbook, hosts: controller (connection: local)
main.yml                  — unchanged

roles/
  proxy_guard/
    defaults/main.yml     — backup_dir, snapshot scope toggles, sample verify domain
    vars/main.yml         — empty (project pattern)
    meta/main.yml
    tasks/
      main.yml            — auth to NPM API once, then dispatch by tag
      auth.yml            — POST /api/tokens -> npm_token (no_log)
      backup.yml          — GET all resource types -> write timestamped JSON + latest
      verify.yml          — GET proxy-hosts, assert snapshot domains/ids all present
      restore.yml         — re-POST missing proxy hosts from npm-latest.json (tag: restore)

backups/                  — gitignored; holds live snapshots (data, not source)
  npm-YYYYMMDD-HHMMSS.json
  npm-latest.json
```

Both playbooks run on `hosts: controller` and reuse the shared `ansible.cfg` and
`.vault_pass`. `main.yml` (ha_nodes) is untouched.

---

## Variables

### `roles/proxy_guard/defaults/main.yml`

```yaml
# Where snapshots are written on the controller (relative to playbook dir).
proxy_guard_backup_dir: "{{ playbook_dir }}/backups"

# Resource types to capture in the snapshot.
proxy_guard_capture:
  - proxy-hosts
  - redirection-hosts
  - dead-hosts
  - streams
  - access-lists
  - certificates

# Optional end-to-end check: a domain expected to return 2xx/3xx through the VIP.
# Empty string disables the live-HTTP check.
proxy_guard_sample_domain: ""
```

NPM API URL and admin credentials are reused from the existing `controller` group_vars
(`npm_api_base_url`, `npm_admin_email`) and vault (`npm_admin_password`). No new secrets.

---

## Data flow

### Backup (`proxy_backup.yml`)

1. `auth.yml` — `POST /api/tokens` → `npm_token` (`no_log: true`).
2. For each type in `proxy_guard_capture`: `GET /api/nginx/<type>` (certificates is
   `GET /api/nginx/certificates`). Register each response.
3. Assemble a single JSON document:
   ```json
   {
     "captured_at": "2026-06-16T12:00:00Z",
     "npm_api_base_url": "http://192.168.206.220:15625",
     "proxy-hosts": [ ... ],
     "redirection-hosts": [ ... ],
     "dead-hosts": [ ... ],
     "streams": [ ... ],
     "access-lists": [ ... ],
     "certificates": [ ... ]
   }
   ```
4. Write to `backups/npm-<timestamp>.json` (mode `0600`) and copy to
   `backups/npm-latest.json`.
5. Print a summary: counts per type and the snapshot path.

### Verify (`proxy_verify.yml`)

1. `auth.yml` → token.
2. `GET /api/nginx/proxy-hosts` (current live state).
3. Load `backups/npm-latest.json`.
4. Assert: every proxy-host `id` and every `domain_names` entry in the snapshot is
   present in the live list, and each matched host is `enabled`. Build an explicit
   `missing` list for the failure message.
5. If `missing` is non-empty → **fail loudly** with the list and the exact restore
   command. No writes (manual-confirm mode).
6. If `proxy_guard_sample_domain` is set → `GET` it through the VIP and assert 2xx/3xx.

### Restore (`proxy_verify.yml --tags restore`, manual)

1. `auth.yml` → token.
2. Load `backups/npm-latest.json`, recompute `missing` against live proxy-hosts.
3. For each missing host: `POST /api/nginx/proxy-hosts` with the snapshot object,
   stripping `id, created_on, modified_on, owner_user_id` (matching the existing
   `sync_proxy_hosts.yml` pattern). `certificate_id` is preserved as-is.
4. Re-verify and report restored count.

---

## Run procedure

```
1. ansible-playbook proxy_backup.yml          # snapshot proxies -> backups/
2. ansible-playbook main.yml                  # re-converge (gated steps skip)
3. ansible-playbook proxy_verify.yml          # assert nothing lost (+ optional HTTP check)
   # only if step 3 fails:
4. ansible-playbook proxy_verify.yml --tags restore
```

---

## Error handling

- **Auth failure** — `auth.yml` fails fast; backup never writes a partial/empty
  snapshot. Verify/restore abort before touching live state.
- **Empty snapshot guard** — `backup.yml` asserts the proxy-hosts list is non-empty
  before overwriting `npm-latest.json`, so a transient API hiccup can't clobber a good
  snapshot with zero hosts.
- **Verify is read-only** — never mutates live NPM. Restore is the only writer and is
  manually triggered via `--tags restore`.
- **Restore is additive** — only re-POSTs hosts that are *missing*; it does not modify or
  delete existing live hosts.

---

## Testing

- Molecule/unit testing is out of scope (controller-only API role; the existing
  `npm_ha` role has the molecule scaffold, `cert_manager` does not — match
  `cert_manager`).
- Manual validation against the live cluster is the acceptance test, in this order:
  1. `proxy_backup.yml` → confirm `backups/npm-latest.json` has the expected host count.
  2. `proxy_verify.yml` immediately → must pass (snapshot == live).
  3. `main.yml` re-run → confirm gated steps report `skipping`.
  4. `proxy_verify.yml` again → must still pass (proxies survived the re-run).

---

## Out of scope

- Restoring redirection-hosts, dead-hosts, streams, access-lists, or certificates — these
  are captured for reference/manual recovery but the automated restore path covers
  proxy-hosts only (the stated priority: "guard the reverse proxies").
- Any change to `main.yml` or the `npm_ha` role behavior.
- Scheduling/automation of backups (this is an on-demand safety net for the re-run test).
