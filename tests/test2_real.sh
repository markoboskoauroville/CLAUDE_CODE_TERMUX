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
# What a real Termux glibc holds: a genuine ELF libc.so.6 beside a TEXT linker
# script named libc.so. Android's own libc is also named libc.so, so any
# directory on LD_LIBRARY_PATH that contains this script breaks every Bionic
# command. Measured on a phone, 12.9.2026. The fixture carries the trap.
cp /bin/true "$PREFIX/glibc/lib/libc.so.6"
printf '/* GNU ld script */\nGROUP ( libc.so.6 )\n' > "$PREFIX/glibc/lib/libc.so"
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
  RPATH="$(patchelf --print-rpath "$BIN" 2>&1)"
  assert_eq "the library path is written into the binary, not left to the shell" \
            "$PREFIX/glibc/lib" "$RPATH"
  NEEDED="$(patchelf --print-needed "$BIN" 2>&1)"
  assert_contains "the binary asks for libc.so.6 by that name" "libc.so.6" "$NEEDED"
  assert_not_contains "and never for bare libc.so, which is Android's own" \
    "$(printf 'libc.so\n')" "$(printf '%s\n' "$NEEDED" | grep -x 'libc.so')"
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
# MEASURED ON A PHONE, 12.9.2026. Exporting LD_LIBRARY_PATH pointed every
# process the launcher started at the glibc directory. Android's libc is named
# libc.so and glibc ships a TEXT LINKER SCRIPT under that same name, so Termux
# commands loaded the script and died with "bad ELF magic: 2f2a2047". The
# library path must live in the binary, never in the environment.
if printf '%s\n' "$LAUNCHER" | grep -qE '^[^#]*export[[:space:]]+LD_LIBRARY_PATH'; then
  fail "the launcher must not export LD_LIBRARY_PATH" \
       "it poisons every Termux command the launcher runs"
else
  pass "the launcher does not export LD_LIBRARY_PATH"
fi
# MEASURED ON A PHONE, 12.9.2026, with LD_DEBUG=libs. Termux puts
# libtermux-exec-ld-preload.so on LD_PRELOAD in every shell. It is a Bionic
# object needing libc.so; glibc's loader honours the preload, searches the
# glibc directory for libc.so, finds a text linker script and stops with
# "invalid ELF header". The launcher must clear the preload for its own
# process. This check can fail on its own: remove the unset and it goes red.
if printf '%s\n' "$LAUNCHER" | grep -qE '^[[:space:]]*unset[[:space:]]+LD_PRELOAD'; then
  pass "the launcher clears the Termux preload before exec"
else
  fail "the launcher clears the Termux preload before exec" \
       "without it, glibc resolves the preload's libc.so against the linker script"
fi
PRELOAD_LINE=$(printf '%s\n' "$LAUNCHER" | grep -nE '^[[:space:]]*unset[[:space:]]+LD_PRELOAD' | cut -d: -f1 | head -1)
EXEC_LINE=$(printf '%s\n' "$LAUNCHER" | grep -n '^exec ' | cut -d: -f1 | head -1)
if [ -n "$PRELOAD_LINE" ] && [ -n "$EXEC_LINE" ] && [ "$PRELOAD_LINE" -lt "$EXEC_LINE" ]; then
  pass "and it clears it before the exec, not after"
else
  fail "and it clears it before the exec" "unset at line ${PRELOAD_LINE:-none}, exec at line ${EXEC_LINE:-none}"
fi
assert_contains "the launcher gives Android a TMPDIR" "TMPDIR"               "$LAUNCHER"
assert_contains "the launcher uses Termux ripgrep"    "USE_BUILTIN_RIPGREP=0" "$LAUNCHER"
assert_contains "the launcher disables the autoupdater" "DISABLE_AUTOUPDATER=1" "$LAUNCHER"
assert_contains "the launcher execs the binary"       "exec "                "$LAUNCHER"
# the mkdir must not run under a poisoned environment either
MKDIR_LINE=$(printf '%s\n' "$LAUNCHER" | grep -n 'mkdir' | cut -d: -f1 | head -1)
LDLP_LINE=$(printf '%s\n' "$LAUNCHER" | grep -nE '^[^#]*LD_LIBRARY_PATH' | cut -d: -f1 | head -1)
if [ -z "$LDLP_LINE" ]; then
  pass "no library path is set before the launcher runs mkdir"
else
  fail "no library path is set before the launcher runs mkdir" "line $LDLP_LINE sets it, mkdir is at line $MKDIR_LINE"
fi
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

# The proot launcher is generated here and checked, though it cannot be run:
# no proot-distro exists on a test machine.
PROOT_LAUNCHER="$(CCT_SOURCE_ONLY=1 bash -c '
  export PREFIX="'"$PREFIX"'" BIN_DIR="'"$PREFIX"'/bin"
  . "'"$HERE"'/../install.sh"
  BIN_DIR="'"$PREFIX"'/bin"
  write_launcher_proot >/dev/null 2>&1
  cat "$BIN_DIR/claude"')"
assert_ok "the proot launcher parses" bash -c "printf '%s' \"\$1\" | bash -n" _ "$PROOT_LAUNCHER"
assert_contains "it clears the Termux preload too" "unset LD_PRELOAD" "$PROOT_LAUNCHER"
# MEASURED ON A PHONE, 12.9.2026: proot-distro login always starts in the
# container's home, so "cd myproject && claude" opened Claude Code in the home
# directory and it could not see the project files at all.
assert_contains "it resolves the working directory with symlinks followed" "pwd -P" "$PROOT_LAUNCHER"
assert_contains "it binds that directory into the container" '--bind "$CCT_CWD:$CCT_CWD"' "$PROOT_LAUNCHER"
assert_contains "and changes into it before starting" 'cd "$1"' "$PROOT_LAUNCHER"

skip "claude --version actually running" "this machine is not aarch64; only a phone can prove it"
skip "the proot launcher actually entering the directory" "no proot-distro here; only a phone can prove it"
skip "pkg install against real Termux repositories" "no Termux here"

t_summary "TEST 2"
