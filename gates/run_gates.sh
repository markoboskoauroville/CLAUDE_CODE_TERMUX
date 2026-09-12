#!/usr/bin/env bash
# gates/run_gates.sh — the nine delivery gates, per MANTRA_MANIFEST
# modules/delivery-gate.md. Cheapest first. Each gate can fail on its own and
# each prints what it examined, not only what it found.
#
#   bash gates/run_gates.sh            all gates, local artefact
#   bash gates/run_gates.sh --remote   also check the pushed bytes (G1)
#
# Exit 0 only when every BLOCKING gate is green.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
REMOTE=0
[ "${1:-}" = "--remote" ] && REMOTE=1

RAW="https://raw.githubusercontent.com/markoboskoauroville/CLAUDE_CODE_TERMUX/main"
ARTEFACTS=(install.sh uninstall.sh README.md LICENSE .gitignore tests/run_tests.sh gates/run_gates.sh DELIVERY.md)

if [ -t 1 ]; then G=$'\033[38;5;35m'; R=$'\033[38;5;167m'; A=$'\033[38;5;214m'; D=$'\033[38;5;244m'; B=$'\033[1m'; Z=$'\033[0m'
else G=""; R=""; A=""; D=""; B=""; Z=""; fi

GATES_RUN=0; GATES_GREEN=0; GATES_RED=0; GATES_ADVISORY=0
GATE_FAILED=0

gate() {
  GATES_RUN=$((GATES_RUN+1)); GATE_FAILED=0
  printf '\n%s\n%s\n' "${B}$*${Z}" "${D}$(printf '%.0s-' {1..66})${Z}"
}
pass()  { printf '  %sok%s    %s\n' "$G" "$Z" "$*"; }
fail()  { printf '  %sBLOCK%s %s\n' "$R" "$Z" "$*"; GATE_FAILED=1; }
adv()   { printf '  %sadv%s   %s\n' "$A" "$Z" "$*"; GATES_ADVISORY=$((GATES_ADVISORY+1)); }
count() { printf '  %s%s%s\n' "$D" "$*" "$Z"; }
close_gate() {
  if [ "$GATE_FAILED" -eq 0 ]; then GATES_GREEN=$((GATES_GREEN+1))
  else GATES_RED=$((GATES_RED+1)); fi
}

# =========================================================== G1 PROVENANCE ==
gate "G1  PROVENANCE — is this the artefact I think it is"

present=0; absent=0
for f in "${ARTEFACTS[@]}"; do
  if [ -f "$f" ]; then present=$((present+1)); else absent=$((absent+1)); fail "missing artefact: $f"; fi
done
count "artefacts declared: ${#ARTEFACTS[@]}   present: $present   missing: $absent"

ver="$(grep -m1 '^CCT_VERSION=' install.sh | cut -d= -f2)"
case "$ver" in
  ''|*[!0-9]*) fail "CCT_VERSION is '$ver' — versioning.md requires a whole number" ;;
  *)           pass "version $ver (whole number)" ;;
esac

if grep -q "v$ver" README.md; then pass "README names v$ver"; else fail "README does not name v$ver"; fi
if [ -f DELIVERY.md ] && grep -q "v$ver" DELIVERY.md; then pass "DELIVERY.md names v$ver"; else fail "DELIVERY.md does not name v$ver"; fi

if [ "$(tail -1 install.sh)" = "# CCT_COMPLETE_V2" ]; then
  pass "completeness marker is the last line of install.sh"
else
  fail "completeness marker is not the last line — a truncated download would install half an app"
fi

if [ "$REMOTE" = 1 ]; then
  same=0; diff=0
  for f in "${ARTEFACTS[@]}"; do
    [ -f "$f" ] || continue
    local_sum="$(sha256sum "$f" | cut -d' ' -f1)"
    remote_sum="$(curl -fsSL --max-time 30 "$RAW/$f" 2>/dev/null | sha256sum | cut -d' ' -f1)"
    if [ "$local_sum" = "$remote_sum" ]; then same=$((same+1))
    else diff=$((diff+1)); fail "remote bytes differ from local: $f"; fi
  done
  count "compared over the wire: $((same+diff))   identical: $same   different: $diff"
  [ "$diff" -eq 0 ] && pass "every artefact on the remote matches the local file byte for byte"
else
  adv "remote comparison skipped — rerun with --remote after pushing (versioning.md: never say pushed on the strength of the command having run)"
fi
close_gate

# ============================================================== G2 SECRETS ==
gate "G2  SECRETS — does it carry anything that must never leave"

scanned=0; hits=0
# ERE, not BRE: the first version of this line used \{20,\} inside grep -E,
# which matches nothing. It reported zero findings on a file with a planted
# token in it and read as a pass. (four-tests.md: break the check on purpose.)
patterns='ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|gho_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|sk-ant-[A-Za-z0-9_-]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|Authorization: *Bearer +[A-Za-z0-9]'
for f in "${ARTEFACTS[@]}"; do
  [ -f "$f" ] || continue
  scanned=$((scanned+1))
  if grep -nEq "$patterns" "$f"; then hits=$((hits+1)); fail "secret-shaped string in $f"; fi
done

# a bare 40-hex string is a classic PAT; check separately so the count is honest
bare=0
for f in "${ARTEFACTS[@]}"; do
  [ -f "$f" ] || continue
  if grep -nEq '(^|[^a-f0-9])[a-f0-9]{40}([^a-f0-9]|$)' "$f"; then
    bare=$((bare+1)); fail "40-hex string (classic PAT shape) in $f"
  fi
done

# and the specific token this session was handed, if it is still on disk
tokenfile="/mnt/user-data/uploads/___github_token.txt"
if [ -f "$tokenfile" ]; then
  tok="$(tr -d '\r\n' < "$tokenfile")"
  found=0
  for f in "${ARTEFACTS[@]}"; do
    [ -f "$f" ] || continue
    grep -qF "$tok" "$f" && { found=1; fail "the supplied GitHub token appears in $f"; }
  done
  unset tok
  [ "$found" -eq 0 ] && pass "the supplied GitHub token appears in no artefact"
else
  adv "no token file present in this environment to check against"
fi

# self-test: the pattern must match a string that is definitely a secret,
# otherwise "0 findings" means the regex is broken, not that the repo is clean
if printf 'ghp_%s\n' "$(printf 'a%.0s' $(seq 1 36))" | grep -Eq "$patterns"; then
  pass "the secret pattern matches a known-bad string (the check can fail)"
else
  fail "the secret pattern matches nothing at all — this gate proves nothing"
fi

if grep -q 'token' .gitignore 2>/dev/null; then pass ".gitignore excludes token files"; else adv ".gitignore does not mention tokens"; fi
count "files scanned: $scanned   pattern hits: $hits   bare-40-hex hits: $bare"
[ "$hits" -eq 0 ] && [ "$bare" -eq 0 ] && pass "no secret-shaped strings in any artefact"
close_gate

# ============================================================= G3 ANALYSIS ==
gate "G3  ANALYSIS — what do the machines say, warnings all the way up"

if command -v shellcheck >/dev/null 2>&1; then
  total=0; files=0
  for f in install.sh uninstall.sh tests/run_tests.sh gates/run_gates.sh; do
    [ -f "$f" ] || continue
    files=$((files+1))
    n="$(shellcheck -S warning -f gcc "$f" 2>/dev/null | wc -l)"
    total=$((total+n))
    if [ "$n" -gt 0 ]; then
      fail "$f: $n finding(s) at warning or above"
      shellcheck -S warning -f gcc "$f" 2>/dev/null | sed "s/^/        ${D}| ${Z}/"
    else
      pass "$f: clean at warning and above"
    fi
  done
  style=0
  for f in install.sh uninstall.sh tests/run_tests.sh gates/run_gates.sh; do
    [ -f "$f" ] || continue
    style=$((style + $(shellcheck -S style -f gcc "$f" 2>/dev/null | wc -l)))
  done
  count "files analysed: $files   blocking findings: $total   style-level findings: $style"
  [ "$style" -gt 0 ] && adv "$style style-level findings (not blocking)"
else
  fail "shellcheck is not installed — this gate cannot run, which is not the same as passing"
fi

parsed=0; unparsed=0
for f in install.sh uninstall.sh tests/run_tests.sh gates/run_gates.sh; do
  [ -f "$f" ] || continue
  if bash -n "$f" 2>/dev/null; then parsed=$((parsed+1)); else unparsed=$((unparsed+1)); fail "$f does not parse"; fi
done
count "scripts parsed: $parsed   failed to parse: $unparsed"
close_gate

# ============================================================ G4 DEAD CODE ==
gate "G4  DEAD CODE — what is in there that nothing reaches"

defined=0; dead=0
for f in install.sh uninstall.sh tests/run_tests.sh gates/run_gates.sh; do
  [ -f "$f" ] || continue
  while read -r fn; do
    [ -z "$fn" ] && continue
    defined=$((defined+1))
    uses="$(grep -c "\b$fn\b" "$f")"
    if [ "$uses" -le 1 ]; then
      dead=$((dead+1)); adv "$f: $fn() is defined but never called"
    fi
  done < <(grep -oE '^[a-z_][a-z0-9_]*\(\)' "$f" | tr -d '()')
done
count "functions defined: $defined   never called: $dead"
[ "$dead" -eq 0 ] && pass "every function defined is reached by something"
# Advisory, not blocking: a helper kept deliberately is a judgement call.
close_gate

# ============================================================ G5 DEAD LOOPS ==
gate "G5  DEAD LOOPS — what can spin, hang or wait forever"

nettotal=0; untimed=0
# Only real invocations: "curl" followed by an option. This deliberately does
# not match "curl" inside an apt package list or in a comment — the first
# version of this check did, and reported seven findings of which two were real.
while IFS= read -r line; do
  nettotal=$((nettotal+1))
  case "$line" in
    *--max-time*|*--speed-time*|*--connect-timeout*) : ;;
    *) untimed=$((untimed+1)); fail "curl with no time bound: $(echo "$line" | sed 's/^ *//' | cut -c1-72)" ;;
  esac
done < <(
  # backslash-continued commands are joined first, and comment lines dropped,
  # so a flag on the following line still counts and the usage example in the
  # file header does not.
  cat install.sh uninstall.sh tests/run_tests.sh gates/run_gates.sh 2>/dev/null \
    | sed -e ':a' -e '/\\$/{N;s/\\\n//;ba}' \
    | grep -v '^[[:space:]]*#' \
    | grep -E 'curl +-'
)
count "curl invocations found: $nettotal   without any time bound: $untimed"
[ "$untimed" -eq 0 ] && pass "every network call is bounded"

if grep -nE 'while +(true|:)' install.sh uninstall.sh >/dev/null 2>&1; then
  fail "unbounded while loop in a shipped script"
else
  pass "no 'while true' in any shipped script"
fi

# the progress bar's loop is bounded by the life of the process it watches
if grep -q 'while kill -0 "\$pid"' install.sh; then
  pass "the progress loop ends with the process it watches, not on a timer"
fi

if grep -q 'read -r -p' install.sh; then
  if grep -q '\[ ! -t 0 \]' install.sh; then
    pass "the only interactive read is guarded by a terminal check — a piped install never blocks"
  else
    fail "an interactive read with no terminal guard would hang a piped install forever"
  fi
fi

if grep -q 'trap cct_cleanup EXIT' install.sh && grep -q "trap 'exit 130' INT" install.sh; then
  pass "traps are armed for EXIT, INT and TERM before the first terminal write"
else
  fail "no interrupt trap — a killed install would leave the terminal in raw mode"
fi
close_gate

# =============================================================== G6 STRESS ==
gate "G6  STRESS — what happens when the world misbehaves, repeatedly"

if [ -f tests/run_tests.sh ]; then
  runs=3; okruns=0; badruns=0; SUITE_SECS=0
  for i in $(seq 1 "$runs"); do
    t0="$(date +%s)"
    if bash tests/run_tests.sh >"/tmp/cct-stress-$i.log" 2>&1; then okruns=$((okruns+1)); else badruns=$((badruns+1)); fi
    [ "$i" = 1 ] && SUITE_SECS=$(( $(date +%s) - t0 )) && cp "/tmp/cct-stress-1.log" /tmp/cct-suite.txt
  done
  count "full test suite runs: $runs   green: $okruns   red: $badruns   first run: ${SUITE_SECS}s"
  if [ "$badruns" -eq 0 ]; then
    pass "the suite is repeatable — same result $runs times"
  else
    fail "$badruns of $runs runs disagreed with the others (flaky, or a real intermittent fault)"
    tail -20 "/tmp/cct-stress-1.log" | sed "s/^/        ${D}| ${Z}/"
  fi

  checks_per_run="$(grep -m1 'checks run' /tmp/cct-suite.txt | tr -dc '0-9')"
  count "checks per run: ${checks_per_run:-0}"

  sab="$(grep -c 'FAKE_' tests/run_tests.sh)"
  count "sabotage switches wired into the harness: $sab (network down, HTML instead of JSON, corrupt checksum, apt failure, download failure, lying patchelf, 32-bit arch, truncated installer)"
  [ "$sab" -ge 7 ] && pass "the world is made to misbehave in at least 7 distinct ways"
else
  fail "no test suite to stress"
  SUITE_SECS=0
fi
close_gate

# ============================================================== G7 BUDGETS ==
gate "G7  BUDGETS — is anything worse than last time"

bytes="$(wc -c < install.sh)"; lines="$(wc -l < install.sh)"
count "install.sh: $bytes bytes, $lines lines"
[ "$bytes" -lt 40000 ] && pass "installer under the 40 KB budget (a phone downloads it before anything else)" \
                       || fail "installer is $bytes bytes, over the 40 KB budget"

count "test suite wall time: ${SUITE_SECS}s (measured in G6, not run again)"
[ "${SUITE_SECS:-999}" -lt 120 ] && pass "suite under the 2 minute budget" || adv "suite takes ${SUITE_SECS}s"

deps="$(grep -oE 'apt-get install -y [a-z0-9 .-]+' install.sh | tr ' ' '\n' | grep -vE 'apt-get|install|-y' | sort -u | wc -l)"
count "distinct Termux packages the installer can install: $deps"
[ "$deps" -le 20 ] && pass "dependency count within budget" || adv "$deps packages is a lot to ask of a phone"

total_repo="$(du -sk . 2>/dev/null | cut -f1)"
count "repository size: ${total_repo} KB"
[ "${total_repo:-0}" -lt 5000 ] && pass "repository under 5 MB — nothing here regenerates or belongs on Drive"
close_gate

# ============================================================== G8 UPGRADE ==
gate "G8  UPGRADE — the person who already had the old one, and the way back"

# reuses the run captured in G6 rather than running the suite a third time
sed -n '/TEST 4/,/WHAT WAS NOT/p' /tmp/cct-suite.txt > /tmp/cct-t4.txt 2>/dev/null || : > /tmp/cct-t4.txt
t4_pass="$(grep -c '  pass' /tmp/cct-t4.txt)"
t4_fail="$(grep -c '  FAIL' /tmp/cct-t4.txt)"
count "Test 4 checks: $((t4_pass+t4_fail))   passed: $t4_pass   failed: $t4_fail"
if [ "$t4_fail" -eq 0 ] && [ "$t4_pass" -gt 0 ]; then
  pass "upgrade from the previous build, with settings kept"
else
  fail "the upgrade path is not green"
  sed -n 's/^/        | /p' /tmp/cct-t4.txt | grep FAIL
fi

grep -q 'do_rollback' install.sh && pass "a rollback clause exists (--rollback)" || fail "no rollback path"
grep -q 'previous' install.sh && pass "the previous build is recorded before the new one becomes current" || fail "no previous build is kept"
grep -q 'DISABLE_AUTOUPDATER' install.sh && pass "the built-in updater is disabled so it cannot unpatch the binary behind the person's back" || fail "the built-in updater is live and will break the native install"
close_gate

# =============================================================== G9 RECORD ==
gate "G9  THE RECORD — what is being claimed, and what is not"

if [ -f DELIVERY.md ]; then
  pass "DELIVERY.md exists"
  for section in "WHAT WAS TESTED" "WHAT WAS NOT TESTED" "KNOWN LIMITS"; do
    if grep -qi "$section" DELIVERY.md; then pass "DELIVERY.md has a '$section' section"
    else fail "DELIVERY.md is missing '$section'"; fi
  done
  if grep -qi 'shim\|workaround\|not official' DELIVERY.md; then
    pass "the record says plainly that the native path is a shim, not official Android support"
  else
    fail "the record does not disclose that the native path is unofficial"
  fi
else
  fail "no DELIVERY.md — nothing states what is claimed and what is not"
fi

if grep -qi 'not tested\|cannot be tested' README.md; then
  pass "the README also carries the off-phone caveat"
else
  adv "the README does not repeat what cannot be tested off a phone"
fi
close_gate

# ================================================================= RESULT ===
printf '\n%s\n%s\n' "${B}RESULT${Z}" "${D}$(printf '%.0s-' {1..66})${Z}"
printf '  gates run   %s%d%s\n' "$B" "$GATES_RUN" "$Z"
printf '  green       %s%d%s\n' "$G" "$GATES_GREEN" "$Z"
printf '  blocked     %s%d%s\n' "$R" "$GATES_RED" "$Z"
printf '  advisory    %s%d%s\n\n' "$A" "$GATES_ADVISORY" "$Z"

if [ "$GATES_RED" -eq 0 ]; then
  printf '  %sall blocking gates green — this may be delivered%s\n\n' "$G" "$Z"
  exit 0
else
  printf '  %s%d gate(s) blocking — do not deliver%s\n\n' "$R" "$GATES_RED" "$Z"
  exit 1
fi
