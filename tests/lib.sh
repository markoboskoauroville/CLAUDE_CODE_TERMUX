#!/usr/bin/env bash
# Shared harness. Every test prints a count, because "0 findings" and
# "the check never ran" look identical from outside.

PASS=0; FAIL=0; SKIP=0
FAILED_NAMES=()

if [ -t 1 ]; then
  GREEN=$'\033[38;5;114m'; RED=$'\033[38;5;174m'; AMBER=$'\033[38;5;214m'
  DIM=$'\033[2m'; OFF=$'\033[0m'
else
  GREEN=""; RED=""; AMBER=""; DIM=""; OFF=""
fi

t_head() { printf '\n%s== %s ==%s\n' "$AMBER" "$1" "$OFF"; }

pass() { PASS=$((PASS+1)); printf '  %sPASS%s  %s\n' "$GREEN" "$OFF" "$1"; }
fail() { FAIL=$((FAIL+1)); FAILED_NAMES+=("$1"); printf '  %sFAIL%s  %s\n        %s\n' "$RED" "$OFF" "$1" "${2:-}"; }
skip() { SKIP=$((SKIP+1)); printf '  %sSKIP%s  %s  %s%s%s\n' "$DIM" "$OFF" "$1" "$DIM" "${2:-}" "$OFF"; }

# assert_eq NAME EXPECTED ACTUAL
assert_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected [$2] got [$3]"; fi
}
# assert_ok NAME  -- then the command
assert_ok() {
  local name="$1"; shift
  local out rc
  out=$("$@" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then pass "$name"; else fail "$name" "exit $rc: $out"; fi
}
assert_fails() {
  local name="$1"; shift
  local out rc
  out=$("$@" 2>&1); rc=$?
  if [ "$rc" -ne 0 ]; then pass "$name"; else fail "$name" "expected a non-zero exit, got 0: $out"; fi
}
assert_contains() {
  case "$3" in
    *"$2"*) pass "$1" ;;
    *) fail "$1" "[$3] does not contain [$2]" ;;
  esac
}
assert_not_contains() {
  case "$3" in
    *"$2"*) fail "$1" "[$3] contains [$2] and should not" ;;
    *) pass "$1" ;;
  esac
}

t_summary() {
  printf '\n%s%s: %d passed, %d failed, %d skipped%s\n' \
    "$AMBER" "$1" "$PASS" "$FAIL" "$SKIP" "$OFF"
  if [ "$FAIL" -gt 0 ]; then
    printf '  failed: %s\n' "${FAILED_NAMES[*]}"
    return 1
  fi
  return 0
}
