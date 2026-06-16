# npmctl Polish Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (chosen: inline, subtle rendering work) to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Polish `npmctl` — parsed cluster-health panel, spinner + ✓/✗ step runner, grouped menu, unified `ui_box` primitive — with offline-testable pure parsers.

**Architecture:** All changes in the single `npmctl` file + the two test files. Pure `_parse_drbd`/`_parse_pcs` (string→string) enable fixture tests with zero production contact. `ui_box` is the one boxed-render primitive; `run_step` wraps long commands with a spinner; `cmd_status` renders a health panel and exits non-zero when unhealthy.

**Tech Stack:** Bash, ANSI, `python3` (pty test). Zero new runtime deps.

---

## File Structure

```
npmctl                      — MODIFY: ui_box, parsers, cmd_status panel, run_step, grouped menu
tests/test_npmctl.sh        — MODIFY: parser + run_step + panel-NO_COLOR tests
tests/test_npmctl_menu.py   — MODIFY: tolerate grouped menu (still selects status)
README.md                   — MODIFY: note status health verdict / exit code
```

---

### Task 1: `ui_box` primitive (+ ASCII fallback), reimplement banner

**Files:** Modify `npmctl`.

- [ ] **Step 1:** Add `ui_box` immediately before `ui_banner`. It draws a rounded box sized to the widest line:

```bash
# ui_box <title> <line>... : rounded box sized to the widest line. NPMCTL_ASCII=1
# (or NO_COLOR with non-UTF terms) falls back to ASCII corners.
ui_box() {
  local title="$1"; shift
  local lines=("$@") w=${#title} i len
  for i in "${lines[@]}"; do len=${#i}; (( len>w )) && w=$len; done
  (( w+=2 ))
  local tl='╭' tr='╮' bl='╰' br='╯' h='─' v='│'
  if [[ -n "${NPMCTL_ASCII:-}" ]]; then tl='+'; tr='+'; bl='+'; br='+'; h='-'; v='|'; fi
  local bar; bar="$(printf "%${w}s" '' | tr ' ' "$h")"
  printf '%s%s%s %s %s%s\n' "$C_CYN" "$tl" "$h" "$title" \
    "$(printf '%*s' "$(( w - ${#title} - 3 ))" '' | tr ' ' "$h")" "$tr$C_RESET"
  for i in "${lines[@]}"; do
    printf '%s%s%s %-*s %s%s%s\n' "$C_CYN" "$v" "$C_RESET" "$((w-2))" "$i" "$C_CYN" "$v" "$C_RESET"
  done
  printf '%s%s%s%s%s\n' "$C_CYN" "$bl" "$bar" "$br" "$C_RESET"
}
```

- [ ] **Step 2:** Replace the body of `ui_banner` with a single `ui_box` call:

```bash
ui_banner() { ui_box 'NPM HA · MIBTECH' 'npmctl — cluster management'; }
```

- [ ] **Step 3:** Sanity (renders, no crash):

Run: `NPMCTL_DRY_RUN=1 bash -c 'NO_COLOR=1; source ./npmctl 2>/dev/null; ui_box "Test" "row one" "longer row two"' 2>/dev/null || true`
Expected: a box whose width fits "longer row two" with aligned right border. (If sourcing runs `main`, ignore its output — the box prints first.)

> NOTE: `source ./npmctl` runs `main "$@"` at EOF. To test functions in isolation, instead extract is unnecessary — use the harness in later tasks. For this manual check, run: `NO_COLOR=1 ./npmctl help >/dev/null; printf 'ok\n'` only to confirm no syntax error: `bash -n npmctl && echo "syntax ok"`.

- [ ] **Step 4:** `bash -n npmctl && echo "syntax ok"` → `syntax ok`. Then `bash tests/test_npmctl.sh` → still `0 failed` (banner change is cosmetic).

- [ ] **Step 5:** Commit:
```bash
git add npmctl
git commit -m "feat(npmctl): add ui_box primitive, reimplement banner via it"
```

---

### Task 2: Pure DRBD/pcs parsers (TDD)

**Files:** Modify `npmctl`, `tests/test_npmctl.sh`.

- [ ] **Step 1:** Add failing tests before the final `echo "== done`:

```bash
echo "== Task P2: parsers =="
# _parse_drbd: healthy -> two ok rows
drbd_ok="10: cs:Connected ro:Primary/Secondary ds:UpToDate/UpToDate C r-----
11: cs:Connected ro:Secondary/Primary ds:UpToDate/UpToDate C r-----"
out="$(NPMCTL_DRY_RUN=1 bash -c 'source ./npmctl >/dev/null 2>&1; _parse_drbd "$1"' _ "$drbd_ok" 2>/dev/null)"
check "drbd healthy app ok" "ok	app" "$out"
check "drbd healthy db ok"  "ok	db"  "$out"
# degraded -> bad
drbd_bad="10: cs:StandAlone ro:Primary/Unknown ds:UpToDate/DUnknown r-----
11: cs:Connected ro:Secondary/Primary ds:Inconsistent/UpToDate C r-----"
out="$(NPMCTL_DRY_RUN=1 bash -c 'source ./npmctl >/dev/null 2>&1; _parse_drbd "$1"' _ "$drbd_bad" 2>/dev/null)"
check "drbd standalone bad" "bad	app" "$out"
check "drbd inconsistent bad" "bad	db" "$out"
# _parse_pcs
pcs_ok="  * npm_vip	(ocf:heartbeat:IPaddr2):	 Started MIBTECH-NPM-PROD-01
  * npm_service	(systemd:npm-stack):	 Started MIBTECH-NPM-PROD-01"
out="$(NPMCTL_DRY_RUN=1 bash -c 'source ./npmctl >/dev/null 2>&1; _parse_pcs "$1"' _ "$pcs_ok" 2>/dev/null)"
check "pcs vip started ok" "ok	npm_vip" "$out"
check "pcs service started ok" "ok	npm_service" "$out"
pcs_bad="  * npm_vip	(ocf:heartbeat:IPaddr2):	 Stopped
Failed Resource Actions:"
out="$(NPMCTL_DRY_RUN=1 bash -c 'source ./npmctl >/dev/null 2>&1; _parse_pcs "$1"' _ "$pcs_bad" 2>/dev/null)"
check "pcs vip stopped bad" "bad	npm_vip" "$out"
check "pcs failed actions bad" "bad	failed-actions" "$out"
```

> The `source ./npmctl` runs `main` with no args; under non-tty it prints help to
> stderr and returns 2 — harmless, we discard output and only call the parser after.
> To avoid `main` side effects entirely, the parsers are defined BEFORE `main` and
> `main` is guarded: see Step 3's guard so sourcing does not execute `main`.

- [ ] **Step 2:** Run `bash tests/test_npmctl.sh` → the 8 new checks FAIL.

- [ ] **Step 3:** Implement. Add a **source-guard** so the file can be sourced in tests without running `main`. Change the final line `main "$@"` to:
```bash
# Only run main when executed directly, not when sourced (tests source for unit access).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi
```
Add the parsers after `cmd_main` (before `cmd_status`):
```bash
# _parse_drbd <text> : emit "ok|bad<TAB>app|db<TAB>detail" per DRBD minor (10=app,11=db).
_parse_drbd() {
  local line minor label st
  while IFS= read -r line; do
    case "$line" in
      10:*) label=app ;;
      11:*) label=db ;;
      *) continue ;;
    esac
    if [[ "$line" == *cs:Connected* && "$line" == *ds:UpToDate/UpToDate* ]]; then st=ok
    else st=bad; fi
    # detail: connection + disk state tokens
    local cs ds
    cs="$(printf '%s\n' "$line" | grep -oE 'cs:[A-Za-z]+' | head -1)"
    ds="$(printf '%s\n' "$line" | grep -oE 'ds:[A-Za-z]+/[A-Za-z]+' | head -1)"
    printf '%s\t%s\t%s %s\n' "$st" "$label" "${cs#cs:}" "${ds#ds:}"
  done <<< "$text_in_drbd_compat$1"
}
```
> The `<<<` line above is wrong (leftover). Use this correct final form for `_parse_drbd`:
```bash
_parse_drbd() {
  local text="$1" line label st cs ds
  while IFS= read -r line; do
    case "$line" in
      10:*) label=app ;;
      11:*) label=db ;;
      *) continue ;;
    esac
    if [[ "$line" == *cs:Connected* && "$line" == *ds:UpToDate/UpToDate* ]]; then st=ok; else st=bad; fi
    cs="$(printf '%s\n' "$line" | grep -oE 'cs:[A-Za-z]+' | head -1)"
    ds="$(printf '%s\n' "$line" | grep -oE 'ds:[A-Za-z]+/[A-Za-z]+' | head -1)"
    printf '%s\t%s\t%s %s\n' "$st" "$label" "${cs#cs:}" "${ds#ds:}"
  done <<< "$text"
}

# _parse_pcs <text> : emit "ok|bad<TAB>name<TAB>detail" for npm_vip, npm_service,
# and a "bad<TAB>failed-actions" row if Failed Resource Actions are present.
_parse_pcs() {
  local text="$1" line name st detail
  for name in npm_vip npm_service; do
    line="$(printf '%s\n' "$text" | grep -F "$name" | head -1)"
    [[ -z "$line" ]] && continue
    if [[ "$line" == *Started* ]]; then
      st=ok; detail="Started $(printf '%s\n' "$line" | grep -oE 'MIBTECH-[A-Z0-9-]+' | head -1)"
    else
      st=bad; detail="$(printf '%s\n' "$line" | grep -oE 'Stopped|FAILED|Starting' | head -1)"; detail="${detail:-down}"
    fi
    printf '%s\t%s\t%s\n' "$st" "$name" "$detail"
  done
  if printf '%s\n' "$text" | grep -q 'Failed Resource Actions'; then
    printf 'bad\tfailed-actions\tpresent\n'
  fi
}
```
Use ONLY the corrected `_parse_drbd` (the loop-based `text="$1"` form) and `_parse_pcs`; delete the erroneous first `_parse_drbd` variant.

- [ ] **Step 4:** Run `bash tests/test_npmctl.sh` → `0 failed`.
- [ ] **Step 5:** Commit:
```bash
git add npmctl tests/test_npmctl.sh
git commit -m "feat(npmctl): pure DRBD/pcs parsers with source-guard for tests"
```

---

### Task 3: Health panel `cmd_status` + non-zero on unhealthy

**Files:** Modify `npmctl`, `tests/test_npmctl.sh`.

- [ ] **Step 1:** Replace the entire `cmd_status` function with:
```bash
cmd_status() {
  local vip port; vip="$(_vip)"; vip="${vip:-192.168.206.220}"; port="$(_port)"; port="${port:-15625}"
  if [[ "$DRY_RUN" == "1" ]]; then
    run ansible ha_nodes -b -m shell -a 'cat /proc/drbd'   # keeps dry-run test contract
    return 0
  fi
  local drbd_raw pcs_raw http rows=() bad=0 st label detail
  drbd_raw="$(ansible ha_nodes -b -o -m shell -a 'grep -E "^ *[0-9]+:" /proc/drbd' 2>/dev/null | grep -oE '1[01]: cs:[^"]*' | sort -u)"
  pcs_raw="$(ansible ha_nodes -b -o -m shell -a 'pcs status --full | grep -E "npm_service|npm_vip|Failed Resource"' 2>/dev/null)"
  http="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 "http://${vip}:${port}/" 2>/dev/null || echo 000)"

  local out=( 'DRBD' )
  while IFS=$'\t' read -r st label detail; do
    [[ -z "$st" ]] && continue
    [[ "$st" == bad ]] && bad=$((bad+1))
    out+=( "$(_row "$st" "  $label" "$detail")" )
  done <<< "$(_parse_drbd "$drbd_raw")"
  out+=( 'Pacemaker' )
  while IFS=$'\t' read -r st label detail; do
    [[ -z "$st" ]] && continue
    [[ "$st" == bad ]] && bad=$((bad+1))
    out+=( "$(_row "$st" "  $label" "$detail")" )
  done <<< "$(_parse_pcs "$pcs_raw")"
  out+=( "VIP ${vip}:${port}" )
  if [[ "$http" == 2* || "$http" == 3* ]]; then out+=( "$(_row ok '  HTTP' "$http")" )
  else out+=( "$(_row bad '  HTTP' "$http")" ); bad=$((bad+1)); fi

  if (( bad == 0 )); then out+=( "$(_row ok '' 'healthy')" )
  else out+=( "$(_row bad '' "$bad issue(s)")" ); fi

  ui_box 'Cluster Health' "${out[@]}"
  (( bad == 0 ))
}

# _row <ok|bad|''> <label> <detail> : "✓ label detail" / "✗ label detail" / plain group head.
_row() {
  local st="$1" label="$2" detail="$3" icon=''
  case "$st" in
    ok)  icon="${C_GREEN}✓${C_RESET} " ;;
    bad) icon="${C_RED}✗${C_RESET} " ;;
    *)   icon='' ;;
  esac
  printf '%s%s %s' "$icon" "$label" "$detail"
}
```
Add `-o` (oneline) is already in the ansible calls. `_row` must be defined before `cmd_status` or anywhere at top level (bash resolves at call time, so order within the file is fine as long as both exist before `main` runs).

- [ ] **Step 2:** Add a test (panel renders, NO_COLOR has zero ESC) before final `echo "== done`:
```bash
echo "== Task P3: status panel rendering =="
out="$(NO_COLOR=1 bash -c 'source ./npmctl >/dev/null 2>&1
  _row(){ :; }; ' 2>/dev/null; printf '')"
# Render a panel directly from parser output under NO_COLOR; assert zero ESC bytes.
esc="$(NO_COLOR=1 bash -c '
  source ./npmctl >/dev/null 2>&1
  out=("DRBD" "$(_row ok "  app" "Connected UpToDate/UpToDate")")
  ui_box "Cluster Health" "${out[@]}"
' 2>/dev/null | tr -cd "\033" | wc -c | tr -d " ")"
check "status panel NO_COLOR has no ESC" "0" "$esc"
out="$(NO_COLOR=1 bash -c 'source ./npmctl >/dev/null 2>&1; _row ok "  app" "x"' 2>/dev/null)"
check "row ok shows check" "✓" "$out"
```

- [ ] **Step 3:** Run `bash tests/test_npmctl.sh` → `0 failed`.
- [ ] **Step 4:** Commit:
```bash
git add npmctl tests/test_npmctl.sh
git commit -m "feat(npmctl): parsed cluster-health status panel, non-zero on unhealthy"
```

---

### Task 4: `run_step` spinner; route deploy + wrappers through it

**Files:** Modify `npmctl`, `tests/test_npmctl.sh`.

- [ ] **Step 1:** Add `run_step` after `run`:
```bash
# run_step <label> <cmd...> : spinner while running (TTY), then ✓/✗ + elapsed.
# Honors dry-run (prints "would-run: <cmd>") and non-TTY (plain lines).
run_step() {
  local label="$1"; shift
  if [[ "$DRY_RUN" == "1" ]]; then printf 'would-run: %s\n' "$*"; return 0; fi
  local log; log="$(mktemp)"; local start=$SECONDS
  if [[ -t 1 ]]; then
    ( "$@" >"$log" 2>&1 ) & local pid=$!
    local frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0
    tput civis 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null; do
      printf '\r%s %s' "${frames:i++%10:1}" "$label" >/dev/tty; sleep 0.1
    done
    wait "$pid"; local rc=$?; tput cnorm 2>/dev/null || true
    printf '\r\033[K' >/dev/tty
  else
    printf '• %s\n' "$label"; "$@" >"$log" 2>&1; local rc=$?
  fi
  local secs=$(( SECONDS - start ))
  if (( rc == 0 )); then printf '%s✓%s %s (%ss)\n' "$C_GREEN" "$C_RESET" "$label" "$secs"
  else printf '%s✗%s %s (rc %s)\n' "$C_RED" "$C_RESET" "$label" "$rc"; tail -n 15 "$log"; fi
  rm -f "$log"; return "$rc"
}
```

- [ ] **Step 2:** Route wrappers + deploy steps through `run_step` (labels added; behavior identical under dry-run since `run_step` dry-run prints `would-run:` exactly like `run`). Replace the six wrapper functions:
```bash
cmd_drift()   { run_step "drift check" ansible-playbook drift_check.yml "$@"; }
cmd_backup()  { run_step "snapshot proxy hosts" ansible-playbook proxy_backup.yml "$@"; }
cmd_verify()  { run_step "verify proxy hosts" ansible-playbook proxy_verify.yml "$@"; }
cmd_restore() { run_step "restore proxy hosts" ansible-playbook proxy_restore.yml "$@"; }
cmd_update()  { run_step "rolling update" ansible-playbook npm_update.yml "$@"; }
cmd_cert()    { run_step "issue/renew certs" ansible-playbook cert_manager.yml "$@"; }
```
And `cmd_main`:
```bash
cmd_main() { run_step "converge (main.yml)" ansible-playbook main.yml "$@"; }
```

- [ ] **Step 3:** Existing dry-run tests already assert `would-run: ansible-playbook <pb>`; `run_step` dry-run prints exactly that, so they still pass. Add one explicit check before final `echo "== done`:
```bash
echo "== Task P4: run_step =="
out="$(NPMCTL_DRY_RUN=1 bash -c 'source ./npmctl >/dev/null 2>&1; run_step lbl ansible-playbook foo.yml' 2>/dev/null)"
check "run_step dry-run prints would-run" "would-run: ansible-playbook foo.yml" "$out"
```

- [ ] **Step 4:** Run `bash tests/test_npmctl.sh` → `0 failed` (all prior wrapper + deploy tests still green).
- [ ] **Step 5:** Commit:
```bash
git add npmctl tests/test_npmctl.sh
git commit -m "feat(npmctl): run_step spinner; route playbook commands through it"
```

---

### Task 5: Grouped menu with descriptions

**Files:** Modify `npmctl`, `tests/test_npmctl_menu.py`.

- [ ] **Step 1:** Extend `ui_menu` to skip non-selectable divider rows. Replace `ui_menu` with a version that treats items beginning with the marker `--` as dividers (drawn dim, never selected) and supports an optional parallel `UI_DESC` array:
```bash
ui_menu() {
  local prompt="$1"; shift
  local items=("$@") sel=0 key i
  # find first selectable row
  _sel_next() { local d="$1"; local n=$sel; while :; do n=$((n+d)); ((n<0||n>=${#items[@]})) && return 1; [[ "${items[$n]}" == --* ]] || { sel=$n; return 0; }; done; }
  [[ "${items[0]}" == --* ]] && _sel_next 1
  tput civis >/dev/tty 2>/dev/null || true
  while true; do
    printf '%s%s%s\n' "$C_BOLD" "$prompt" "$C_RESET" >/dev/tty
    for i in "${!items[@]}"; do
      local it="${items[$i]}" desc="${UI_DESC[$i]:-}"
      if [[ "$it" == --* ]]; then printf '  %s%s%s\n' "$C_DIM" "${it#--}" "$C_RESET" >/dev/tty
      elif [[ "$i" == "$sel" ]]; then printf '  %s› %-10s%s %s%s%s\n' "$C_GREEN" "$it" "$C_RESET" "$C_DIM" "$desc" "$C_RESET" >/dev/tty
      else printf '    %-10s %s%s%s\n' "$it" "$C_DIM" "$desc" "$C_RESET" >/dev/tty; fi
    done
    IFS= read -rsn1 key </dev/tty
    if [[ "$key" == $'\e' ]]; then read -rsn2 -t 0.001 key </dev/tty || true
      case "$key" in '[A') _sel_next -1 || true;; '[B') _sel_next 1 || true;; esac
    elif [[ "$key" == "" ]]; then [[ "${items[$sel]}" == --* ]] || break
    fi
    printf '\e[%dA' "$(( ${#items[@]} + 1 ))" >/dev/tty
  done
  tput cnorm >/dev/tty 2>/dev/null || true
  printf '%s' "${items[$sel]}"
}
```
(Number-key shortcuts are dropped here because divider rows would misalign indices; arrow nav is the primary interaction and the pty test uses arrows.)

- [ ] **Step 2:** Replace `interactive_menu`'s main `ui_menu` call to pass grouped items + descriptions:
```bash
interactive_menu() {
  local choice
  local UI_DESC=()
  while true; do
    clear 2>/dev/null || true
    ui_banner
    local items=( '--Operate' deploy drift '--Inspect' status logs '--Maintain' backup verify restore update cert vault-edit quit )
    UI_DESC=(  '' 'safe converge (gate→backup→verify)' 'check repo vs live'
               '' 'cluster / DRBD / VIP health' 'tail NPM logs'
               '' 'snapshot proxy hosts' 'verify proxy hosts' 'restore proxy hosts'
               'rolling image update' 'issue/renew TLS' 'edit secrets' 'exit' )
    choice="$(ui_menu 'Choose an action:' "${items[@]}")"
    [[ "$choice" == "quit" ]] && break
    printf '\n'
    if [[ "$choice" == "vault-edit" ]]; then
      local t; t="$(ui_menu 'Which vault?' 'ha_nodes' 'controller')"; dispatch vault-edit "$t" || true
    else
      dispatch "$choice" || warn "command '$choice' failed (rc $?)"
    fi
    printf '\n%sPress Enter to return to the menu…%s' "$C_DIM" "$C_RESET"; read -r
  done
}
```

- [ ] **Step 3:** Update `tests/test_npmctl_menu.py`: the first selectable item is now `deploy` (after the `Operate` divider), and `status` is reached by navigating. Keep it simple — change the test to send two Down presses to land on `status` (Operate divider skipped, deploy→drift→status), Enter, and assert `would-run`/clean dispatch is NOT required; instead assert dispatch of `deploy` by pressing Enter immediately (selection auto-lands on `deploy`, the first selectable). Replace the send logic: on seeing "Choose an action", send `\r` (selects `deploy`), and assert `would-run: ansible-playbook drift_check.yml` appears and no "Unknown command". (This still validates the capture-bug fix with the grouped menu.)

Concretely, in `tests/test_npmctl_menu.py`, no structural change is needed if the first selectable row is `deploy` and Enter selects it — but the auto-advance past the leading `--Operate` divider must work. Verify by running; if it lands on the divider, the test will show "Unknown command" and fail, catching a regression.

- [ ] **Step 4:** Run `bash tests/test_npmctl.sh` → `0 failed` (includes the pty menu test).
- [ ] **Step 5:** Commit:
```bash
git add npmctl tests/test_npmctl_menu.py
git commit -m "feat(npmctl): grouped menu with section dividers and descriptions"
```

---

### Task 6: Docs + live acceptance

**Files:** Modify `README.md`.

- [ ] **Step 1:** In the `## Managing the cluster: npmctl` README section, append a note:
```markdown
`./npmctl status` renders a parsed health panel (✓/✗ for DRBD, Pacemaker, and the
VIP) and exits non-zero if anything is unhealthy — usable as a monitoring check.
Long playbook commands show a live spinner with a ✓/✗ result. Set `NPMCTL_ASCII=1`
for terminals without box-drawing glyphs.
```

- [ ] **Step 2:** Full harness: `bash tests/test_npmctl.sh` → `0 failed`.
- [ ] **Step 3:** Live acceptance (read-only, controller): `./npmctl status` → parsed panel, exits 0 when healthy:
```bash
./npmctl status; echo "status exit=$?"
```
Expected: a "Cluster Health" box with ✓ rows; `status exit=0`.
- [ ] **Step 4:** Commit:
```bash
git add README.md
git commit -m "docs: note npmctl status health panel and exit code"
```

---

## Acceptance (full)

1. `bash tests/test_npmctl.sh` → all pass including parsers, run_step, panel-NO_COLOR, pty menu.
2. `bash -n npmctl` → syntax ok.
3. `./npmctl status` (live) → parsed health panel, exit 0 healthy.
4. `./npmctl` (TTY) → grouped menu, arrow nav skips dividers, selection dispatches cleanly.

## Self-Review Notes

- **Spec coverage:** ui_box → T1; pure parsers → T2; health panel + non-zero exit → T3; run_step + routing → T4; grouped menu + ui_menu divider support → T5; docs/acceptance → T6. Source-guard (sourcing without running main) added in T2 enables all parser/panel/run_step unit tests.
- **Placeholder scan:** T2 Step 3 explicitly flags and replaces the erroneous first `_parse_drbd` draft with the final form to use; all other code blocks are complete.
- **Name consistency:** `ui_box`, `_parse_drbd`, `_parse_pcs`, `_row`, `run_step`, `UI_DESC`, `_sel_next` used consistently across npmctl and tests. Wrapper functions keep their `cmd_*` names so `dispatch` is unchanged. Dry-run `would-run:` contract preserved by `run_step`.
