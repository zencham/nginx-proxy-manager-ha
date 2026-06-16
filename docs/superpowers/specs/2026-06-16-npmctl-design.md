# npmctl — Management CLI Design

## Goal

A single self-contained bash script, `npmctl`, at the repo root that lets an
operator manage the NPM HA cluster through friendly subcommands and a beautiful
interactive terminal UI, instead of invoking `ansible-playbook`/`ansible`
directly. It bakes in the safety sequence learned from the 2026-06-16 outage:
`deploy` refuses to converge on config drift and always snapshots the proxy hosts
first.

## Context

The project exposes these playbooks (run today by hand): `main.yml`,
`drift_check.yml`, `proxy_backup.yml`, `proxy_verify.yml`, `proxy_restore.yml`,
`npm_update.yml`, `cert_manager.yml`. Live inspection (cluster/DRBD/VIP health,
container logs) currently needs manual `ansible`/`ssh` ad-hoc commands. `npmctl`
wraps all of this. It holds no state; it shells out using the repo's `ansible.cfg`
(inventory, `roles_path`, `vault_password_file = .vault_pass`).

Zero new runtime dependencies: pure bash + ANSI. `bash` and `ansible` are the only
requirements (ansible already required by the project). `shellcheck` is used in dev
only.

## Architecture

```
npmctl                    — CREATE: executable bash script (the whole tool)
tests/test_npmctl.sh      — CREATE: dependency-free test harness (uses dry-run)
README.md                 — MODIFY: document ./npmctl
```

Single file, organized in sections: config/colors → ui helpers → command functions
→ dispatch/menu → main. A single self-contained file is chosen over a lib split so
the tool is trivially portable (one file).

### Two entry modes (share the same command functions — DRY)

- `./npmctl` with **no args** → interactive TUI menu loop.
- `./npmctl <command> [flags]` → runs that command directly (scriptable).

Both paths call the same `cmd_*` bash functions; the menu is just another caller.

### Startup guard

`main()` first `cd`s to the script's own directory (`BASH_SOURCE` dirname) so
`ansible.cfg` is always picked up regardless of the caller's CWD. Then it asserts
`ansible.cfg` exists (correct repo), `ansible`/`ansible-playbook` are on `PATH`,
and warns (non-fatal) if `.vault_pass` is missing.

## Command surface

| Command | Maps to | Read-only? |
|---|---|---|
| `deploy` | safety-gated converge (below) | no |
| `drift` | `drift_check.yml` | yes |
| `backup` | `proxy_backup.yml` | yes (writes local snapshot) |
| `verify` | `proxy_verify.yml` | yes |
| `restore` | `proxy_restore.yml` | **no (writes to NPM)** |
| `update` | `npm_update.yml` | no |
| `cert` | `cert_manager.yml` | no |
| `status` | `pcs status` + `drbdadm status` + VIP HTTP probe, rendered as a panel | yes |
| `logs` | `docker compose logs --tail` on the ha_nodes via ansible | yes |
| `vault-edit [ha_nodes\|controller]` | `ansible-vault edit` the chosen vault | n/a |
| `help` | usage | yes |

## `deploy` safety sequence

1. `drift_check.yml` — if it exits non-zero (drift) → **abort** with the diff,
   unless `--force` was passed.
2. `proxy_backup.yml` — snapshot proxy hosts to `backups/`.
3. **Confirm prompt** ("About to converge production. Continue?") — skipped only
   with `--yes`.
4. `main.yml` — converge.
5. `proxy_verify.yml` — confirm the proxy hosts survived.

Any step's non-zero exit stops the chain and reports which step failed.

**Flag semantics (explicit):**
- `--force` — bypass *only* the drift abort in step 1. Steps 2–5 still run; the
  confirm prompt still applies.
- `--yes` — skip *only* the interactive confirm in step 3 (for automation).
  Independent of `--force`.

## UI (pure bash + ANSI)

- `ui_menu` — renders a list with a highlighted current row; navigation by ↑/↓ +
  Enter (read via `read -rsn`), with number-key shortcuts as an alternative.
  Returns the chosen item's key.
- `ui_banner` — colored title bar (`╭─ NPM HA ─ MIBTECH ─╮` style).
- `ui_status_panel` — boxed health summary with ✓/✗ icons (drbd UpToDate, pacemaker
  no-failed-actions, VIP HTTP code), shown atop the menu.
- `ui_confirm` — yes/no prompt for destructive actions.
- `run_step` — runs a labelled command with a spinner; prints ✓/✗ and elapsed time.
- A `trap '... ' EXIT INT` restores cursor visibility and resets colors on exit or
  Ctrl-C.

### Color / TTY handling (gap closures)

- If stdout is **not a TTY** or `NO_COLOR` is set → disable all ANSI (plain text).
- If **stdin/stdout are not both a TTY** → the interactive menu cannot run; `./npmctl`
  with no args prints `help` and exits non-zero instead of launching the TUI. (So
  piping/CI never hangs on a menu.)

## Data flow

`npmctl` → `ansible-playbook <playbook>` / `ansible ha_nodes -m …` with the repo
`ansible.cfg`. `status` parses three signals: `drbdadm status` (count of
`UpToDate`), `pcs status --full` (`Failed Resource Actions` present?), and
`curl -s -o /dev/null -w %{http_code}` to the VIP admin port. The VIP/admin port
come from `inventory/group_vars/ha_nodes/vars.yml` (`vip_address`, `npm_admin_port`)
read via a small `ansible -m debug`/lookup or parsed from the vars file; the spec
uses a parsed value with the documented defaults (`192.168.206.220`, `15625`).

## Error handling

- `set -euo pipefail` globally.
- Every `cmd_*` returns the underlying exit code; the **menu loop** traps a non-zero
  return, shows the error, and returns to the menu (does not crash the session).
- Direct mode propagates the exit code to the shell (so `deploy` failing is
  scriptable / CI-detectable).
- `EXIT`/`INT` trap always restores the terminal.

## Testing

A dependency-free harness `tests/test_npmctl.sh` (plain bash, no bats) using
**`NPMCTL_DRY_RUN=1`** — in which every `cmd_*` and the status panel print
`would-run: <command>` instead of executing, so nothing touches ansible or
production. It asserts:

1. Unknown command → non-zero exit + usage shown.
2. `help` → lists every command.
3. `deploy` (dry-run) → prints the five steps in order: drift, backup, confirm,
   main, verify.
4. `deploy --force` (dry-run) → still prints all steps; marks the drift gate as
   bypassed.
5. `deploy --yes` (dry-run) → no interactive confirm in the sequence.
6. Each wrapper (`drift`/`backup`/`verify`/`restore`/`update`/`cert`) → prints the
   correct `ansible-playbook <file>`.

`shellcheck npmctl` must pass clean (dev check).

Live acceptance (read-only, controller-run): `./npmctl status` shows the real
cluster panel; `./npmctl drift` exits 0 (no drift). The destructive `deploy`/`update`
are NOT auto-run during acceptance.

## Out of scope

- Replacing or modifying the playbooks themselves (npmctl only orchestrates them).
- Remote execution / packaging (it runs from the repo checkout on the controller).
- A non-bash rewrite or external TUI dependency (gum, dialog, python) — explicitly
  rejected to keep zero new deps and clone-readiness.
