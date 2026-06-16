# npmctl maintenance / active-passive Design

## Goal

Let an operator see which node is active (master) vs passive, and transfer
mastership to perform maintenance — by adding a **Nodes** section to `npmctl
status` and a **`maintenance`** command that drains a node via pacemaker standby
(and restores it). Safe by construction: it refuses to drain when doing so would
leave the cluster without a healthy, up-to-date peer.

## Context

`npmctl` is a self-contained bash CLI on `master`. The cluster is a 2-node
Pacemaker/Corosync/DRBD setup (no STONITH; DRBD Protocol C guards split-brain).
The **active** node runs `npm_group` (the `npm_vip` IPaddr2 + `npm_service`
systemd resource) and is DRBD **Primary**; the peer is **passive** (Secondary).
`cmd_status` already parses `npm_vip`/`npm_service` `Started <node>` lines via
`_parse_pcs`, so the active node is already derivable.

Verified live facts to parse:
- `pcs status nodes` lists `Online:`, `Standby:`, and `Standby with resource(s)
  running:` groups of full node names (`MIBTECH-NPM-PROD-01/02`).
- `pcs status --full` Node List shows `online`/`standby`/`offline` per node.
- Standby/unstandby: `pcs node standby <full>` / `pcs node unstandby <full>`
  (permanent until cleared — survives reboot, which is what maintenance needs).

Node short labels (`PROD-01`) are display-only; all `pcs` calls use full names.

## Architecture

All changes in the single `npmctl` file + the two test files.

```
npmctl
  _node_short <full>           — CREATE: MIBTECH-NPM-PROD-01 -> PROD-01
  _node_full  <short|full>     — CREATE: resolve user arg to a full cluster node, or fail
  _parse_nodes <nodes-text> <active-full>  — CREATE: pure; emit role rows
  cmd_status                   — MODIFY: add a "Nodes" section
  _maint_precheck <node-full>  — CREATE: assert safe to drain (peer online + DRBD UpToDate)
  cmd_maintenance              — CREATE: standby / unstandby with confirm + run_step
  dispatch / cmd_help / menu   — MODIFY: wire in `maintenance`
tests/test_npmctl.sh           — MODIFY: parser + resolver + precheck + dry-run tests
README.md                      — MODIFY: document maintenance + active/passive
```

### Active/passive/standby detection — pure functions

- `_node_short <full>`: strips the site prefix → `PROD-01`. (Falls back to the
  input if it doesn't match the pattern.)
- `_node_full <arg>`: accepts `PROD-01` or the full name (case-insensitive on the
  suffix); echoes the canonical full name if it is one of the two known cluster
  nodes (`node1_name`/`node2_name` parsed from group_vars, with the known MIBTECH
  values as fallback), else returns non-zero.
- `_parse_nodes <nodes-text> <active-full>`: given `pcs status nodes` output and the
  active node, for each known node emits one row:
  - `ok<TAB>● <short>  ACTIVE` if it equals `<active-full>`,
  - `bad<TAB>⊘ <short>  STANDBY` if it appears under a `Standby` group,
  - `dim<TAB>○ <short>  passive` otherwise (online, not active).
  Output is `state<TAB>text`; `cmd_status` maps `ok`→green, `bad`→red, `dim`→plain.

### Status "Nodes" section

`cmd_status` gathers `pcs status nodes` once more (oneline-safe), determines the
active node from the same `_parse_pcs` rows it already computes, calls
`_parse_nodes`, and renders a `Nodes` group above the footer. A node in standby
counts as a `bad` row (so `status` exit code reflects "not fully redundant").

### `maintenance` command

- `npmctl maintenance <node>` → drain `<node>` (pcs node standby) so resources run
  on the peer; you maintain/reboot it.
- `npmctl maintenance end <node>` → `pcs node unstandby <node>`; then `run_step`
  waits until `drbdadm status` shows the node `UpToDate` again.
- `npmctl maintenance` (no node) → prints current roles (same Nodes panel) and usage.

Flags: `--yes` skips the confirm; `--force` overrides the safety precheck.

Flow for `maintenance <node>`:
1. `_node_full` resolves/validates the arg (else die with usage).
2. `_maint_precheck <full>` unless `--force`:
   - peer node must be `Online` and **not** itself standby/offline,
   - both DRBD resources `UpToDate` on **both** nodes (no draining onto a stale peer).
   Refuse with a specific message naming what failed.
3. If `<node>` is the **active** node, draining moves the VIP (brief blip) →
   `confirm_or_die` naming the impact (skip with `--yes`).
4. `run_step "standby <short>" ansible <node1> -b -m shell -a 'pcs node standby <full>'`
   (delegated to a node that stays up — always send pcs commands to the *peer* if
   draining the active node, else to node1).
5. Poll until resources are `Started` on the peer; print the new active node + a
   reminder: `run 'npmctl maintenance end <node>' when done`.

`maintenance end` is idempotent: unstandby a non-standby node simply reports
"already in service".

## Data flow

`cmd_status` / `cmd_maintenance` → `ansible <node> -b -m shell -a 'pcs …'` →
text → pure parsers (`_parse_nodes`, `_parse_pcs`, `_parse_drbd`) → rows → panel /
decisions. Parsers are I/O-free → fixture-tested offline. `pcs` mutations run via
`run_step`. The deploy/drift/proxy commands are untouched.

## Error handling

- `_node_full` rejects unknown nodes before any cluster contact.
- `_maint_precheck` is the core guard: no drain onto an absent/stale peer
  (the failure class behind the 2026-06-16 outage). `--force` documented as
  "I accept reduced redundancy".
- All `pcs` calls go through `run_step` (✓/✗ + tail on failure); commands are sent
  to a node that will remain up.
- `set -euo pipefail` retained; capture uses `|| true` so an unreachable node yields
  a `bad`/`STANDBY`/`offline` row rather than a crash.
- `maintenance end` and re-running `maintenance` are idempotent.

## Testing

`tests/test_npmctl.sh` (dry-run, offline) gains:
- `_node_short` / `_node_full`: short and full inputs resolve; bogus → non-zero.
- `_parse_nodes`: active→`● ACTIVE`/ok, passive→`○ passive`/dim, a node listed under
  `Standby:`→`⊘ STANDBY`/bad.
- `_maint_precheck`: healthy fixture → ok; degraded fixture (peer standby, or DRBD
  `Inconsistent`) → non-zero with a message.
- `maintenance <node>` dry-run prints `pcs node standby <full>`; `maintenance end
  <node>` prints `pcs node unstandby <full>`; bogus node → non-zero.
- Existing tests stay green; `would-run:` contract preserved via `run_step`.

`tests/test_npmctl_menu.py`: add `maintenance` under the Maintain group; pty test
still asserts clean dispatch.

Live acceptance is **read-only**: `./npmctl status` shows the new Nodes section
(ACTIVE/passive) and `./npmctl maintenance` prints roles. **No real standby/failover
is triggered during this work** — the operator runs it in a planned window.

## Out of scope

- Automatic failback scheduling or timed standby (chosen: permanent until `end`).
- Touching the playbooks, DRBD config, or deploy safety logic.
- STONITH / fencing (out of scope for this cluster by prior decision).
- A live failover during acceptance (read-only only).
