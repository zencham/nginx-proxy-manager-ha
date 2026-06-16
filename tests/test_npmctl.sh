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

echo "== done: $PASS passed, $FAIL failed =="
[[ "$FAIL" -eq 0 ]]
