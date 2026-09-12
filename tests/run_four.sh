#!/usr/bin/env bash
# Runs the four tests in order and prints the counts.
#
#   bash tests/run_four.sh          all four
#   bash tests/run_four.sh 1 3      only those
#
# Test 2 downloads about 230 MB from Anthropic's CDN. The others are local.

HERE="$(cd "$(dirname "$0")" && pwd)"
WANT="${*:-1 2 3 4}"
declare -A NAME=(
  [1]="the mechanism, alone"
  [2]="the real CDN and binary"
  [3]="the ugly cases"
  [4]="the upgrade and the way back"
)
declare -A FILE=(
  [1]="test1_mechanism.sh"
  [2]="test2_real.sh"
  [3]="test3_ugly.sh"
  [4]="test4_upgrade.sh"
)

RESULTS=(); WORST=0
for n in $WANT; do
  printf '\n--- TEST %s — %s ---\n' "$n" "${NAME[$n]}"
  bash "$HERE/${FILE[$n]}"
  rc=$?
  LINE="$(bash -c ':' ; true)"
  RESULTS+=("TEST $n exit $rc")
  [ "$rc" -ne 0 ] && WORST=1
done

printf '\n=== summary ===\n'
for r in "${RESULTS[@]}"; do printf '  %s\n' "$r"; done
printf '\nA fix is a change, so when one test fails, run all four again. Four\ngreen results only mean something when they describe the same build.\n\n'
exit "$WORST"
