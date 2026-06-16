# npmctl Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `npmctl`, a self-contained bash management CLI + interactive TUI that wraps the project's Ansible playbooks, with a safety-gated `deploy` (drift-check + proxy-backup, abort on drift).

**Architecture:** One executable bash file at the repo root. `cmd_*` functions wrap each playbook; a `run()` helper executes (or, under `NPMCTL_DRY_RUN=1`, prints `would-run: …`) so behaviour is testable offline. A `dispatch()` maps subcommands to functions; with no args, an interactive ANSI menu calls the same functions. A dependency-free `tests/test_npmctl.sh` drives everything in dry-run.

**Tech Stack:** Bash (`set -euo pipefail`), ANSI escapes, ansible (already required). `shellcheck` for dev static analysis.

---

## File Structure

```
npmctl                  — CREATE: the whole tool (one executable bash file)
tests/test_npmctl.sh    — CREATE: dependency-free dry-run test harness
README.md               — MODIFY: document ./npmctl
```

The script is built up across Tasks 1–5; the test harness grows with it. Each task leaves a runnable, tested script.

---

### Task 1: Skeleton — config, run(), dispatch, help, test harness

**Files:**
- Create: `npmctl`
- Create: `tests/test_npmctl.sh`

- [ ] **Step 1: Write the failing test harness** — `tests/test_npmctl.sh`:

```bash
#!/usr/bin/env bash
# Dependency-free tests for npmctl. Runs everything in dry-run (NPMCTL_DRY_RUN=1)
# so nothing touches ansible or production.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
NPMCTL=./npmctl
PASS=0; FAIL=0

check() { # check <description> <expected-substring> <actual>
  if printf '%s' "$3" | grep -qF -- "$2"; then
    PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else
    FAIL=$((FAIL+1)); printf '  FAIL %s\n     want substring: %s\n     got: %s\n' "$1" "$2" "$3"
  fi
}
check_rc() { # check_rc <description> <expected-rc> <actual-rc>
  if [[ "$2" == "$3" ]]; then PASS=$((PASS+1)); printf '  ok   %s\n' "$1"
  else FAIL=$((FAIL+1)); printf '  FAIL %s (rc want %s got %s)\n' "$1" "$2" "$3"; fi
}

echo "== Task 1: dispatch/help =="
out="$(NPMCTL_DRY_RUN=1 $NPMCTL help 2>&1)"; check "help lists deploy" "deploy" "$out"
check "help lists status" "status" "$out"
NPMCTL_DRY_RUN=1 $NPMCTL bogus >/dev/null 2>&1; check_rc "unknown command exits non-zero" 2 "$?"
out="$(NPMCTL_DRY_RUN=1 $NPMCTL bogus 2>&1)"; check "unknown command shows usage" "Usage" "$out"

echo "== done: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]]
```

- [ ] **Step 2: Run the harness, verify it fails**

Run: `chmod +x tests/test_npmctl.sh && bash tests/test_npmctl.sh`
Expected: FAIL (npmctl does not exist yet) — errors about `./npmctl` not found.

- [ ] **Step 3: Create the skeleton** — `npmctl`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Resolve repo root (script's own dir) so ansible.cfg is always found.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN="${NPMCTL_DRY_RUN:-0}"

# --- output helpers ---
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
warn() { printf 'warning: %s\n' "$*" >&2; }
info() { printf '%s\n' "$*"; }

# run <cmd...> : execute, or under dry-run print what would run.
run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'would-run: %s\n' "$*"
    return 0
  fi
  "$@"
}

# --- command functions (filled in by later tasks) ---
cmd_help() {
  cat <<'EOF'
npmctl — manage the NPM HA cluster

Usage: npmctl <command> [flags]
       npmctl              (no args: interactive menu)

Commands:
  deploy        Safe converge: drift-check + backup, then main.yml, then verify
  drift         Check repo vs live config drift
  backup        Snapshot NPM proxy hosts
  verify        Verify proxy hosts against the snapshot
  restore       Restore missing proxy hosts from the snapshot
  update        Rolling NPM image update
  cert          Issue/renew TLS certificates
  status        Show cluster / DRBD / VIP health
  logs          Tail NPM container logs
  vault-edit    Edit an encrypted vault (ha_nodes|controller)
  help          Show this help
EOF
}

# --- dispatch ---
dispatch() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    help|-h|--help) cmd_help ;;
    *) printf 'Usage: npmctl <command>\nUnknown command: %s\n' "$cmd" >&2; cmd_help >&2; return 2 ;;
  esac
}

main() {
  cd "$SCRIPT_DIR"
  [[ -f ansible.cfg ]] || die "must be run from the project root (ansible.cfg not found)"
  dispatch "$@"
}

main "$@"
```

- [ ] **Step 4: Make executable, run the harness, verify it passes**

Run: `chmod +x npmctl && bash tests/test_npmctl.sh`
Expected: PASS — `0 failed`. (help lists deploy/status; unknown command exits 2 with Usage.)

- [ ] **Step 5: shellcheck**

Run: `shellcheck npmctl tests/test_npmctl.sh`
Expected: no warnings. (If `shellcheck` is not installed, note it and skip — not a blocker.)

- [ ] **Step 6: Commit**

```bash
git add npmctl tests/test_npmctl.sh
git commit -m "feat(npmctl): skeleton with dispatch, help, dry-run test harness"
```

---

### Task 2: Playbook wrapper commands

**Files:**
- Modify: `npmctl`
- Modify: `tests/test_npmctl.sh`

- [ ] **Step 1: Add failing tests** — append to `tests/test_npmctl.sh` before the final `echo "== done`:

```bash
echo "== Task 2: playbook wrappers =="
for pair in "drift:drift_check.yml" "backup:proxy_backup.yml" "verify:proxy_verify.yml" \
            "restore:proxy_restore.yml" "update:npm_update.yml" "cert:cert_manager.yml"; do
  c="${pair%%:*}"; pb="${pair##*:}"
  out="$(NPMCTL_DRY_RUN=1 $NPMCTL "$c" 2>&1)"
  check "$c runs $pb" "would-run: ansible-playbook $pb" "$out"
done
```

- [ ] **Step 2: Run, verify new tests fail**

Run: `bash tests/test_npmctl.sh`
Expected: the six Task-2 checks FAIL (commands unknown → usage), Task-1 still passes.

- [ ] **Step 3: Implement the wrappers** — in `npmctl`, add these functions after `cmd_help`:

```bash
cmd_drift()   { run ansible-playbook drift_check.yml "$@"; }
cmd_backup()  { run ansible-playbook proxy_backup.yml "$@"; }
cmd_verify()  { run ansible-playbook proxy_verify.yml "$@"; }
cmd_restore() { run ansible-playbook proxy_restore.yml "$@"; }
cmd_update()  { run ansible-playbook npm_update.yml "$@"; }
cmd_cert()    { run ansible-playbook cert_manager.yml "$@"; }
```

And extend the `case` in `dispatch()` (add these branches before the `*)` default):

```bash
    drift)   cmd_drift "$@" ;;
    backup)  cmd_backup "$@" ;;
    verify)  cmd_verify "$@" ;;
    restore) cmd_restore "$@" ;;
    update)  cmd_update "$@" ;;
    cert)    cmd_cert "$@" ;;
```

- [ ] **Step 4: Run, verify all pass**

Run: `bash tests/test_npmctl.sh`
Expected: PASS, `0 failed`.

- [ ] **Step 5: shellcheck + commit**

```bash
shellcheck npmctl
git add npmctl tests/test_npmctl.sh
git commit -m "feat(npmctl): add playbook wrapper commands"
```

---

### Task 3: Safety-gated deploy (--force / --yes)

**Files:**
- Modify: `npmctl`
- Modify: `tests/test_npmctl.sh`

- [ ] **Step 1: Add failing tests** — append before the final `echo "== done`:

```bash
echo "== Task 3: deploy gate =="
out="$(NPMCTL_DRY_RUN=1 $NPMCTL deploy 2>&1)"
check "deploy step1 drift"   "would-run: ansible-playbook drift_check.yml" "$out"
check "deploy step2 backup"  "would-run: ansible-playbook proxy_backup.yml" "$out"
check "deploy step3 confirm" "would-confirm:" "$out"
check "deploy step4 main"    "would-run: ansible-playbook main.yml" "$out"
check "deploy step5 verify"  "would-run: ansible-playbook proxy_verify.yml" "$out"
# ordering: drift before backup before main before verify
order="$(printf '%s\n' "$out" | grep -nE 'drift_check.yml|proxy_backup.yml|main.yml|proxy_verify.yml' | cut -d: -f1 | tr '\n' ' ')"
check "deploy ordering is sorted" "$(printf '%s' "$order" | tr ' ' '\n' | sort -n | tr '\n' ' ')" "$order"
out="$(NPMCTL_DRY_RUN=1 $NPMCTL deploy --force 2>&1)"
check "deploy --force notes bypass" "drift gate bypassed" "$out"
out="$(NPMCTL_DRY_RUN=1 $NPMCTL deploy --yes 2>&1)"
check "deploy --yes skips confirm" "confirm-skipped" "$out"
```

- [ ] **Step 2: Run, verify new tests fail**

Run: `bash tests/test_npmctl.sh`
Expected: Task-3 checks FAIL (deploy unknown), earlier tasks pass.

- [ ] **Step 3: Implement deploy + confirm helper** — add to `npmctl` after `cmd_cert`:

```bash
# confirm_or_die <message> : interactive yes/no. Honors --yes (FORCE_YES) and dry-run.
FORCE_YES=0
confirm_or_die() {
  local msg="$1"
  if [[ "$FORCE_YES" == "1" ]]; then
    [[ "$DRY_RUN" == "1" ]] && printf 'confirm-skipped: %s\n' "$msg"
    return 0
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'would-confirm: %s\n' "$msg"; return 0
  fi
  local ans
  read -r -p "$msg [y/N] " ans
  [[ "$ans" == "y" || "$ans" == "Y" ]] || die "aborted by operator"
}

cmd_deploy() {
  local force=0
  FORCE_YES=0
  for arg in "$@"; do
    case "$arg" in
      --force) force=1 ;;
      --yes)   FORCE_YES=1 ;;
      *) die "deploy: unknown flag $arg" ;;
    esac
  done

  info "[1/5] drift check"
  if ! cmd_drift; then
    if [[ "$force" == "1" ]]; then
      warn "drift detected — continuing because --force (drift gate bypassed)"
    else
      die "drift detected — reconcile repo vs live, or re-run with --force"
    fi
  fi

  info "[2/5] snapshot proxy hosts"
  cmd_backup

  info "[3/5] confirm"
  confirm_or_die "About to converge PRODUCTION (main.yml). Continue?"

  info "[4/5] converge"
  cmd_main

  info "[5/5] verify proxy hosts survived"
  cmd_verify
}

cmd_main() { run ansible-playbook main.yml "$@"; }
```

> NOTE: under dry-run, `cmd_drift` returns 0 (the `run` helper prints and returns 0),
> so the `--force` branch's "drift gate bypassed" line is reached only when drift is
> real. To make `--force` observable in dry-run for the test, emit the bypass note
> whenever `--force` is passed: replace the `info "[1/5] drift check"` block's
> failure handling with the version below, which also notes the bypass intent up front:

```bash
  info "[1/5] drift check"
  if [[ "$force" == "1" ]]; then info "drift gate bypassed (--force)"; fi
  if ! cmd_drift && [[ "$force" != "1" ]]; then
    die "drift detected — reconcile repo vs live, or re-run with --force"
  fi
```

Use this second form (it makes `--force` testable in dry-run and still aborts on real drift without `--force`). Add the `deploy)` branch to `dispatch()`:

```bash
    deploy)  cmd_deploy "$@" ;;
```

- [ ] **Step 4: Run, verify all pass**

Run: `bash tests/test_npmctl.sh`
Expected: PASS, `0 failed` (deploy prints all five steps in order; `--force` notes bypass; `--yes` prints `confirm-skipped`).

- [ ] **Step 5: shellcheck + commit**

```bash
shellcheck npmctl
git add npmctl tests/test_npmctl.sh
git commit -m "feat(npmctl): safety-gated deploy with --force/--yes"
```

---

### Task 4: Live commands — status, logs, vault-edit

**Files:**
- Modify: `npmctl`
- Modify: `tests/test_npmctl.sh`

- [ ] **Step 1: Add failing tests** — append before final `echo "== done`:

```bash
echo "== Task 4: live commands =="
out="$(NPMCTL_DRY_RUN=1 $NPMCTL status 2>&1)"
check "status probes drbd"  "would-run: ansible ha_nodes" "$out"
out="$(NPMCTL_DRY_RUN=1 $NPMCTL logs 2>&1)"
check "logs uses docker compose logs" "compose" "$out"
out="$(NPMCTL_DRY_RUN=1 $NPMCTL vault-edit ha_nodes 2>&1)"
check "vault-edit edits ha_nodes vault" "would-run: ansible-vault edit inventory/group_vars/ha_nodes/vault.yml" "$out"
NPMCTL_DRY_RUN=1 $NPMCTL vault-edit bogus >/dev/null 2>&1; check_rc "vault-edit rejects bad target" 1 "$?"
```

- [ ] **Step 2: Run, verify fail**

Run: `bash tests/test_npmctl.sh`
Expected: Task-4 checks FAIL.

- [ ] **Step 3: Implement** — add to `npmctl` after `cmd_main`:

```bash
# VIP/admin port: parsed from group_vars with documented fallbacks.
_vip() {  sed -nE 's/^vip_address:[[:space:]]*"?([0-9.]+)"?.*/\1/p' inventory/group_vars/ha_nodes/vars.yml 2>/dev/null | head -1; }
_port() { sed -nE 's/^npm_admin_port:[[:space:]]*"?([0-9]+)"?.*/\1/p'   inventory/group_vars/ha_nodes/vars.yml 2>/dev/null | head -1; }

cmd_status() {
  local vip port; vip="$(_vip)"; vip="${vip:-192.168.206.220}"; port="$(_port)"; port="${port:-15625}"
  info "DRBD:"
  run ansible ha_nodes -b -m shell -a 'grep -E "^ *[0-9]+:" /proc/drbd'
  info "Pacemaker:"
  run ansible ha_nodes -b -m shell -a 'pcs status --full | grep -E "npm_service|npm_vip|Failed Resource" || true'
  info "VIP ${vip}:${port}:"
  run curl -s -o /dev/null -w 'HTTP %{http_code}\n' --max-time 8 "http://${vip}:${port}/"
}

cmd_logs() {
  local n="${1:-50}"
  run ansible ha_nodes -b -m shell -a "docker compose -f /opt/npm/compose/docker-compose.yml logs --tail=${n} 2>/dev/null || true"
}

cmd_vault_edit() {
  local target="${1:-}"
  case "$target" in
    ha_nodes)   run ansible-vault edit inventory/group_vars/ha_nodes/vault.yml ;;
    controller) run ansible-vault edit inventory/group_vars/controller/vault.yml ;;
    *) die "vault-edit: target must be ha_nodes or controller" ;;
  esac
}
```

Add branches to `dispatch()`:

```bash
    status)     cmd_status "$@" ;;
    logs)       cmd_logs "$@" ;;
    vault-edit) cmd_vault_edit "$@" ;;
```

- [ ] **Step 4: Run, verify pass**

Run: `bash tests/test_npmctl.sh`
Expected: PASS, `0 failed`.

- [ ] **Step 5: shellcheck + commit**

```bash
shellcheck npmctl
git add npmctl tests/test_npmctl.sh
git commit -m "feat(npmctl): add status, logs, vault-edit commands"
```

---

### Task 5: Interactive ANSI UI

**Files:**
- Modify: `npmctl`
- Modify: `tests/test_npmctl.sh`

- [ ] **Step 1: Add failing tests** (TTY guard + color discipline are the unit-testable parts) — append before final `echo "== done`:

```bash
echo "== Task 5: UI guards =="
# No args + non-TTY stdin (piped) must NOT hang; prints help and exits non-zero.
out="$(printf '' | NPMCTL_DRY_RUN=1 $NPMCTL 2>&1)"; rc=$?
check "no-args non-tty shows help" "Usage: npmctl" "$out"
check_rc "no-args non-tty exits non-zero" 2 "$rc"
# NO_COLOR disables ANSI escapes in help output.
out="$(NO_COLOR=1 NPMCTL_DRY_RUN=1 $NPMCTL help 2>&1)"
if printf '%s' "$out" | grep -q $'\e['; then check "NO_COLOR strips ANSI" "NO_ESC" "ESC_FOUND"; else check "NO_COLOR strips ANSI" "" ""; fi
```

- [ ] **Step 2: Run, verify the new guard tests fail**

Run: `bash tests/test_npmctl.sh`
Expected: the no-args guard checks FAIL (currently no-args calls `dispatch ""` → unknown). Color check passes trivially (no color yet).

- [ ] **Step 3: Implement color setup** — insert near the top of `npmctl`, right after the `DRY_RUN=` line:

```bash
# ANSI palette — disabled when not a TTY or NO_COLOR is set.
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
  C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YEL=$'\e[33m'; C_BLU=$'\e[34m'; C_CYN=$'\e[36m'
else
  C_RESET=''; C_BOLD=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YEL=''; C_BLU=''; C_CYN=''
fi
```

- [ ] **Step 4: Implement the UI + menu + main guard** — add these functions before `main()`:

```bash
ui_banner() {
  printf '%s╭─ NPM HA ─ MIBTECH ──────────────╮%s\n' "$C_CYN" "$C_RESET"
  printf '%s│%s  npmctl — cluster management    %s│%s\n' "$C_CYN" "$C_RESET" "$C_CYN" "$C_RESET"
  printf '%s╰─────────────────────────────────╯%s\n' "$C_CYN" "$C_RESET"
}

# ui_menu <prompt> <item1> <item2> ... : arrow-key + number select; echoes chosen item.
ui_menu() {
  local prompt="$1"; shift
  local items=("$@") sel=0 key i
  tput civis 2>/dev/null || true
  while true; do
    printf '%s%s%s\n' "$C_BOLD" "$prompt" "$C_RESET"
    for i in "${!items[@]}"; do
      if [[ "$i" == "$sel" ]]; then printf '  %s› %s%s\n' "$C_GREEN" "${items[$i]}" "$C_RESET"
      else printf '    %s\n' "${items[$i]}"; fi
    done
    IFS= read -rsn1 key
    if [[ "$key" == $'\e' ]]; then read -rsn2 -t 0.001 key || true
      case "$key" in '[A') ((sel>0)) && ((sel--));; '[B') ((sel<${#items[@]}-1)) && ((sel++));; esac
    elif [[ "$key" == "" ]]; then break
    elif [[ "$key" =~ ^[0-9]$ ]] && (( key>=1 && key<=${#items[@]} )); then sel=$((key-1)); break
    fi
    printf '\e[%dA' "$(( ${#items[@]} + 1 ))"  # cursor back up to redraw
  done
  tput cnorm 2>/dev/null || true
  printf '%s' "${items[$sel]}"
}

interactive_menu() {
  local choice
  while true; do
    clear 2>/dev/null || true
    ui_banner
    choice="$(ui_menu 'Choose an action:' \
      'deploy' 'drift' 'status' 'backup' 'verify' 'restore' \
      'update' 'cert' 'logs' 'vault-edit' 'quit')"
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

Then replace `main()` with:

```bash
# Always restore cursor/colors, even on Ctrl-C mid-menu.
_restore_term() { tput cnorm 2>/dev/null || true; printf '%s' "${C_RESET:-}"; }
trap _restore_term EXIT INT

main() {
  cd "$SCRIPT_DIR"
  [[ -f ansible.cfg ]] || die "must be run from the project root (ansible.cfg not found)"
  [[ -f .vault_pass ]] || warn ".vault_pass not found — vault-backed commands will fail until you create it"
  if [[ $# -eq 0 ]]; then
    if [[ -t 0 && -t 1 ]]; then
      interactive_menu
    else
      printf 'Usage: npmctl <command>  (interactive menu needs a TTY)\n' >&2
      cmd_help >&2
      return 2
    fi
  else
    dispatch "$@"
  fi
}

main "$@"
```

Remove the old `main "$@"` call lower in the file if duplicated (there must be exactly one `main "$@"` at EOF).

- [ ] **Step 5: Run tests, verify pass**

Run: `bash tests/test_npmctl.sh`
Expected: PASS, `0 failed` (no-args piped → help + rc 2; NO_COLOR → no ANSI).

- [ ] **Step 6: Manual smoke of the TUI (interactive)**

Run: `./npmctl` in a real terminal. Expected: banner + arrow-navigable menu; selecting `quit` exits cleanly with cursor restored. (Ctrl-C also restores the cursor.)

- [ ] **Step 7: shellcheck + commit**

```bash
shellcheck npmctl
git add npmctl tests/test_npmctl.sh
git commit -m "feat(npmctl): interactive ANSI menu with TTY/NO_COLOR guards"
```

---

### Task 6: Docs + live acceptance

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add a README section** (match existing heading style; place after Architecture or near the Setup section):

```markdown
## Managing the cluster: `npmctl`

`./npmctl` is a self-contained management CLI (zero extra dependencies). Run it
with no arguments for an interactive menu, or pass a command directly:

    ./npmctl              # interactive menu
    ./npmctl status       # cluster / DRBD / VIP health
    ./npmctl deploy       # SAFE converge: drift-check + backup, then main.yml, then verify
    ./npmctl drift        # config drift check
    ./npmctl backup|verify|restore   # proxy-host snapshot / verify / restore
    ./npmctl update|cert  # rolling image update / TLS certs
    ./npmctl logs         # tail NPM container logs
    ./npmctl vault-edit ha_nodes     # edit secrets

`deploy` refuses to converge if `drift` detects repo↔live drift (override with
`--force`) and always snapshots proxy hosts first; pass `--yes` to skip the
confirmation prompt in automation.
```

- [ ] **Step 2: Run the full test harness once more**

Run: `bash tests/test_npmctl.sh`
Expected: PASS, `0 failed`.

- [ ] **Step 3: Live acceptance (read-only, controller)**

Run:
```bash
./npmctl status
./npmctl drift
```
Expected: `status` prints the real DRBD/pacemaker/VIP panel; `drift` exits 0 ("No drift"). Do NOT run `deploy`/`update` during acceptance.

- [ ] **Step 4: shellcheck + commit**

```bash
shellcheck npmctl
git add README.md
git commit -m "docs: document npmctl management CLI"
```

---

## Acceptance (full)

1. `bash tests/test_npmctl.sh` → all checks pass (`0 failed`).
2. `shellcheck npmctl` → clean.
3. `./npmctl` in a TTY → interactive menu works; cursor restored on quit/Ctrl-C.
4. `./npmctl status` → real health panel; `./npmctl drift` → exit 0.
5. `printf '' | ./npmctl` → prints help, exits 2 (no hang).

## Self-Review Notes

- **Spec coverage:** dual entry modes + dispatch → Task 1/5; all wrappers → Task 2; safety-gated deploy with `--force`/`--yes` semantics → Task 3; status/logs/vault-edit → Task 4; ANSI UI + TTY/NO_COLOR guards + cursor restore via an `EXIT`/`INT` trap (`_restore_term`) → Task 5; docs → Task 6; dry-run dependency-free tests → Tasks 1–5.
- **Placeholder scan:** every step has full code; the Task-3 note explicitly resolves the dry-run/`--force` observability with the final code form to use.
- **Name consistency:** `run`, `cmd_drift/backup/verify/restore/update/cert/main/deploy/status/logs/vault_edit`, `confirm_or_die`, `FORCE_YES`, `ui_menu`, `dispatch`, `interactive_menu` are used identically across tasks and the dispatch `case`.
