# npmctl maintenance / active-passive Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (chosen: inline; safety-sensitive parsing). Steps use checkbox (`- [ ]`) syntax.

**Goal:** Add active/passive visibility (`status` Nodes section) and a `maintenance` command that drains a node via pacemaker standby, guarded by a precheck that refuses to drain onto an absent/stale peer.

**Architecture:** Pure functions (`_node_short`, `_node_full`, `_parse_nodes`) → offline-tested. `cmd_status` gains a Nodes section. `cmd_maintenance` validates the node, runs `_maint_precheck`, confirms if draining the active node, then `pcs node standby/unstandby` via `run_step`. All changes in `npmctl` + the two test files.

**Tech Stack:** Bash, ANSI, ansible ad-hoc `pcs`, python3 (pty test). Zero new deps.

---

## File Structure

```
npmctl                      — MODIFY: node helpers, _parse_nodes, status Nodes section,
                              _maint_precheck, cmd_maintenance, dispatch/help/menu
tests/test_npmctl.sh        — MODIFY: node-helper + _parse_nodes + precheck + maintenance dry-run tests
tests/test_npmctl_menu.py   — (no change needed; menu still dispatches cleanly)
README.md                   — MODIFY: document maintenance + active/passive
```

Node names from group_vars: `node1_name: MIBTECH-NPM-PROD-01`, `node2_name: MIBTECH-NPM-PROD-02`.

---

### Task 1: Node helpers + `_parse_nodes` (pure, TDD)

**Files:** Modify `npmctl`, `tests/test_npmctl.sh`.

- [ ] **Step 1:** Add failing tests before the final `echo "== done`:
```bash
echo "== Task M1: node helpers =="
out="$(bash -c 'source ./npmctl >/dev/null 2>&1; set +e +o pipefail; _node_short MIBTECH-NPM-PROD-01' 2>/dev/null)"
check "node_short strips prefix" "PROD-01" "$out"
out="$(bash -c 'source ./npmctl >/dev/null 2>&1; set +e +o pipefail; _node_full PROD-02' 2>/dev/null)"
check "node_full from short" "MIBTECH-NPM-PROD-02" "$out"
out="$(bash -c 'source ./npmctl >/dev/null 2>&1; set +e +o pipefail; _node_full MIBTECH-NPM-PROD-01' 2>/dev/null)"
check "node_full from full" "MIBTECH-NPM-PROD-01" "$out"
bash -c 'source ./npmctl >/dev/null 2>&1; set +e +o pipefail; _node_full BOGUS' >/dev/null 2>&1; check_rc "node_full rejects bogus" 1 "$?"
nodes_text="Pacemaker Nodes:
 Online: MIBTECH-NPM-PROD-01 MIBTECH-NPM-PROD-02
 Standby:
 Standby with resource(s) running:
 Offline:"
out="$(bash -c 'source ./npmctl >/dev/null 2>&1; set +e +o pipefail; _parse_nodes "$1" "$2"' _ "$nodes_text" "MIBTECH-NPM-PROD-01" 2>/dev/null)"
check "parse_nodes active row" "ACTIVE" "$out"
check "parse_nodes active is PROD-01" "PROD-01" "$out"
check "parse_nodes passive row" "passive" "$out"
nodes_sb="Pacemaker Nodes:
 Online: MIBTECH-NPM-PROD-01
 Standby: MIBTECH-NPM-PROD-02
 Offline:"
out="$(bash -c 'source ./npmctl >/dev/null 2>&1; set +e +o pipefail; _parse_nodes "$1" "$2"' _ "$nodes_sb" "MIBTECH-NPM-PROD-01" 2>/dev/null)"
check "parse_nodes standby row" "STANDBY" "$out"
check "parse_nodes standby is bad" "bad	" "$out"
```

- [ ] **Step 2:** Run `bash tests/test_npmctl.sh` → the M1 checks FAIL.

- [ ] **Step 3:** Implement. Add after `_port()` (before `_parse_drbd`):
```bash
# Known cluster nodes (from group_vars, with MIBTECH fallback).
_node1() { sed -nE 's/^node1_name:[[:space:]]*"?([A-Za-z0-9.-]+)"?.*/\1/p' inventory/group_vars/ha_nodes/vars.yml 2>/dev/null | head -1; }
_node2() { sed -nE 's/^node2_name:[[:space:]]*"?([A-Za-z0-9.-]+)"?.*/\1/p' inventory/group_vars/ha_nodes/vars.yml 2>/dev/null | head -1; }

# _node_short <full> : MIBTECH-NPM-PROD-01 -> PROD-01 (else echo input unchanged).
_node_short() {
  local n="$1"
  if [[ "$n" =~ (PROD-[0-9]+)$ ]]; then printf '%s' "${BASH_REMATCH[1]}"; else printf '%s' "$n"; fi
}

# _node_full <short|full> : resolve to a canonical full cluster node name, or rc 1.
_node_full() {
  local arg="$1" n1 n2; n1="$(_node1)"; n2="$(_node2)"
  n1="${n1:-MIBTECH-NPM-PROD-01}"; n2="${n2:-MIBTECH-NPM-PROD-02}"
  case "$arg" in
    "$n1"|"$(_node_short "$n1")") printf '%s' "$n1" ;;
    "$n2"|"$(_node_short "$n2")") printf '%s' "$n2" ;;
    *) return 1 ;;
  esac
}

# _parse_nodes <pcs-status-nodes-text> <active-full> : emit "state<TAB>icon short  ROLE".
# state: ok=active, bad=standby (reduced redundancy), dim=passive online.
_parse_nodes() {
  local text="$1" active="$2" n short standby_line
  standby_line="$(printf '%s\n' "$text" | grep -E '^ *Standby:' | head -1)"
  for n in "$(_node1)" "$(_node2)"; do
    n="${n:-}"; [[ -z "$n" ]] && continue
    short="$(_node_short "$n")"
    if [[ "$n" == "$active" ]]; then printf 'ok\t● %s  ACTIVE\n' "$short"
    elif printf '%s' "$standby_line" | grep -qF "$n"; then printf 'bad\t⊘ %s  STANDBY\n' "$short"
    else printf 'dim\t○ %s  passive\n' "$short"; fi
  done
}
```
> `_node1`/`_node2` fall back inside `_node_full` but `_parse_nodes` calls them
> directly; in tests group_vars exists so they return the real names. Keep the
> fallback in `_node_full` only (parser stays pure on its text input + the vars file
> which is part of the repo).

- [ ] **Step 4:** Run `bash tests/test_npmctl.sh` → `0 failed`.
- [ ] **Step 5:** Commit:
```bash
git add npmctl tests/test_npmctl.sh
git commit -m "feat(npmctl): node name helpers and pure _parse_nodes"
```

---

### Task 2: Nodes section in `cmd_status`

**Files:** Modify `npmctl`.

- [ ] **Step 1:** In `cmd_status`, the active node must be derived. After the `pcs_raw=...`
line and before building `out`, add active-node extraction; then add a Nodes group.
Locate the Pacemaker block (the `out+=( 'Pacemaker' )` … `done <<< "$(_parse_pcs ...)"`)
and insert, immediately AFTER that block, this Nodes section:
```bash
  # Active node = where npm_vip is Started (from the same pcs_raw).
  local active nodes_raw
  active="$(printf '%s\n' "$pcs_raw" | grep -F 'npm_vip' | grep -oE 'MIBTECH-[A-Z0-9-]+' | head -1)"
  nodes_raw="$(ansible "${active:-$(_node1)}" -b -o -m shell -a 'pcs status nodes' 2>/dev/null | sed 's/\\n/\n/g')"
  out+=( 'Nodes' )
  while IFS=$'\t' read -r st detail; do
    [[ -z "$st" ]] && continue
    [[ "$st" == bad ]] && bad=$((bad+1))
    out+=( "$(_row "$st" "$detail" '')" )
  done <<< "$(_parse_nodes "$nodes_raw" "$active")"
```
> `_row <state> <label> <detail>` already supports `ok`/`bad`; for `dim` it falls to
> the `*)` plain branch (no icon) — but our rows embed their own ●/○/⊘ icon and ROLE
> in the label, so pass the whole `detail` as the label and empty detail. Update `_row`
> to treat `dim` like a plain labelled row (it already does via `*)`).

- [ ] **Step 2:** Verify live (read-only):
```bash
bash -n npmctl && ./npmctl status
```
Expected: the panel now includes a `Nodes` group with `● PROD-0X  ACTIVE` and
`○ PROD-0Y  passive`. Exit 0 when healthy.

- [ ] **Step 3:** Run `bash tests/test_npmctl.sh` → `0 failed` (status panel tests still pass).
- [ ] **Step 4:** Commit:
```bash
git add npmctl
git commit -m "feat(npmctl): show active/passive Nodes section in status panel"
```

---

### Task 3: `_maint_precheck` (pure-ish, TDD)

**Files:** Modify `npmctl`, `tests/test_npmctl.sh`.

`_maint_precheck` takes the DRBD text and pcs-nodes text and the node being drained;
returns 0 if safe (peer online & both DRBD UpToDate on both nodes), else 1 + message.
To stay offline-testable, it accepts the raw texts as args.

- [ ] **Step 1:** Add failing tests before final `echo "== done`:
```bash
echo "== Task M3: maint precheck =="
drbd_ok2="MIBTECH-NPM-PROD-01 | rc=0 | 10: cs:Connected ds:UpToDate/UpToDate
11: cs:Connected ds:UpToDate/UpToDate
MIBTECH-NPM-PROD-02 | rc=0 | 10: cs:Connected ds:UpToDate/UpToDate
11: cs:Connected ds:UpToDate/UpToDate"
nodes_ok="Online: MIBTECH-NPM-PROD-01 MIBTECH-NPM-PROD-02
 Standby:"
bash -c 'source ./npmctl >/dev/null 2>&1; set +e +o pipefail; _maint_precheck "$1" "$2" "$3"' _ "$drbd_ok2" "$nodes_ok" "MIBTECH-NPM-PROD-01" >/dev/null 2>&1
check_rc "precheck ok when healthy" 0 "$?"
drbd_bad2="MIBTECH-NPM-PROD-01 | 10: cs:Connected ds:Inconsistent/UpToDate
11: cs:Connected ds:UpToDate/UpToDate"
bash -c 'source ./npmctl >/dev/null 2>&1; set +e +o pipefail; _maint_precheck "$1" "$2" "$3"' _ "$drbd_bad2" "$nodes_ok" "MIBTECH-NPM-PROD-01" >/dev/null 2>&1
check_rc "precheck fails on inconsistent drbd" 1 "$?"
nodes_peer_sb="Online: MIBTECH-NPM-PROD-01
 Standby: MIBTECH-NPM-PROD-02"
bash -c 'source ./npmctl >/dev/null 2>&1; set +e +o pipefail; _maint_precheck "$1" "$2" "$3"' _ "$drbd_ok2" "$nodes_peer_sb" "MIBTECH-NPM-PROD-01" >/dev/null 2>&1
check_rc "precheck fails when peer already standby" 1 "$?"
```

- [ ] **Step 2:** Run `bash tests/test_npmctl.sh` → M3 checks FAIL.

- [ ] **Step 3:** Implement. Add after `_parse_nodes`:
```bash
# _maint_precheck <drbd-text> <nodes-text> <drain-full> : 0 if safe to drain.
# Safe = peer is Online (not standby/offline) AND no DRBD resource is anything
# other than UpToDate (no Inconsistent/Diskless/Unknown) anywhere in the text.
_maint_precheck() {
  local drbd="$1" nodes="$2" drain="$3" peer n1 n2
  n1="$(_node1)"; n2="$(_node2)"; n1="${n1:-MIBTECH-NPM-PROD-01}"; n2="${n2:-MIBTECH-NPM-PROD-02}"
  if [[ "$drain" == "$n1" ]]; then peer="$n2"; else peer="$n1"; fi
  # peer must appear on an Online: line and NOT on a Standby:/Offline: line.
  if ! printf '%s\n' "$nodes" | grep -E '^ *Online:' | grep -qF "$peer"; then
    warn "maintenance precheck: peer $peer is not Online"; return 1
  fi
  if printf '%s\n' "$nodes" | grep -E '^ *(Standby|Offline):' | grep -qF "$peer"; then
    warn "maintenance precheck: peer $peer is in standby/offline"; return 1
  fi
  # every ds: token must be UpToDate/UpToDate; any other disk state is unsafe.
  if printf '%s\n' "$drbd" | grep -oE 'ds:[A-Za-z]+/[A-Za-z]+' | grep -qvE 'ds:UpToDate/UpToDate'; then
    warn "maintenance precheck: DRBD not UpToDate on both nodes"; return 1
  fi
  return 0
}
```

- [ ] **Step 4:** Run `bash tests/test_npmctl.sh` → `0 failed`.
- [ ] **Step 5:** Commit:
```bash
git add npmctl tests/test_npmctl.sh
git commit -m "feat(npmctl): _maint_precheck guards against draining onto a bad peer"
```

---

### Task 4: `cmd_maintenance` + dispatch/help/menu wiring

**Files:** Modify `npmctl`, `tests/test_npmctl.sh`.

- [ ] **Step 1:** Add failing tests before final `echo "== done`:
```bash
echo "== Task M4: maintenance command =="
out="$(NPMCTL_DRY_RUN=1 bash -c 'source ./npmctl >/dev/null 2>&1; set +e +o pipefail; _node1(){ echo MIBTECH-NPM-PROD-01; }; _node2(){ echo MIBTECH-NPM-PROD-02; }; cmd_maintenance PROD-02 --yes --force' 2>/dev/null)"
check "maintenance standby cmd" "pcs node standby MIBTECH-NPM-PROD-02" "$out"
out="$(NPMCTL_DRY_RUN=1 bash -c 'source ./npmctl >/dev/null 2>&1; set +e +o pipefail; cmd_maintenance end PROD-02' 2>/dev/null)"
check "maintenance end unstandby cmd" "pcs node unstandby MIBTECH-NPM-PROD-02" "$out"
NPMCTL_DRY_RUN=1 bash -c 'source ./npmctl >/dev/null 2>&1; set +e +o pipefail; cmd_maintenance BOGUS' >/dev/null 2>&1
check_rc "maintenance rejects bogus node" 1 "$?"
out="$(NPMCTL_DRY_RUN=1 ./npmctl help 2>&1)"
check "help lists maintenance" "maintenance" "$out"
```

- [ ] **Step 2:** Run `bash tests/test_npmctl.sh` → M4 checks FAIL.

- [ ] **Step 3:** Implement `cmd_maintenance` (add after `cmd_status`):
```bash
cmd_maintenance() {
  # end subcommand: npmctl maintenance end <node>
  if [[ "${1:-}" == "end" ]]; then
    shift; local full; full="$(_node_full "${1:-}")" || { die "maintenance end: unknown node '${1:-}'"; }
    run_step "unstandby $(_node_short "$full")" \
      ansible "$full" -b -m shell -a "pcs node unstandby $full"
    info "maintenance ended for $(_node_short "$full"). DRBD will resync if needed."
    return 0
  fi
  # no node: show roles
  if [[ -z "${1:-}" || "${1:0:2}" == "--" ]]; then
    cmd_status; return $?
  fi
  local full force=0 yes=0 arg
  full="$(_node_full "$1")" || { die "maintenance: unknown node '$1' (use PROD-01 / PROD-02)"; }
  shift
  for arg in "$@"; do case "$arg" in --force) force=1;; --yes) yes=1;; *) die "maintenance: unknown flag $arg";; esac; done

  local n1 n2 peer; n1="$(_node1)"; n2="$(_node2)"; n1="${n1:-MIBTECH-NPM-PROD-01}"; n2="${n2:-MIBTECH-NPM-PROD-02}"
  [[ "$full" == "$n1" ]] && peer="$n2" || peer="$n1"

  if [[ "$DRY_RUN" != "1" && "$force" != "1" ]]; then
    local drbd_raw nodes_raw
    drbd_raw="$(ansible ha_nodes -b -o -m shell -a 'grep -E "^ *[0-9]+:" /proc/drbd' 2>/dev/null)"
    nodes_raw="$(ansible "$peer" -b -o -m shell -a 'pcs status nodes' 2>/dev/null | sed 's/\\n/\n/g')"
    if ! _maint_precheck "$drbd_raw" "$nodes_raw" "$full"; then
      die "refusing to drain $(_node_short "$full") — peer not ready (override with --force)"
    fi
  fi

  # Draining the active node moves the VIP (brief blip) -> confirm.
  local active; active="$(ansible "$peer" -b -o -m shell -a 'pcs status --full | grep npm_vip' 2>/dev/null | grep -oE 'MIBTECH-[A-Z0-9-]+' | head -1)"
  if [[ "$DRY_RUN" != "1" && "$full" == "$active" ]]; then
    [[ "$yes" == "1" ]] && FORCE_YES=1 || FORCE_YES=0
    confirm_or_die "Draining ACTIVE node $(_node_short "$full") moves the VIP to $(_node_short "$peer") (brief blip). Continue?"
  fi

  # Send the standby command to the PEER (which stays up).
  run_step "standby $(_node_short "$full")" \
    ansible "$peer" -b -m shell -a "pcs node standby $full"
  info "$(_node_short "$full") draining to $(_node_short "$peer"). Run 'npmctl maintenance end $(_node_short "$full")' when done."
}
```

- [ ] **Step 4:** Wire dispatch + help + menu:
  - In `dispatch()` add before `*)`:
```bash
    maintenance) cmd_maintenance "$@" ;;
```
  - In `cmd_help` Commands list, add after the `status` line:
```bash
  maintenance   Drain a node for maintenance (standby) / end <node>
```
  - In `interactive_menu`, add `maintenance` to the Maintain group items and a
    description. Change the items + UI_DESC arrays:
```bash
    items=( '--Operate' deploy drift '--Inspect' status logs
            '--Maintain' maintenance backup verify restore update cert vault-edit quit )
    UI_DESC=( '' 'safe converge (gate→backup→verify)' 'check repo vs live config'
              '' 'cluster / DRBD / VIP health' 'tail NPM container logs'
              '' 'drain a node (standby)' 'snapshot proxy hosts' 'verify proxy hosts' 'restore proxy hosts'
              'rolling image update' 'issue/renew TLS' 'edit secrets' 'exit' )
```

- [ ] **Step 5:** Run `bash tests/test_npmctl.sh` → `0 failed` (incl pty menu). Note: `maintenance` with no node calls `cmd_status` which in the menu prints the panel — fine.

- [ ] **Step 6:** Commit:
```bash
git add npmctl tests/test_npmctl.sh
git commit -m "feat(npmctl): maintenance command (standby/unstandby) with precheck + confirm"
```

---

### Task 5: Docs + read-only live acceptance

**Files:** Modify `README.md`.

- [ ] **Step 1:** Add to the `## Managing the cluster: npmctl` README section:
```markdown
`./npmctl status` also shows a **Nodes** section marking which node is ACTIVE
(holds the VIP, NPM service, and DRBD Primary) vs passive. To do maintenance on a
node, drain it to its peer:

    ./npmctl maintenance PROD-01        # standby PROD-01 → services move to PROD-02
    # ... maintain / reboot PROD-01 ...
    ./npmctl maintenance end PROD-01    # unstandby → back in service, DRBD resyncs

`maintenance` refuses to drain if the peer is not Online or DRBD is not UpToDate on
both nodes (override with `--force`); draining the ACTIVE node prompts first
(`--yes` to skip). Standby is permanent until `end`, so it survives a reboot.
```

- [ ] **Step 2:** `bash tests/test_npmctl.sh` → `0 failed`.
- [ ] **Step 3:** Read-only live acceptance (NO real failover):
```bash
./npmctl status            # Nodes section shows ACTIVE/passive
NPMCTL_DRY_RUN=1 ./npmctl maintenance PROD-02 --yes   # prints pcs node standby ... (no execution)
```
Expected: Nodes section renders; dry-run prints the standby command. Do NOT run a real `maintenance` without dry-run.
- [ ] **Step 4:** Commit:
```bash
git add README.md
git commit -m "docs: document npmctl maintenance and active/passive nodes"
```

---

## Acceptance (full)

1. `bash tests/test_npmctl.sh` → all pass (node helpers, _parse_nodes, precheck, maintenance dry-run, pty menu).
2. `bash -n npmctl` → syntax ok.
3. `./npmctl status` (live, read-only) → Nodes section with ACTIVE/passive.
4. `NPMCTL_DRY_RUN=1 ./npmctl maintenance PROD-02` → prints `pcs node standby MIBTECH-NPM-PROD-02`.

## Self-Review Notes

- **Spec coverage:** node helpers + `_parse_nodes` → T1; Nodes section → T2; `_maint_precheck` (no drain onto bad peer) → T3; `cmd_maintenance` standby/unstandby + confirm + dispatch/help/menu → T4; docs/acceptance → T5. Permanent standby (no `--lifetime`) honored. Read-only acceptance honored (dry-run for the mutating path).
- **Placeholder scan:** complete code in every step; precheck/maintenance shown in full.
- **Name consistency:** `_node1/_node2`, `_node_short`, `_node_full`, `_parse_nodes`, `_maint_precheck`, `cmd_maintenance`, `run_step`, `confirm_or_die`/`FORCE_YES` used consistently. Commands sent to the peer (which stays up) when draining.
