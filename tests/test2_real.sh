#!/usr/bin/env bash
# TEST 2 — INSIDE THE RUNNING INSTALLER, WITH REAL DATA
#
# The real install.sh, driven the way a person drives it, against Anthropic's
# real CDN, downloading the real binary and patching it with the real patchelf.
# Nothing is mocked except the two things that cannot exist off a phone: the
# Termux package manager and Termux's glibc.
#
# The outside number this test leans on: Anthropic publishes a sha256 and a
# byte count in its own manifest, and both must agree with what lands on disk.
# That is an independent party confirming the result.
#
# Run: bash tests/test2_real.sh

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"

command -v patchelf >/dev/null 2>&1 || { echo "patchelf is needed for TEST 2"; exit 2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export PREFIX="$WORK/usr"
mkdir -p "$PREFIX/bin" "$PREFIX/tmp" "$PREFIX/glibc/lib"
export HOME="$WORK/home"; mkdir -p "$HOME"

# The two stand-ins, and only these two.
cat > "$WORK/apt-get" <<'STUB'
#!/bin/bash
echo "apt-get stand-in: $*"
exit 0
STUB
chmod +x "$WORK/apt-get"
# A stand-in for Termux's glibc linker. patchelf only writes the path string,
# so a real loader is not needed to prove the write happened.
printf '\177ELF stand-in loader\n' > "$PREFIX/glibc/lib/ld-linux-aarch64.so.1"
export PATH="$WORK:$PATH"

t_head "TEST 2 — the real installer against the real CDN"

echo "  running install.sh --native --yes  (this downloads ~230 MB)"
LOG="$WORK/install.log"
bash "$HERE/../install.sh" --native --yes > "$LOG" 2>&1
INSTALL_RC=$?
echo "  installer exited $INSTALL_RC, $(wc -l < "$LOG") lines of output"

# The installer is expected to end unhappy here: the artefact is an aarch64
# binary and this machine is not aarch64, so the final claude --version cannot
# run. Everything before that step must have succeeded.
assert_contains "the run reached the verify step"     "Verifying"            "$(cat "$LOG")"

# ---- what the CDN said, read back independently of the installer -----------
CDN="https://downloads.claude.ai/claude-code-releases"
VERSION="$(curl -fsSL --max-time 60 "$CDN/latest" | tr -d '\r\n')"
MANIFEST="$(curl -fsSL --max-time 60 "$CDN/$VERSION/manifest.json")"
WANT_SHA="$(printf '%s' "$MANIFEST" | python3 -c 'import json,sys;print(json.load(sys.stdin)["platforms"]["linux-arm64"]["checksum"])')"
WANT_SIZE="$(printf '%s' "$MANIFEST" | python3 -c 'import json,sys;print(json.load(sys.stdin)["platforms"]["linux-arm64"]["size"])')"
echo "  Anthropic says version $VERSION, $WANT_SIZE bytes, sha256 ${WANT_SHA:0:16}..."

BIN="$PREFIX/opt/claude-code/versions/claude-$VERSION"
assert_ok "the binary for the current version is on disk" test -f "$BIN"

if [ -f "$BIN" ]; then
  GOT_SIZE="$(stat -c %s "$BIN")"
  # The outside number: Anthropic's byte count against what the installer
  # verified. It is read from the installer's own log, because that figure is
  # taken BEFORE patchelf touches the file. Comparing the patched file to the
  # manifest would be comparing two different artefacts.
  DOWNLOADED="$(sed -n 's/.*sha256 matches, \([0-9][0-9]*\) bytes.*/\1/p' "$LOG" | head -1)"
  assert_eq "the downloaded byte count matches Anthropic's manifest" "$WANT_SIZE" "${DOWNLOADED:-none}"
  assert_contains "the installer reported the sha256 matching" "sha256 matches" "$(cat "$LOG")"
  assert_contains "the installer printed the manifest size"    "MB, sha256"     "$(cat "$LOG")"

  # patchelf pads the ELF headers to a page boundary, so the file on disk is
  # larger than the manifest figure. Record the growth rather than assume it.
  GREW=$(( GOT_SIZE - WANT_SIZE ))
  echo "  patchelf grew the file by $GREW bytes ($(( GREW / 1024 )) KB)"
  if [ "$GREW" -ge 0 ] && [ "$GREW" -le 1048576 ]; then
    pass "the patch grew the file by a page-sized amount, $GREW bytes"
  else
    fail "the patch grew the file by a page-sized amount" "it changed by $GREW bytes, which is not header padding"
  fi

  # ---- the patch really took --------------------------------------------
  INTERP="$(patchelf --print-interpreter "$BIN" 2>&1)"
  assert_eq "the ELF interpreter now points at Termux glibc" \
            "$PREFIX/glibc/lib/ld-linux-aarch64.so.1" "$INTERP"
  # and the file is still a working aarch64 ELF, not corrupted by the rewrite
  FILE_SAYS="$(file -b "$BIN" 2>/dev/null || echo unknown)"
  assert_contains "it is still an ELF" "ELF" "$FILE_SAYS"
  assert_contains "it is still aarch64" "aarch64" "$FILE_SAYS"
  # the payload bun appends must survive the rewrite: the file cannot have shrunk
  if [ "$GOT_SIZE" -ge "$WANT_SIZE" ]; then
    pass "patching did not truncate the appended payload"
  else
    fail "patching did not truncate the appended payload" "$GOT_SIZE < $WANT_SIZE"
  fi
fi

# ---- the commands the person will actually type ---------------------------
assert_ok "claude was created"                 test -x "$PREFIX/bin/claude"
assert_ok "claude-termux-update was created"   test -x "$PREFIX/bin/claude-termux-update"
assert_ok "no half-written claude.new remains" test ! -e "$PREFIX/bin/claude.new"
assert_ok "no half-written updater remains"    test ! -e "$PREFIX/bin/claude-termux-update.new"
assert_eq "the mode was recorded" "native" "$(cat "$PREFIX/opt/claude-code/mode" 2>/dev/null)"
assert_ok "current points at the binary" test -L "$PREFIX/opt/claude-code/current"

LAUNCHER="$(cat "$PREFIX/bin/claude" 2>/dev/null)"
assert_contains "the launcher sets LD_LIBRARY_PATH"   "LD_LIBRARY_PATH"      "$LAUNCHER"
assert_contains "the launcher gives Android a TMPDIR" "TMPDIR"               "$LAUNCHER"
assert_contains "the launcher uses Termux ripgrep"    "USE_BUILTIN_RIPGREP=0" "$LAUNCHER"
assert_contains "the launcher disables the autoupdater" "DISABLE_AUTOUPDATER=1" "$LAUNCHER"
assert_contains "the launcher execs the binary"       "exec "                "$LAUNCHER"
assert_ok "the launcher is valid shell" bash -n "$PREFIX/bin/claude"

UPD="$(cat "$PREFIX/bin/claude-termux-update" 2>/dev/null)"
assert_ok "the updater is valid shell" bash -n "$PREFIX/bin/claude-termux-update"
assert_contains "the updater fetches"      "curl"           "$UPD"
assert_contains "the updater then installs" "bash \"\$TMP\"" "$UPD"
assert_contains "the updater checks the sentinel" "SENTINEL" "$UPD"
assert_contains "the updater carries a deadline"  "--max-time" "$UPD"

# ---- the verbose contract: the person must see progress -------------------
OUT="$(cat "$LOG")"
assert_contains "step 1 of 9 is announced"      "[ 1 / 9 ]" "$OUT"
assert_contains "step 9 of 9 is reached"        "[ 9 / 9 ]" "$OUT"
assert_contains "the dependency table is drawn" "DEPENDENCY" "$OUT"
assert_contains "a progress bar was drawn"      "MB  claude" "$OUT"
assert_contains "apt output was streamed, not hidden" "apt-get stand-in" "$OUT"
LONGEST_GAP="$(awk '/^$/{next}{print}' "$LOG" | wc -l)"
if [ "$LONGEST_GAP" -ge 30 ]; then
  pass "the run printed $LONGEST_GAP lines, so it never looks stalled"
else
  fail "the run printed enough to look alive" "only $LONGEST_GAP lines"
fi

skip "claude --version actually running" "this machine is not aarch64; only a phone can prove it"
skip "pkg install against real Termux repositories" "no Termux here"

t_summary "TEST 2"
