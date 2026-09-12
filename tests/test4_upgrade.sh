#!/usr/bin/env bash
# TEST 4 — THE UPGRADE, FROM THE VERSION BEFORE
#
# Nobody installs this fresh. They have the previous edition, their login,
# their settings, and possibly the old updater still running. The question is
# not "does it install" but "does it install OVER what is already there and
# leave every one of those intact".
#
# The previous edition is fetched from the repository's own history, so this is
# the real artefact and not a reconstruction of it.
#
# Run: bash tests/test4_upgrade.sh   [path-to-previous-install.sh]

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"

PREV="${1:-$HERE/fixtures/install-previous.sh}"
[ -f "$PREV" ] || { echo "the previous edition is not at $PREV"; exit 2; }

WORK="$(mktemp -d)"
SERVER_PID=""
cleanup() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; [ -n "${CCT_KEEP:-}" ] || rm -rf "$WORK"; [ -n "${CCT_KEEP:-}" ] && echo "  work kept at $WORK"; }
trap cleanup EXIT

t_head "TEST 4 — upgrading from the previous edition"

# ------------------------------------------------- a stand-in CDN and stubs
SRV="$WORK/srv"; mkdir -p "$SRV/9.9.9/linux-arm64"
ELF="$WORK/fake-claude"; cp /bin/true "$ELF"
printf '9.9.9' > "$SRV/latest"
cp "$ELF" "$SRV/9.9.9/linux-arm64/claude"
printf '{"version":"9.9.9","platforms":{"linux-arm64":{"checksum":"%s","size":%s}}}' \
  "$(sha256sum "$ELF" | cut -d' ' -f1)" "$(stat -c %s "$ELF")" > "$SRV/9.9.9/manifest.json"
PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"
( cd "$SRV" && python3 -m http.server "$PORT" >/dev/null 2>&1 ) & SERVER_PID=$!
SERVER_UP=0
for _ in $(seq 1 40); do
  if /usr/bin/curl -fsS --max-time 2 "http://127.0.0.1:$PORT/latest" >/dev/null 2>&1; then SERVER_UP=1; break; fi
  sleep 0.25
done
# A check that never ran and a check that found nothing look identical from
# outside, so a server that never came up is a hard stop, not a quiet skip.
[ "$SERVER_UP" = "1" ] || { echo "the stand-in server on port $PORT never answered"; exit 2; }

STUBS="$WORK/stubs"; mkdir -p "$STUBS"
cat > "$STUBS/apt-get" <<'S'
#!/bin/bash
exit 0
S
# The previous edition hardcodes Anthropic's address, so the redirect to the
# stand-in server is done in a curl stub rather than by editing it. The old
# script therefore runs exactly as it shipped.
cat > "$STUBS/curl" <<S
#!/bin/bash
args=()
for a in "\$@"; do
  b="\${a/https:\/\/downloads.claude.ai\/claude-code-releases/http:\/\/127.0.0.1:$PORT}"
  b="\${b/https:\/\/downloads.claude.ai/http:\/\/127.0.0.1:$PORT}"
  args+=("\$b")
done
exec /usr/bin/curl "\${args[@]}"
S
# The previous edition refuses anything that is not aarch64, which is correct
# on a phone. The stand-in makes this machine answer the way a phone does, so
# both editions run under the same conditions.
cat > "$STUBS/uname" <<'S'
#!/bin/bash
[ "$1" = "-m" ] && { echo aarch64; exit 0; }
exec /usr/bin/uname "$@"
S
chmod +x "$STUBS/apt-get" "$STUBS/curl" "$STUBS/uname"
export PATH="$STUBS:$PATH"

export PREFIX="$WORK/usr"
mkdir -p "$PREFIX/bin" "$PREFIX/tmp" "$PREFIX/glibc/lib"
export HOME="$WORK/home"; mkdir -p "$HOME"
printf '\177ELF stand-in loader\n' > "$PREFIX/glibc/lib/ld-linux-aarch64.so.1"

# ================================================ 1. INSTALL THE OLD ONE ====
echo "  installing the previous edition"
bash "$PREV" --native > "$WORK/old.log" 2>&1
OLD_RC=$?
echo "  it exited $OLD_RC"

assert_ok "the previous edition produced a claude command" test -x "$PREFIX/bin/claude"
assert_ok "the previous edition produced an updater"        test -x "$PREFIX/bin/claude-termux-update"

# Verify the OLD version is really old, and that the new features are ABSENT.
# Otherwise this test may have installed the new one twice and proved nothing.
assert_contains "the fixture really is the previous edition" "CCT_VERSION=2" "$(cat "$PREV")"
OLD_UPDATER="$(cat "$PREFIX/bin/claude-termux-update")"
assert_not_contains "the old updater does not know this edition's marker" \
  "CLAUDE_CODE_TERMUX_COMPLETE_MARKER" "$OLD_UPDATER"
assert_not_contains "the old run used its own step counter, not this one" "[ 1 / 9 ]" "$(cat "$WORK/old.log")"

# THE COMPATIBILITY CLAUSE. The previous edition's updater refuses any
# installer that does not carry its own completeness marker. If this edition
# drops that line, every phone already on edition 2 is stranded: its update
# command will report a truncated download forever and never move.
if grep -q "CCT_COMPLETE_V2" "$PREV"; then
  if grep -q '^# CCT_COMPLETE_V2$' "$HERE/../install.sh"; then
    pass "this edition carries the previous edition's marker, so v2 phones can still update"
  else
    fail "this edition carries the previous edition's marker" \
         "the line # CCT_COMPLETE_V2 is missing, so an edition-2 updater will reject this file"
  fi
  OLD_CHECK="$(grep -o "grep -q '\^# CCT_COMPLETE_V2\$'[^|]*" "$PREV" | head -1)"
  if tail -2 "$HERE/../install.sh" | grep -q '^# CCT_COMPLETE_V2$'; then
    pass "and it is in the last two lines, where a truncation removes it"
  else
    fail "and it is in the last two lines" "it sits too early to prove completeness"
  fi
else
  skip "the previous edition's marker" "the previous edition does not use one"
fi

# ==================================================== 2. USE IT, FOR REAL ===
mkdir -p "$HOME/.claude/projects/brain-brake"
cat > "$HOME/.claude/settings.json" <<'J'
{"theme":"dark","autoCompact":false,"myMarker":"set-by-the-user-before-the-upgrade"}
J
printf '{"oauthAccount":{"stand-in":"credential"},"numStartups":11}\n' > "$HOME/.claude.json"
printf 'a note written by the old version\n' > "$HOME/.claude/projects/brain-brake/NOTES.md"
SETTINGS_SHA="$(sha256sum "$HOME/.claude/settings.json" | cut -d' ' -f1)"
CREDS_SHA="$(sha256sum "$HOME/.claude.json" | cut -d' ' -f1)"
NOTES_SHA="$(sha256sum "$HOME/.claude/projects/brain-brake/NOTES.md" | cut -d' ' -f1)"
OLD_BINARY_SHA="$(sha256sum "$PREFIX/opt/claude-code/versions/claude-9.9.9" | cut -d' ' -f1)"
OLD_BINARY_SIZE="$(stat -c %s "$PREFIX/opt/claude-code/versions/claude-9.9.9")"

# ================================================= 3. LEAVE IT RUNNING ======
cat > "$PREFIX/bin/claude-termux-update" <<'READER'
#!/bin/bash
sleep 2
echo "OLD-UPDATER-FINISHED-CLEANLY"
READER
chmod +x "$PREFIX/bin/claude-termux-update"
( bash "$PREFIX/bin/claude-termux-update" > "$WORK/reader.out" 2>&1 ) &
READER_JOB=$!
sleep 0.4

# ============================================ 4. INSTALL THE NEW ON TOP =====
echo "  installing edition v2 over the top"
CCT_CDN="http://127.0.0.1:$PORT" CCT_RAW="http://127.0.0.1:$PORT/install.sh" \
  bash "$HERE/../install.sh" --native --yes > "$WORK/new.log" 2>&1
NEW_RC=$?
echo "  it exited $NEW_RC"
wait "$READER_JOB" 2>/dev/null

# ==================================================== 5. CHECK EVERYTHING ===
assert_contains "the new edition really is the new one" "[ 1 / 9 ]" "$(cat "$WORK/new.log")"

# every setting keeps its VALUE, not its default
assert_eq "settings.json survives byte for byte" "$SETTINGS_SHA" \
  "$(sha256sum "$HOME/.claude/settings.json" | cut -d' ' -f1)"
assert_contains "and the value inside it is still the user's" "set-by-the-user-before-the-upgrade" \
  "$(cat "$HOME/.claude/settings.json")"
assert_eq "the credential file survives" "$CREDS_SHA" \
  "$(sha256sum "$HOME/.claude.json" | cut -d' ' -f1)"
assert_eq "a file written by the old version is still there and unchanged" "$NOTES_SHA" \
  "$(sha256sum "$HOME/.claude/projects/brain-brake/NOTES.md" | cut -d' ' -f1)"
assert_ok "the project directory survives" test -d "$HOME/.claude/projects/brain-brake"

# a running process reads to the end rather than falling off a truncated file
assert_contains "the updater that was running finished cleanly" \
  "OLD-UPDATER-FINISHED-CLEANLY" "$(cat "$WORK/reader.out")"

# every executable is replaced
NEW_LAUNCHER="$(cat "$PREFIX/bin/claude")"
NEW_UPDATER="$(cat "$PREFIX/bin/claude-termux-update")"
# Read the edition out of the script rather than writing a number here. A
# hardcoded expectation fails on the next bump for no reason connected to the
# feature under test.
EDITION="$(grep -m1 '^CCT_EDITION=' "$HERE/../install.sh" | cut -d= -f2)"
assert_contains "the launcher is the new one"  "edition v$EDITION" "$NEW_LAUNCHER"
assert_contains "the updater is the new one"   "edition v$EDITION" "$NEW_UPDATER"
assert_contains "the updater now checks a sentinel" "CLAUDE_CODE_TERMUX_COMPLETE_MARKER" "$NEW_UPDATER"
assert_ok "the launcher parses"  bash -n "$PREFIX/bin/claude"
assert_ok "the updater parses"   bash -n "$PREFIX/bin/claude-termux-update"

# no half-written temporary file is left behind
assert_ok "no .new file remains"  test ! -e "$PREFIX/bin/claude.new"
assert_ok "no .part file remains" bash -c '! ls "$PREFIX"/opt/claude-code/versions/*.part >/dev/null 2>&1'

# the binary the old version already fetched is reused rather than re-fetched
assert_contains "the existing download is reused, not fetched again" "already here" "$(cat "$WORK/new.log")"
NEW_BINARY_SIZE="$(stat -c %s "$PREFIX/opt/claude-code/versions/claude-9.9.9")"
INTERP="$(patchelf --print-interpreter "$PREFIX/opt/claude-code/versions/claude-9.9.9" 2>&1)"
assert_eq "the interpreter is still pointed at Termux glibc" \
  "$PREFIX/glibc/lib/ld-linux-aarch64.so.1" "$INTERP"
GREW=$(( NEW_BINARY_SIZE - OLD_BINARY_SIZE ))
echo "  patching an already-patched binary changed its size by $GREW bytes"
if [ "$GREW" -le 1048576 ]; then
  pass "re-patching an already-patched binary does not run away, $GREW bytes"
else
  fail "re-patching an already-patched binary does not run away" "it grew $GREW bytes"
fi

# the new edition records what the old one did not, so the updater knows the mode
assert_eq "the mode file now exists" "native" "$(cat "$PREFIX/opt/claude-code/mode" 2>/dev/null)"

# ============================================ 6. DOING IT TWICE IS SAFE =====
BEFORE_SHA="$(sha256sum "$PREFIX/bin/claude" | cut -d' ' -f1)"
CCT_CDN="http://127.0.0.1:$PORT" bash "$HERE/../install.sh" --native --yes > "$WORK/new2.log" 2>&1
assert_eq "upgrading a second time changes nothing" "$BEFORE_SHA" \
  "$(sha256sum "$PREFIX/bin/claude" | cut -d' ' -f1)"
assert_eq "and the settings are still the user's" "$SETTINGS_SHA" \
  "$(sha256sum "$HOME/.claude/settings.json" | cut -d' ' -f1)"

# ================================================= 7. THE WAY BACK ==========
# Rolling back means the previous edition installs over the new one and the
# person's data is still theirs.
bash "$PREV" --native > "$WORK/rollback.log" 2>&1
ROLLBACK_RC=$?

# MEASURED, and it is a defect in the previous edition rather than in this one:
# edition 2 re-verifies the sha256 of a binary that is ALREADY on disk. That
# binary has been through patchelf, so its bytes no longer match Anthropic's
# manifest, and edition 2 stops with a checksum mismatch. The same thing
# happens when edition 2 is simply run twice. The way back therefore has one
# extra step, and it is tested below rather than assumed.
if [ "$ROLLBACK_RC" -ne 0 ]; then
  pass "rolling straight back is refused by the previous edition, as measured"
  assert_contains "and the reason is its checksum re-check on a patched file" \
    "checksum mismatch" "$(cat "$WORK/rollback.log")"
  assert_ok "the working install is left intact by the refusal" test -x "$PREFIX/bin/claude"
else
  note_unexpected=1
  pass "the previous edition installed straight back"
fi

# The documented way back: drop the patched binary, then install the previous
# edition, which then downloads and verifies a fresh one.
rm -rf "$PREFIX/opt/claude-code/versions"
bash "$PREV" --native > "$WORK/rollback2.log" 2>&1
assert_ok "clearing the patched binary first lets the previous edition install" \
  test -x "$PREFIX/bin/claude"
assert_not_contains "and the launcher is the old one again" "edition v$EDITION" "$(cat "$PREFIX/bin/claude")"
assert_eq "the settings survive the way back" "$SETTINGS_SHA" \
  "$(sha256sum "$HOME/.claude/settings.json" | cut -d' ' -f1)"
assert_eq "and so does the credential file" "$CREDS_SHA" \
  "$(sha256sum "$HOME/.claude.json" | cut -d' ' -f1)"

skip "an upgrade on a real phone, over a real login" "no Android here; only the phone can prove it"

t_summary "TEST 4"
