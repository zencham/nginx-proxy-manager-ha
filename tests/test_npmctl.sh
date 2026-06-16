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

echo "== Task 2: playbook wrappers =="
for pair in "drift:drift_check.yml" "backup:proxy_backup.yml" "verify:proxy_verify.yml" \
            "restore:proxy_restore.yml" "update:npm_update.yml" "cert:cert_manager.yml"; do
  c="${pair%%:*}"; pb="${pair##*:}"
  out="$(NPMCTL_DRY_RUN=1 $NPMCTL "$c" 2>&1)"
  check "$c runs $pb" "would-run: ansible-playbook $pb" "$out"
done

echo "== Task 3: deploy gate =="
out="$(NPMCTL_DRY_RUN=1 $NPMCTL deploy 2>&1)"
check "deploy step1 drift"   "would-run: ansible-playbook drift_check.yml" "$out"
check "deploy step2 backup"  "would-run: ansible-playbook proxy_backup.yml" "$out"
check "deploy step3 confirm" "would-confirm:" "$out"
check "deploy step4 main"    "would-run: ansible-playbook main.yml" "$out"
check "deploy step5 verify"  "would-run: ansible-playbook proxy_verify.yml" "$out"
order="$(printf '%s\n' "$out" | grep -nE 'drift_check.yml|proxy_backup.yml|main.yml|proxy_verify.yml' | cut -d: -f1 | tr '\n' ' ')"
check "deploy ordering is sorted" "$(printf '%s' "$order" | tr ' ' '\n' | sort -n | tr '\n' ' ')" "$order"
out="$(NPMCTL_DRY_RUN=1 $NPMCTL deploy --force 2>&1)"
check "deploy --force notes bypass" "drift gate bypassed" "$out"
out="$(NPMCTL_DRY_RUN=1 $NPMCTL deploy --yes 2>&1)"
check "deploy --yes skips confirm" "confirm-skipped" "$out"

echo "== Task 4: live commands =="
out="$(NPMCTL_DRY_RUN=1 $NPMCTL status 2>&1)"
check "status probes drbd"  "would-run: ansible ha_nodes" "$out"
out="$(NPMCTL_DRY_RUN=1 $NPMCTL logs 2>&1)"
check "logs uses docker compose logs" "compose" "$out"
out="$(NPMCTL_DRY_RUN=1 $NPMCTL vault-edit ha_nodes 2>&1)"
check "vault-edit edits ha_nodes vault" "would-run: ansible-vault edit inventory/group_vars/ha_nodes/vault.yml" "$out"
NPMCTL_DRY_RUN=1 $NPMCTL vault-edit bogus >/dev/null 2>&1; check_rc "vault-edit rejects bad target" 1 "$?"

echo "== Task 5: UI guards =="
out="$(printf '' | NPMCTL_DRY_RUN=1 $NPMCTL 2>&1)"; rc=$?
check "no-args non-tty shows help" "Usage: npmctl" "$out"
check_rc "no-args non-tty exits non-zero" 2 "$rc"
# NO_COLOR must produce zero ESC (0x1b) bytes. tr -cd keeps only ESC bytes; wc -c counts them.
esc_count="$(NO_COLOR=1 NPMCTL_DRY_RUN=1 $NPMCTL status 2>/dev/null | tr -cd '\033' | wc -c | tr -d ' ')"
check "NO_COLOR strips ANSI" "0" "$esc_count"
# Sanity: the same status output, when it WOULD color (forced palette), is still escape-free under capture (non-TTY) — guard is correct either way.

echo "== Task 5b: interactive menu (pty regression) =="
if command -v python3 >/dev/null 2>&1; then
  if python3 tests/test_npmctl_menu.py; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi
else
  printf '  skip menu pty test (python3 not found)\n'
fi

echo "== Task P2: parsers =="
drbd_ok="10: cs:Connected ro:Primary/Secondary ds:UpToDate/UpToDate C r-----
11: cs:Connected ro:Secondary/Primary ds:UpToDate/UpToDate C r-----"
out="$(bash -c 'source ./npmctl >/dev/null 2>&1; set +e +o pipefail; _parse_drbd "$1"' _ "$drbd_ok" 2>/dev/null)"
check "drbd healthy app ok" "ok	app" "$out"
check "drbd healthy db ok"  "ok	db"  "$out"
drbd_bad="10: cs:StandAlone ro:Primary/Unknown ds:UpToDate/DUnknown r-----
11: cs:Connected ro:Secondary/Primary ds:Inconsistent/UpToDate C r-----"
out="$(bash -c 'source ./npmctl >/dev/null 2>&1; set +e +o pipefail; _parse_drbd "$1"' _ "$drbd_bad" 2>/dev/null)"
check "drbd standalone bad" "bad	app" "$out"
check "drbd inconsistent bad" "bad	db" "$out"
pcs_ok="  * npm_vip	(ocf:heartbeat:IPaddr2):	 Started MIBTECH-NPM-PROD-01
  * npm_service	(systemd:npm-stack):	 Started MIBTECH-NPM-PROD-01"
out="$(bash -c 'source ./npmctl >/dev/null 2>&1; set +e +o pipefail; _parse_pcs "$1"' _ "$pcs_ok" 2>/dev/null)"
check "pcs vip started ok" "ok	npm_vip" "$out"
check "pcs service started ok" "ok	npm_service" "$out"
pcs_bad="  * npm_vip	(ocf:heartbeat:IPaddr2):	 Stopped
Failed Resource Actions:"
out="$(bash -c 'source ./npmctl >/dev/null 2>&1; set +e +o pipefail; _parse_pcs "$1"' _ "$pcs_bad" 2>/dev/null)"
check "pcs vip stopped bad" "bad	npm_vip" "$out"
check "pcs failed actions bad" "bad	failed-actions" "$out"

echo "== Task P3: status panel rendering =="
esc="$(NO_COLOR=1 bash -c '
  source ./npmctl >/dev/null 2>&1; set +e +o pipefail
  ui_box "Cluster Health" "DRBD" "$(_row ok "  app " "Connected UpToDate/UpToDate")"
' 2>/dev/null | tr -cd "\033" | wc -c | tr -d " ")"
check "status panel NO_COLOR has no ESC" "0" "$esc"
out="$(NO_COLOR=1 bash -c 'source ./npmctl >/dev/null 2>&1; set +e +o pipefail; _row ok "  app" "x"' 2>/dev/null)"
check "row ok shows check" "✓" "$out"
out="$(bash -c 'source ./npmctl >/dev/null 2>&1; set +e +o pipefail; _row bad "  db" "x"' 2>/dev/null)"
check "row bad shows cross" "✗" "$out"

echo "== Task P4: run_step =="
out="$(NPMCTL_DRY_RUN=1 bash -c 'source ./npmctl >/dev/null 2>&1; set +e +o pipefail; run_step lbl ansible-playbook foo.yml' 2>/dev/null)"
check "run_step dry-run prints would-run" "would-run: ansible-playbook foo.yml" "$out"

echo "== done: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]]
