# npmctl Polish Design

## Goal

Make `npmctl` genuinely polished: replace the raw, noisy `status` output with a
parsed cluster-health panel (✓/✗ per check), add a spinner + ✓/✗ result line for
long playbook runs, group the menu with short descriptions, and unify all boxed
rendering through one primitive. Also close gaps left from the first build: the
designed `ui_status_panel` and `run_step` were never implemented, and `status`
dumped misleading `CHANGED | rc=0` ansible output with no health verdict.

## Context

`npmctl` is a self-contained bash CLI (zero deps) at the repo root, already on
`master`. Today `cmd_status` runs three `ansible … -m shell` probes and prints
their raw stdout, which shows `MIBTECH-NPM-PROD-01 | CHANGED | rc=0 >>` noise and
duplicated per-node blocks. Colors honor `NO_COLOR`/non-TTY. Tests live in
`tests/test_npmctl.sh` (dry-run harness) and `tests/test_npmctl_menu.py` (pty).

Real probe output to parse (verified live):
- DRBD (`grep -E "^ *[0-9]+:" /proc/drbd`):
  `10: cs:Connected ro:Primary/Secondary ds:UpToDate/UpToDate C r-----`
  (minor 10 = app, 11 = db).
- Pacemaker (`pcs status --full | grep -E "npm_service|npm_vip|Failed Resource"`):
  `* npm_vip (ocf:heartbeat:IPaddr2): Started MIBTECH-NPM-PROD-01`
- VIP: `curl -s -o /dev/null -w '%{http_code}'`.

## Architecture

All changes stay in the single `npmctl` file plus the two test files.

### 1. Boxed rendering primitive — `ui_box`

`ui_box <title> <line>...` draws a rounded box (`╭─ title ─╮` / `│ … │` /
`╰──╯`) sized to the widest line, color via `$C_CYN`. Under `NO_COLOR`/non-TTY it
still draws (box chars are plain Unicode); a `NPMCTL_ASCII=1` escape hatch swaps to
`+--+`/`|` for terminals without UTF-8. The existing `ui_banner` is reimplemented as
a one-line `ui_box` call (DRY).

### 2. Health panel — `cmd_status` + pure parsers

`cmd_status` gathers the three probe outputs (with `changed_when: false` so no
`CHANGED` noise; capture with `2>/dev/null`), passes each to a **pure parser**, and
renders the result inside `ui_box "Cluster Health"`.

Pure, offline-testable parsers (text in → status rows out, no I/O):

- `_parse_drbd <text>` → for minors 10/11 emits `app`/`db` with `ok` iff the line
  contains `cs:Connected` and `ds:UpToDate/UpToDate`, else `bad` + the raw state.
  Output lines: `ok|bad<TAB>label<TAB>detail`.
- `_parse_pcs <text>` → for `npm_vip` and `npm_service` emits `ok` iff `Started`,
  else `bad`; emits a `bad` row if `Failed Resource Actions` (i.e. the literal
  `Failed` marker) appears.

`cmd_status` itself:
- VIP: `ok` iff curl prints `200`; row `HTTP <code>`.
- Renders each row as `  ✓ label detail` (green) or `  ✗ label detail` (red), under
  `DRBD` / `Pacemaker` / `VIP …:<port>` group headings.
- Footer: counts bad rows → prints `✓ healthy` (green) or `✗ N issue(s)` (red).
- **Returns non-zero when any row is bad** (scriptable / monitorable).

### 3. Step runner — `run_step`

`run_step <label> <cmd…>`:
- Dry-run → prints `would-run: <cmd>` (preserves existing test contract) and returns 0.
- Non-TTY → prints `• <label>` then runs, then `✓/✗ <label>` (no spinner).
- TTY → braille spinner (`⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏`) on `/dev/tty` while the command runs in the
  background; on completion clears the line and prints `✓ <label> (<secs>s)` green or
  `✗ <label> (rc <n>)` red, and on failure echoes the last ~15 captured lines.
- Returns the command's exit code.

`cmd_deploy`'s five steps and the wrapper commands (`drift`/`backup`/`verify`/
`restore`/`update`/`cert`) route their `ansible-playbook` call through `run_step`.
**The deploy gate semantics are unchanged** (drift abort, `--force`, `--yes`).

### 4. Menu polish — grouped with descriptions

`interactive_menu` items become grouped with dim section dividers and a short
description each:
```
Operate
  deploy      safe converge (drift-gate → backup → verify)
  drift       check repo vs live config
Inspect
  status      cluster / DRBD / VIP health
  logs        tail NPM container logs
Maintain
  backup / verify / restore  proxy-host snapshot ops
  update / cert / vault-edit  images / TLS / secrets
  quit
```
`ui_menu` gains support for non-selectable divider rows (skipped during arrow
navigation) and a parallel description array drawn dimmed to the right. The
returned value is still the bare command key (so `dispatch` is unchanged), keeping
the pty regression test valid.

## Data flow

`cmd_status` → 3 probes → `_parse_drbd`/`_parse_pcs` + curl check → rows → `ui_box`.
`run_step` → background command, spinner, result. Parsers are pure (string →
string), enabling fixture-based unit tests with zero production contact.

## Error handling

- `set -euo pipefail` retained. Probe capture uses `|| true` so an unreachable node
  yields `✗` rows, not a crash.
- `run_step` always restores the cursor (existing `_restore_term` trap covers
  Ctrl-C); spinner output goes to `/dev/tty` so it never pollutes captured stdout.
- `cmd_status` non-zero exit on unhealthy is intentional and documented.

## Testing

`tests/test_npmctl.sh` (dry-run) gains:
- `_parse_drbd` healthy fixture → two `ok` rows; degraded fixture (`Connected` but
  `Inconsistent`, and a `StandAlone`) → `bad` rows.
- `_parse_pcs` fixture: both Started → `ok`; a `Stopped` and a `Failed Resource
  Actions` fixture → `bad`.
- `run_step` under dry-run → prints `would-run:`.
- `ui_box`/panel under `NO_COLOR` → zero ESC bytes.
- Existing wrapper/deploy/guard tests still pass (deploy still prints the five
  steps; `would-run:` contract preserved via `run_step` dry-run branch).

`tests/test_npmctl_menu.py` (pty) updated: still selects an item and asserts clean
dispatch; updated for divider rows (selecting `status` returns `status`).

Live acceptance (read-only): `./npmctl status` shows the parsed panel and exits 0
when healthy.

## Out of scope

- Any change to the playbooks or deploy safety logic (purely presentational +
  the new non-zero status exit).
- External TUI libraries (still pure bash, zero deps).
- Watch/refresh mode for status (YAGNI for now).
