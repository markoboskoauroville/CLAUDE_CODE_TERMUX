#!/usr/bin/env bash
# TEST 3 — THE UGLY CASES
#
# Failure, empty, corrupt, truncated, hostile, offline, never answering, twice,
# out of order. Closes "it works when the world behaves".
#
# A local stand-in CDN is used so each case costs a second rather than 230 MB.
# The bytes are small; the failures are real.
#
# Run: bash tests/test3_ugly.sh

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"

WORK="$(mktemp -d)"
SERVER_PID=""
cleanup() { [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

SRV="$WORK/srv"; mkdir -p "$SRV"
PORT="$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')"

t_head "TEST 3 — the ugly cases"

# --------------------------------------------------------- the stand-in CDN
build_cdn() {
  # $1 = the file that will be served as the claude binary
  rm -rf "$SRV"; mkdir -p "$SRV/9.9.9/linux-arm64"
  printf '9.9.9' > "$SRV/latest"
  cp "$1" "$SRV/9.9.9/linux-arm64/claude"
  local sha size
  sha=$(sha256sum "$1" | cut -d' ' -f1)
  size=$(stat -c %s "$1")
  printf '{"version":"9.9.9","platforms":{"linux-arm64":{"checksum":"%s","size":%s}}}' \
    "$sha" "$size" > "$SRV/9.9.9/manifest.json"
}

start_server() {
  ( cd "$SRV" && python3 -m http.server "$PORT" >/dev/null 2>&1 ) &
  SERVER_PID=$!
  for _ in $(seq 1 40); do
    curl -fsS --max-time 2 "http://127.0.0.1:$PORT/latest" >/dev/null 2>&1 && return 0
    sleep 0.25
  done
  return 1
}

# A small real ELF stands in for the 230 MB one. patchelf needs a real ELF;
# nothing else in the ugly cases cares how big it is.
ELF="$WORK/fake-claude"
cp /bin/true "$ELF"
build_cdn "$ELF"
start_server || { echo "the stand-in server would not start"; exit 2; }

# ------------------------------------------------------- a clean environment
fresh_env() {
  rm -rf "$WORK/usr" "$WORK/home"
  export PREFIX="$WORK/usr"
  mkdir -p "$PREFIX/bin" "$PREFIX/tmp" "$PREFIX/glibc/lib"
  export HOME="$WORK/home"; mkdir -p "$HOME"
  printf '\177ELF stand-in loader\n' > "$PREFIX/glibc/lib/ld-linux-aarch64.so.1"
  # A real Termux glibc holds a genuine ELF libc.so.6 beside a TEXT linker
  # script named libc.so. Android's own libc is also named libc.so, so any
  # directory on LD_LIBRARY_PATH holding this script breaks every Bionic
  # command. Measured on a phone, 12.9.2026. The fixture carries the trap.
  cp /bin/true "$PREFIX/glibc/lib/libc.so.6"
  printf '/* GNU ld script */\nGROUP ( libc.so.6 )\n' > "$PREFIX/glibc/lib/libc.so"
  export CCT_CDN="http://127.0.0.1:$PORT"
  export CCT_RAW="http://127.0.0.1:$PORT/install.sh"
  export CCT_CONNECT_TIMEOUT=3 CCT_SMALL_TIMEOUT=5 CCT_BIG_TIMEOUT=20
}
STUBS="$WORK/stubs"; mkdir -p "$STUBS"
cat > "$STUBS/apt-get" <<'S'
#!/bin/bash
exit 0
S
chmod +x "$STUBS/apt-get"
export PATH="$STUBS:$PATH"

install_run() { bash "$HERE/../install.sh" --native --yes "$@" >"$WORK/out.log" 2>&1; echo $?; }

# ============================================================== ABSENT ======
fresh_env
CCT_CDN="http://127.0.0.1:1" RC=$(CCT_CDN="http://127.0.0.1:1" install_run)
assert_eq  "a refused connection stops the install" "1" "$RC"
assert_contains "and says so in words" "did not answer with a version" "$(cat "$WORK/out.log")"
assert_ok  "nothing was left in bin" test ! -e "$PREFIX/bin/claude"

# ============================================================== EMPTY =======
fresh_env
: > "$SRV/latest"
RC=$(install_run)
assert_eq "an empty version reply stops the install" "1" "$RC"
assert_ok "nothing was installed" test ! -e "$PREFIX/bin/claude"
printf '9.9.9' > "$SRV/latest"

# ========================================================== MALFORMED =======
fresh_env
printf '<!DOCTYPE html><html><body>Sign in to the wifi</body></html>' > "$SRV/latest"
RC=$(install_run)
assert_eq "a captive-portal page is not taken for a version" "1" "$RC"
assert_contains "and the message points at the network" "Check the network" "$(cat "$WORK/out.log")"
printf '9.9.9' > "$SRV/latest"

fresh_env
printf '{"platforms":{"darwin-arm64":{"checksum":"aa"}}}' > "$SRV/9.9.9/manifest.json"
RC=$(install_run)
assert_eq "a manifest with no linux-arm64 stops the install" "1" "$RC"
assert_contains "and names the missing checksum" "no linux-arm64 checksum" "$(cat "$WORK/out.log")"
build_cdn "$ELF"

# =========================================================== CORRUPTED ======
fresh_env
# one byte flipped: the right length, the wrong content
cp "$ELF" "$SRV/9.9.9/linux-arm64/claude"
printf 'X' | dd of="$SRV/9.9.9/linux-arm64/claude" bs=1 seek=64 conv=notrunc 2>/dev/null
RC=$(install_run)
assert_eq "a corrupted download is refused" "1" "$RC"
assert_contains "and the words say nothing was installed" "nothing was installed" "$(cat "$WORK/out.log")"
assert_ok "the rejected file is deleted, not kept" \
  bash -c '! ls "$PREFIX"/opt/claude-code/versions/*.part >/dev/null 2>&1'
assert_ok "no claude command was written" test ! -e "$PREFIX/bin/claude"
build_cdn "$ELF"

fresh_env
# truncated halfway: the right start, the wrong length
head -c 200 "$ELF" > "$SRV/9.9.9/linux-arm64/claude"
RC=$(install_run)
assert_eq "a truncated download is refused" "1" "$RC"
build_cdn "$ELF"

# ====================================================== NEVER ANSWERS =======
# A socket that accepts and then goes quiet forever. This is the case that has
# no error to catch, so only a deadline saves it.
python3 - "$WORK/silent.port" <<'PY' &
import socket, sys, time
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(5)
open(sys.argv[1], "w").write(str(s.getsockname()[1]))
conns = []
while True:
    try:
        c, _ = s.accept(); conns.append(c)   # accept, then say nothing at all
    except Exception:
        time.sleep(0.1)
PY
SILENT_PID=$!
for _ in $(seq 1 40); do [ -s "$WORK/silent.port" ] && break; sleep 0.25; done
SILENT_PORT="$(cat "$WORK/silent.port" 2>/dev/null)"
if [ -n "$SILENT_PORT" ]; then
  fresh_env
  T0=$(date +%s)
  RC=$(CCT_CDN="http://127.0.0.1:$SILENT_PORT" install_run)
  T1=$(date +%s)
  assert_eq "a server that never answers stops the install" "1" "$RC"
  if [ $(( T1 - T0 )) -le 30 ]; then
    pass "it gave up after $(( T1 - T0 ))s instead of waiting forever"
  else
    fail "it gave up rather than waiting forever" "it took $(( T1 - T0 ))s"
  fi
  kill "$SILENT_PID" 2>/dev/null
else
  skip "a server that never answers" "the silent socket would not start"
fi

# =========================================================== HOSTILE ========
fresh_env
# a version string carrying shell metacharacters must never be executed
printf '9.9.9; touch %s/pwned' "$WORK" > "$SRV/latest"
RC=$(install_run)
assert_ok "a version containing a shell command does not run it" test ! -e "$WORK/pwned"
printf '9.9.9' > "$SRV/latest"

# ============================================== UNSUPPORTED ENVIRONMENT =====
fresh_env
cat > "$STUBS/uname" <<'S'
#!/bin/bash
[ "$1" = "-m" ] && { echo armv7l; exit 0; }
exec /usr/bin/uname "$@"
S
chmod +x "$STUBS/uname"
RC=$(install_run)
assert_eq "a 32-bit phone is refused" "1" "$RC"
assert_contains "and the reason is plain" "32-bit" "$(cat "$WORK/out.log")"
rm -f "$STUBS/uname"

fresh_env
rm -rf "$PREFIX/glibc"
RC=$(install_run)
assert_eq "no glibc linker anywhere stops the install" "1" "$RC"
assert_contains "and it names the fix" "pkg install glibc-runner" "$(cat "$WORK/out.log")"

fresh_env
RC=$(PREFIX="$WORK/nowhere" install_run)
assert_eq "a missing prefix is refused" "1" "$RC"

# =========================================================== BAD USAGE ======
fresh_env
bash "$HERE/../install.sh" --banana >"$WORK/out.log" 2>&1
assert_eq "an unknown flag is refused" "1" "$?"
assert_contains "and it says which flag" "banana" "$(cat "$WORK/out.log")"

# ============================================================== TWICE =======
fresh_env
RC1=$(install_run)
FIRST_SHA="$(sha256sum "$PREFIX/bin/claude" | cut -d' ' -f1)"
RC2=$(install_run)
SECOND_SHA="$(sha256sum "$PREFIX/bin/claude" | cut -d' ' -f1)"
assert_eq "installing twice in a row is harmless" "$RC1" "$RC2"
assert_eq "the launcher is byte-identical the second time" "$FIRST_SHA" "$SECOND_SHA"
assert_ok "no half-written files after two runs" test ! -e "$PREFIX/bin/claude.new"
COUNT=$(ls -1 "$PREFIX/opt/claude-code/versions" | wc -l)
assert_eq "only one build is kept for one version" "1" "$COUNT"

# ================================================== INTERRUPTED BEFORE ======
fresh_env
mkdir -p "$PREFIX/bin"
printf 'garbage from a run that died\n' > "$PREFIX/bin/claude.new"
printf 'garbage from a run that died\n' > "$PREFIX/bin/claude-termux-update.new"
RC=$(install_run)
assert_ok "orphaned half-written files are cleared" test ! -e "$PREFIX/bin/claude.new"
assert_contains "and the clearing is reported" "half-written" "$(cat "$WORK/out.log")"

# ======================================= REPLACING A COMMAND WHILE IT RUNS ==
# The sharp one. A shell is reading claude-termux-update when the installer
# replaces it. A truncating write pulls the file out from under that shell.
fresh_env
install_run >/dev/null
cat > "$WORK/slow-reader.sh" <<'READER'
#!/bin/bash
# stands in for the updater: a long script that sleeps in the middle
sleep 2
echo "READER-REACHED-THE-END"
READER
cp "$WORK/slow-reader.sh" "$PREFIX/bin/claude-termux-update"
chmod +x "$PREFIX/bin/claude-termux-update"
( bash "$PREFIX/bin/claude-termux-update" > "$WORK/reader.out" 2>&1 ) &
READER_JOB=$!
sleep 0.5
install_run >/dev/null      # replaces the updater while the reader is inside it
wait "$READER_JOB" 2>/dev/null
assert_contains "a shell reading a command runs to the end while it is replaced" \
  "READER-REACHED-THE-END" "$(cat "$WORK/reader.out")"
assert_not_contains "and reads no fragment of the new file" \
  "claude-termux-update" "$(cat "$WORK/reader.out")"

# ============================ THE UPDATER AGAINST A BROKEN DOWNLOAD =========
fresh_env
install_run >/dev/null
BEFORE="$(sha256sum "$PREFIX/bin/claude" | cut -d' ' -f1)"
# the server offers an installer cut in half, wearing its sentinel
{ head -c 9000 "$HERE/../install.sh"; printf '\n# CLAUDE_CODE_TERMUX_COMPLETE_MARKER\n'; } > "$SRV/install.sh"
bash "$PREFIX/bin/claude-termux-update" > "$WORK/upd.log" 2>&1
UPD_RC=$?
assert_eq "the updater refuses a truncated installer" "1" "$UPD_RC"
assert_contains "and says nothing was changed" "Nothing was changed" "$(cat "$WORK/upd.log")"
assert_eq "and the working claude is untouched" "$BEFORE" "$(sha256sum "$PREFIX/bin/claude" | cut -d' ' -f1)"

# the server offers an HTML error page
printf '<html>404</html>' > "$SRV/install.sh"
bash "$PREFIX/bin/claude-termux-update" > "$WORK/upd.log" 2>&1
assert_eq "the updater refuses an HTML page" "1" "$?"
assert_eq "and claude is still untouched" "$BEFORE" "$(sha256sum "$PREFIX/bin/claude" | cut -d' ' -f1)"

# the server offers the real thing
cp "$HERE/../install.sh" "$SRV/install.sh"
bash "$PREFIX/bin/claude-termux-update" > "$WORK/upd.log" 2>&1
assert_contains "a whole installer passes all four checks" "sentinel present" "$(cat "$WORK/upd.log")"
assert_contains "and the updater then actually installs" "installing, mode native" "$(cat "$WORK/upd.log")"

# ============================= PROOT: THE DISTRO IS ALREADY INSTALLED =======
# MEASURED on a phone, 12.9.2026. proot-distro 5.8.0 did not report the
# installed rootfs through "list --installed", so the installer tried a fresh
# install, got "Error: container 'ubuntu' already exists", and stopped. A
# working Ubuntu was sitting right there.
fresh_env
PD="$STUBS/proot-distro"
cat > "$PD" <<'S'
#!/bin/bash
case "$1" in
  list)    exit 0 ;;                      # says nothing, like 5.8.0
  install) echo "Error: container 'ubuntu' already exists. Specify a different name with '--name NAME'." >&2; exit 1 ;;
  login)   exit 0 ;;
esac
exit 0
S
chmod +x "$PD"
mkdir -p "$PREFIX/var/lib/proot-distro/installed-rootfs/ubuntu"
bash "$HERE/../install.sh" --proot --yes >"$WORK/proot.log" 2>&1
# The sandbox has no $PREFIX/bin/bash, so the final verify cannot succeed here
# and the exit code says nothing. What matters is that the run got PAST the
# rootfs step instead of stopping on it.
assert_not_contains "an already-installed rootfs does not stop the install" \
  "rootfs did not install" "$(cat "$WORK/proot.log")"
assert_contains "and it says the rootfs is already there" "already here" "$(cat "$WORK/proot.log")"
assert_contains "and it carried on to write the commands" "Writing the commands" "$(cat "$WORK/proot.log")"
assert_ok "the launcher was written" test -x "$PREFIX/bin/claude"

# and when the listing is silent AND the directory is missing, a real failure
# must still stop it
fresh_env
rm -rf "$PREFIX/var/lib/proot-distro"
cat > "$STUBS/proot-distro" <<'S'
#!/bin/bash
case "$1" in
  list)    exit 0 ;;
  install) echo "Error: failed to download rootfs tarball" >&2; exit 1 ;;
esac
exit 0
S
chmod +x "$STUBS/proot-distro"
bash "$HERE/../install.sh" --proot --yes >"$WORK/proot2.log" 2>&1
assert_eq "a genuine rootfs failure still stops the install" "1" "$?"
assert_contains "and says which step failed" "rootfs did not install" "$(cat "$WORK/proot2.log")"
rm -f "$STUBS/proot-distro"

t_summary "TEST 3"
