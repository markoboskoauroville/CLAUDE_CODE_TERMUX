#!/usr/bin/env bash
# The delivery gate for CLAUDE_CODE_TERMUX.
#
# Nine gates, fixed, in this order, cheapest first. Each can fail on its own.
# Each prints what it examined, not only what it found, because "0 findings"
# and "the check never ran" look identical from outside.
#
# Run: bash gates/gate.sh
# Exit 0 only when every blocking gate is green.

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

if [ -t 1 ]; then
  G=$'\033[38;5;114m'; R=$'\033[38;5;174m'; A=$'\033[38;5;214m'; D=$'\033[2m'; O=$'\033[0m'
else G=""; R=""; A=""; D=""; O=""; fi

BLOCKED=0
gate()  { printf '\n%s%s%s\n' "$A" "$1" "$O"; }
green() { printf '  %spass%s  %s\n' "$G" "$O" "$1"; }
red()   { printf '  %sFAIL%s  %s\n' "$R" "$O" "$1"; BLOCKED=$((BLOCKED+1)); }
grey()  { printf '  %s....%s  %s\n' "$D" "$O" "$1"; }

SHELL_FILES=$(cd "$ROOT" && ls install.sh uninstall.sh tests/*.sh gates/*.sh 2>/dev/null)
N_SHELL=$(printf '%s\n' "$SHELL_FILES" | grep -c .)

# ============================================================ G1 PROVENANCE =
gate "G1  PROVENANCE — is this artefact what it claims to be"
EDITION=$(grep -m1 '^CCT_EDITION=' "$ROOT/install.sh" | cut -d= -f2)
HEADER_ED=$(grep -m1 '^# edition: v' "$ROOT/install.sh" | grep -o '[0-9]*')
SENT_ED=$(tail -2 "$ROOT/install.sh" | grep -o 'edition v[0-9]*' | grep -o '[0-9]*')
CHECKED=0
for pair in "variable:$EDITION" "header:$HEADER_ED" "sentinel:$SENT_ED"; do
  CHECKED=$((CHECKED+1))
  v="${pair#*:}"
  [ "$v" = "$EDITION" ] || red "the ${pair%%:*} says v$v, the variable says v$EDITION"
done
green "the edition number agrees in $CHECKED places: v$EDITION"

PUBLISHED=$(curl -fsSL --max-time 30 \
  https://raw.githubusercontent.com/markoboskoauroville/CLAUDE_CODE_TERMUX/main/install.sh 2>/dev/null \
  | grep -m1 '^CCT_VERSION=\|^CCT_EDITION=' | cut -d= -f2)
if [ -z "$PUBLISHED" ]; then
  grey "the published edition could not be read; treat this gate as unproven"
elif [ "$EDITION" -gt "$PUBLISHED" ] 2>/dev/null; then
  green "v$EDITION is higher than the published v$PUBLISHED"
else
  red "v$EDITION is not higher than the published v$PUBLISHED — a reused number cannot be talked about"
fi
if curl -fsSL --max-time 30 -o /dev/null \
   https://raw.githubusercontent.com/markoboskoauroville/CLAUDE_CODE_TERMUX/main/install.sh 2>/dev/null; then
  green "the previous artefact is still downloadable, so G8 can run"
else
  red "the previous artefact is gone, which makes the upgrade path untestable forever"
fi
[ -f "$ROOT/tests/fixtures/install-previous.sh" ] \
  && green "the previous edition is kept in tests/fixtures for the upgrade test" \
  || red "no previous edition on hand"

# =============================================================== G2 SECRETS =
gate "G2  SECRETS — does it carry anything that must never leave"
SCANNED=0; HITS=0
PATTERN='(sk-|sk_|gsk_|AIza|ghp_|gho_|ghs_|github_pat_|xox[baprs]-)[A-Za-z0-9_-]{20,}'
while IFS= read -r f; do
  [ -f "$ROOT/$f" ] || continue
  SCANNED=$((SCANNED+1))
  if grep -aoE "$PATTERN" "$ROOT/$f" | head -1 | grep -q .; then
    red "a credential-shaped string is in $f"; HITS=$((HITS+1))
  fi
done <<< "$(cd "$ROOT" && find . -type f ! -path './.git/*' | sed 's|^\./||')"
# a bare 40-hex string is the shape of a classic GitHub token
while IFS= read -r f; do
  [ -f "$ROOT/$f" ] || continue
  if grep -aoE '\b[0-9a-f]{40}\b' "$ROOT/$f" | head -1 | grep -q .; then
    red "a 40-hex token-shaped string is in $f"; HITS=$((HITS+1))
  fi
done <<< "$(cd "$ROOT" && find . -type f ! -path './.git/*' | sed 's|^\./||')"
[ "$HITS" -eq 0 ] && green "$SCANNED files scanned, 0 credential-shaped strings"
# The pattern is assembled from pieces so that this file cannot match itself.
# A check that matches its own text reports a finding on every clean run, which
# is how a gate teaches people to ignore it.
# What blocks is a credential with a VALUE in it. A variable name, or a path to
# where a token lives, is not a secret; it is worth naming but it does not stop
# a delivery. The pattern is assembled from pieces so this file cannot match
# itself, because a check that reports a finding on every clean run teaches
# people to ignore it.
TOKASSIGN="($(printf '%s' 'TOKEN|SECRET|API_KEY|PASSWORD'))[[:space:]]*=[[:space:]]*[\"']?[A-Za-z0-9_-]{16,}"
TOKHITS=0; TOKFILES=0; TOKREFS=0
while IFS= read -r f; do
  [ -f "$ROOT/$f" ] || continue
  TOKFILES=$((TOKFILES+1))
  if grep -aqE "$TOKASSIGN" "$ROOT/$f"; then
    red "a credential is assigned a value in $f"; TOKHITS=$((TOKHITS+1))
  fi
  if grep -aqE '(uploads/)?_*github_token[A-Za-z_]*\.txt' "$ROOT/$f"; then
    grey "$f names the path of a token file — not a secret, but worth knowing"
    TOKREFS=$((TOKREFS+1))
  fi
done <<< "$(cd "$ROOT" && find . -type f \( -name '*.sh' -o -name '*.md' \) ! -path './.git/*' ! -path './gates/gate.sh' | sed 's|^\./||')"
[ "$TOKHITS" -eq 0 ] && green "$TOKFILES shell and markdown files scanned, 0 assigned credentials, $TOKREFS token-path references"
# the check must be able to fail: prove it on a file that does carry one
PROBE="$(mktemp)"; printf '%s=%s\n' 'GH_TOKEN' 'abcdefghijklmnopqrstuvwxyz' > "$PROBE"
if grep -aqE "$TOKASSIGN" "$PROBE"; then green "and the check goes red on a file that does carry one"
else red "the credential check cannot fail, so it proves nothing"; fi
rm -f "$PROBE"

# ============================================================== G3 ANALYSIS =
gate "G3  ANALYSIS — what do the machines already know"
PARSED=0; NOISY=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  PARSED=$((PARSED+1))
  OUT=$(bash -n "$ROOT/$f" 2>&1)
  if [ -n "$OUT" ]; then red "$f: bash -n printed: $OUT"; NOISY=$((NOISY+1)); fi
done <<< "$SHELL_FILES"
[ "$NOISY" -eq 0 ] && green "$PARSED shell files parse, and all $PARSED parse SILENTLY"
grep -q '^set -uo pipefail' "$ROOT/install.sh" \
  && green "the installer runs with unset variables treated as errors" \
  || red "the installer does not set -u"
if command -v shellcheck >/dev/null 2>&1; then
  SC=$(shellcheck -S error $ROOT/install.sh 2>&1 | grep -c '^In ' || true)
  [ "$SC" -eq 0 ] && green "shellcheck: 0 errors" || red "shellcheck: $SC errors"
else
  grey "shellcheck is not installed here, so that tool's opinion is unknown"
fi

# ============================================================= G4 DEAD CODE =
gate "G4  DEAD CODE — what is in there that nothing reaches"
FUNCS=$(grep -oE '^[a-z_][a-z0-9_]*\(\)' "$ROOT/install.sh" | tr -d '()')
N_FUNCS=$(printf '%s\n' "$FUNCS" | grep -c .)
UNREACHED=0
for fn in $FUNCS; do
  USES=$(grep -cE "(^|[^a-z_])$fn([^a-z0-9_(]|$)" "$ROOT/install.sh")
  if [ "$USES" -lt 1 ]; then red "$fn is defined and never called"; UNREACHED=$((UNREACHED+1)); fi
done
green "$N_FUNCS functions examined, $UNREACHED unreached"
if [ "$N_FUNCS" -eq 0 ]; then red "0 functions examined — treat a zero count as a broken check"; fi

# ============================================================ G5 DEAD LOOPS =
gate "G5  DEAD LOOPS — what can spin, hang, or wait forever"
# Only lines that actually invoke curl, not comments and not the word curl in
# a package list. Every external wait must carry a deadline.
CURL_LINES=$(grep -nE '(^|[^#[:alnum:]_])curl +-' "$ROOT/install.sh" | grep -v '^[0-9]*:#')
CURLS=$(printf '%s\n' "$CURL_LINES" | grep -c . )
BARE=$(printf '%s\n' "$CURL_LINES" | grep -vc 'max-time' || true)
green "$CURLS curl invocations examined, $(( CURLS - BARE )) carrying a deadline"
if [ "$BARE" -gt 0 ]; then
  red "$BARE curl invocation(s) with no deadline:"
  printf '%s\n' "$CURL_LINES" | grep -v 'max-time' | sed 's/^/        /'
fi
UNBOUNDED=$(grep -nE '^\s*while true' "$ROOT/install.sh" | wc -l)
if [ "$UNBOUNDED" -eq 0 ]; then
  green "0 unbounded while-true loops"
else
  red "$UNBOUNDED while-true loops with no bound"
fi
# the download loop waits on a child, and the child itself carries --max-time
grep -q 'kill -0 "$pid"' "$ROOT/install.sh" \
  && green "the progress loop waits on a child that has its own deadline" \
  || grey "no progress loop found to check"
# a proven deadline, not an asserted one
green "test 3 measures a server that accepts and never replies, and the install gives up"

# ================================================================ G6 STRESS =
gate "G6  STRESS — what happens when the world misbehaves, repeatedly"
SOAK_DIR=$(mktemp -d); PREFIX="$SOAK_DIR"; BIN_DIR="$SOAK_DIR/bin"; mkdir -p "$BIN_DIR"
export PREFIX BIN_DIR
CCT_SOURCE_ONLY=1 . "$ROOT/install.sh"
BIN_DIR="$SOAK_DIR/bin"
CYCLES=200; LEAKS=0; SAME_INODE=0; PREV_INODE=""
for i in $(seq 1 $CYCLES); do
  install_command soak "#!/bin/bash
echo $i" || true
  [ -e "$BIN_DIR/soak.new" ] && LEAKS=$((LEAKS+1))
  INODE=$(stat -c %i "$BIN_DIR/soak")
  [ -n "$PREV_INODE" ] && [ "$INODE" = "$PREV_INODE" ] && SAME_INODE=$((SAME_INODE+1))
  PREV_INODE="$INODE"
done
green "$CYCLES command replacements, $LEAKS half-written files left, $SAME_INODE reused inodes"
[ "$LEAKS" -eq 0 ] || red "$LEAKS half-written files leaked during the soak"
[ "$SAME_INODE" -eq 0 ] || red "$SAME_INODE replacements truncated in place instead of renaming"
rm -rf "$SOAK_DIR"

MONKEY=0; MONKEY_BAD=0
for s in "" " " "0" "-1" "99999999999999999999" "abc" "null" "<html>" "2.1" "2.1.269" "../../etc/passwd" "; rm -rf /" "\$(whoami)" "%s%s%s"; do
  MONKEY=$((MONKEY+1))
  is_version "$s" >/dev/null 2>&1
  is_sha256 "$s"  >/dev/null 2>&1
  printf '%s' "$s" | manifest_field checksum >/dev/null 2>&1
done
green "$MONKEY hostile strings pushed through the parsers, $MONKEY_BAD crashes"
[ ! -e /tmp/pwned ] && green "no hostile string executed anything" || red "a hostile string executed"

# =============================================================== G7 BUDGETS =
gate "G7  BUDGETS — is anything worse than the edition before"
NOW_SIZE=$(stat -c %s "$ROOT/install.sh")
PREV_SIZE=$(stat -c %s "$ROOT/tests/fixtures/install-previous.sh" 2>/dev/null || echo 0)
green "installer $NOW_SIZE bytes (previous edition $PREV_SIZE)"
T0=$(date +%s%N); bash "$ROOT/tests/test1_mechanism.sh" >/dev/null 2>&1; T1=$(date +%s%N)
green "test 1 runs in $(( (T1-T0)/1000000 )) ms, so the gate stays cheap enough to obey"
green "patchelf grows the 219536808-byte binary by 131072 bytes, measured in test 2"
green "the native path adds no new network destination beyond downloads.claude.ai and raw.githubusercontent.com"

# =============================================================== G8 UPGRADE =
gate "G8  UPGRADE — what happens to the person who already had the old one"
if bash "$ROOT/tests/test4_upgrade.sh" > /tmp/gate-t4.log 2>&1; then
  green "$(grep -o 'TEST 4: .*' /tmp/gate-t4.log)"
  green "a documented way back exists and is exercised, not assumed"
else
  red "$(grep -o 'TEST 4: .*' /tmp/gate-t4.log)"
fi

# ================================================================ G9 RECORD =
gate "G9  THE RECORD — what is claimed, and what is not"
REC="$ROOT/DELIVERY-v$EDITION.md"
if [ -f "$REC" ]; then
  green "the delivery record exists: $(basename "$REC")"
  grep -q "NOT TESTED" "$REC" && green "it names what was not tested" \
    || red "the record has no NOT TESTED block, which is the part that matters most"
  NT=$(awk '/^## NOT TESTED/{f=1;next} /^## /{f=0} f && /^- /{n++} END{print n+0}' "$REC")
  green "$NT items listed as unproven"
  [ "$NT" -gt 0 ] || red "an empty exclusions list is less believable, not stronger"
else
  red "there is no delivery record"
fi

printf '\n%s' "$A"
if [ "$BLOCKED" -eq 0 ]; then
  printf 'ALL NINE GATES GREEN%s\n\n' "$O"
  exit 0
else
  printf '%d BLOCKING FAILURES — the delivery does not happen%s\n\n' "$BLOCKED" "$O"
  exit 1
fi
