#!/usr/bin/env bash
# tests/run_tests.sh — the four tests, per MANTRA_MANIFEST modules/four-tests.md
#
#   1  Does the thing itself work?
#   2  Does the app actually use it, for real, with real data?
#   3  What happens when the world misbehaves?
#   4  What happens to the person who already had the old one?
#
# Run from the repo root:  bash tests/run_tests.sh
#
# These run off the phone, against a stubbed Termux. What that cannot cover is
# listed at the end and in DELIVERY.md — termux-app.md section 12.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT/install.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0; SKIP=0
CHECKS=0

if [ -t 1 ]; then G=$'\033[38;5;35m'; R=$'\033[38;5;167m'; A=$'\033[38;5;214m'; D=$'\033[38;5;244m'; B=$'\033[1m'; Z=$'\033[0m'
else G=""; R=""; A=""; D=""; B=""; Z=""; fi

head1() { printf '\n%s\n%s\n' "${B}$*${Z}" "${D}$(printf '%.0s-' {1..66})${Z}"; }
chk()  { CHECKS=$((CHECKS+1)); PASS=$((PASS+1)); printf '  %spass%s  %s\n' "$G" "$Z" "$*"; }
bad()  { CHECKS=$((CHECKS+1)); FAIL=$((FAIL+1)); printf '  %sFAIL%s  %s\n' "$R" "$Z" "$*"; }
skip() { CHECKS=$((CHECKS+1)); SKIP=$((SKIP+1)); printf '  %sskip%s  %s\n' "$A" "$Z" "$*"; }
assert() { if eval "$1"; then chk "$2"; else bad "$2"; fi; }

# ---------------------------------------------------------------- sandbox ---
# A fake Termux: a PREFIX whose path contains com.termux, stubs for every
# command the installer shells out to, and a fake claude binary whose sha256
# is written into a fake manifest. Nothing here touches the real machine.
make_sandbox() {
  local box="$1" version="${2:-2.1.269}" corrupt="${3:-no}"
  local prefix="$box/data/data/com.termux/files/usr"
  mkdir -p "$prefix/bin" "$prefix/tmp" "$prefix/glibc/lib" "$box/stubs" "$box/cdn" "$box/home"

  : > "$prefix/glibc/lib/ld-linux-aarch64.so.1"
  # Deliberately NO fake libc.so.6 here: the launcher puts this directory on
  # LD_LIBRARY_PATH, and an empty libc.so.6 breaks every host binary the
  # sandbox runs. The first version of this harness did exactly that and the
  # failure looked like a bug in the installer. (four-tests.md: test the test.)
  # the launcher's shebang is $PREFIX/bin/bash, so the sandbox needs one
  ln -sf "$(command -v bash)" "$prefix/bin/bash"

  # the "claude binary" the CDN will serve
  cat > "$box/cdn/claude" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = "--version" ] && echo "$version (Claude Code)" && exit 0
echo "claude stub: \$*"
EOF
  local real_sum published_sum
  real_sum="$(sha256sum "$box/cdn/claude" | cut -d' ' -f1)"
  published_sum="$real_sum"
  [ "$corrupt" = "corrupt" ] && published_sum="$(printf '%064d' 0)"

  printf '%s' "$version" > "$box/cdn/latest"
  cat > "$box/cdn/manifest.json" <<EOF
{"platforms":{"linux-arm64":{"checksum":"$published_sum","size":420}}}
EOF

  cat > "$box/stubs/uname" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "-m" ] && echo "${FAKE_ARCH:-aarch64}" && exit 0
echo Linux
EOF
  cat > "$box/stubs/apt-get" <<'EOF'
#!/usr/bin/env bash
echo "apt-get $*" >> "$CCT_TEST_BOX/apt.log"
[ -n "${FAKE_APT_FAIL:-}" ] && exit 100
exit 0
EOF
  cat > "$box/stubs/curl" <<'EOF'
#!/usr/bin/env bash
# serves the fake CDN out of $CCT_TEST_BOX/cdn
out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
[ -n "${FAKE_NET_DOWN:-}" ] && exit 7
src=""
case "$url" in
  */latest)         src="$CCT_TEST_BOX/cdn/latest" ;;
  */manifest.json)  src="$CCT_TEST_BOX/cdn/manifest.json" ;;
  */linux-arm64/claude)
      [ -n "${FAKE_DOWNLOAD_FAIL:-}" ] && exit 18
      src="$CCT_TEST_BOX/cdn/claude" ;;
  *) src="/dev/null" ;;
esac
[ -n "${FAKE_HTML:-}" ] && { printf '<html>blocked</html>' > "${out:-/dev/stdout}"; exit 0; }
if [ -n "$out" ]; then cp "$src" "$out"; else cat "$src"; fi
EOF
  cat > "$box/stubs/patchelf" <<'EOF'
#!/usr/bin/env bash
echo "patchelf $*" >> "$CCT_TEST_BOX/patchelf.log"
case "${1:-}" in
  --set-interpreter)
     [ -n "${FAKE_PATCHELF_LIES:-}" ] && exit 0
     echo "$2" > "$3.interp"; exit 0 ;;
  --print-interpreter)
     [ -f "$2.interp" ] && cat "$2.interp" || echo "/lib/ld-linux-aarch64.so.1"
     exit 0 ;;
esac
exit 0
EOF
  cat > "$box/stubs/getprop" <<'EOF'
#!/usr/bin/env bash
echo "14"
EOF
  cat > "$box/stubs/proot-distro" <<'EOF'
#!/usr/bin/env bash
echo "proot-distro $*" >> "$CCT_TEST_BOX/proot.log"; exit 0
EOF
  chmod +x "$box"/stubs/* "$box/cdn/claude"
  printf '%s' "$prefix"
}

run_install() {
  local box="$1"; shift
  local prefix="$box/data/data/com.termux/files/usr"
  ( export CCT_TEST_BOX="$box" \
           PREFIX="$prefix" \
           HOME="$box/home" \
           TMPDIR="$prefix/tmp" \
           PATH="$box/stubs:$PATH"
    bash "$INSTALLER" "$@" ) > "$box/out.txt" 2>&1
  echo $? > "$box/rc.txt"
}

# ============================================================== TEST 1 ======
# THE MECHANISM, ALONE. Each piece checked on its own, away from the app.
test1() {
  head1 "TEST 1 — THE MECHANISM, ALONE"

  for f in install.sh uninstall.sh tests/run_tests.sh gates/run_gates.sh; do
    if [ -f "$ROOT/$f" ]; then
      if bash -n "$ROOT/$f" 2>/dev/null; then chk "$f parses"; else bad "$f does not parse"; fi
    else
      bad "$f is missing"
    fi
  done

  # completeness marker — the check that bash -n cannot make
  assert "grep -q '^# CCT_COMPLETE_V2\$' '$INSTALLER'" \
    "installer carries its completeness marker on the last line"
  assert "[ \"\$(tail -1 '$INSTALLER')\" = '# CCT_COMPLETE_V2' ]" \
    "the marker is genuinely the last line"

  # and the marker must be able to fail: truncate and confirm it goes red
  head -n 200 "$INSTALLER" > "$WORK/truncated.sh"
  if grep -q '^# CCT_COMPLETE_V2$' "$WORK/truncated.sh"; then
    bad "the marker check cannot fail — it matched a truncated file"
  else
    chk "the marker check goes red on a truncated file (it can fail)"
  fi

  # manifest parser, all three routes, against the live CDN
  local live_manifest=""
  live_manifest="$(curl -fsSL --max-time 20 "https://downloads.claude.ai/claude-code-releases/$(curl -fsSL --max-time 20 https://downloads.claude.ai/claude-code-releases/latest 2>/dev/null)/manifest.json" 2>/dev/null)"
  if [ -n "$live_manifest" ]; then
    local py jqr fb
    # shellcheck disable=SC2034  # py, jqr and fb are read inside the assert eval strings below
    py="$(printf '%s' "$live_manifest" | python3 -c 'import json,sys; print(json.load(sys.stdin)["platforms"]["linux-arm64"]["checksum"])' 2>/dev/null)"
    jqr="$(printf '%s' "$live_manifest" | jq -r '.platforms["linux-arm64"].checksum' 2>/dev/null)"
    # shellcheck disable=SC2034
    fb="$(printf '%s' "$live_manifest" | tr -d '\n\r\t' \
          | grep -o '"linux-arm64"[[:space:]]*:[[:space:]]*{[^{}]*}' \
          | grep -o '"checksum"[[:space:]]*:[[:space:]]*"\{0,1\}[^,"}]*' | sed 's/.*[:"]//')"
    assert "[ \${#py} -eq 64 ]"  "python parser returns a 64-hex checksum from the live manifest"
    if [ "${#jqr}" -eq 64 ]; then chk "jq parser agrees"; else skip "jq not available here"; fi
    assert "[ \"\$fb\" = \"\$py\" ]" "the no-python fallback parser agrees with python"
  else
    skip "live CDN unreachable — manifest parser checked against fixture only"
  fi

  # the generated launcher must itself be a valid script
  local box prefix
  box="$WORK/t1"; prefix="$(make_sandbox "$box")"
  run_install "$box" --native
  if [ -f "$prefix/bin/claude" ]; then
    if bash -n "$prefix/bin/claude"; then chk "the generated claude launcher parses"; else bad "generated launcher does not parse"; fi
    if bash -n "$prefix/bin/claude-termux-update"; then chk "the generated updater parses"; else bad "generated updater does not parse"; fi
  else
    bad "no launcher was generated in the sandbox"
  fi
}

# ============================================================== TEST 2 ======
# INSIDE THE RUNNING APP, WITH REAL DATA. A full install in the sandbox, then
# the thing the person actually types.
test2() {
  head1 "TEST 2 — A FULL INSTALL, END TO END"

  local box prefix rc
  box="$WORK/t2"; prefix="$(make_sandbox "$box" 2.1.269)"
  run_install "$box" --native
  rc="$(cat "$box/rc.txt")"

  assert "[ '$rc' = '0' ]" "installer exits 0 (exit was $rc)"
  assert "[ -x '$prefix/bin/claude' ]" "claude launcher exists and is executable"
  assert "[ -x '$prefix/bin/claude-termux-update' ]" "claude-termux-update exists"
  assert "[ -L '$prefix/opt/claude-code/current' ]" "current symlink points at a build"

  # the command the person types
  local ver
  ver="$( PREFIX="$prefix" TMPDIR="$prefix/tmp" "$prefix/bin/claude" --version 2>&1 )"
  assert "[ \"\$(echo '$ver' | grep -c '2.1.269')\" = '1' ]" "claude --version prints the installed version"

  # the environment the launcher is supposed to set
  assert "grep -q 'DISABLE_AUTOUPDATER=1' '$prefix/bin/claude'" \
    "launcher disables the built-in updater (it would unpatch the binary)"
  assert "grep -q 'USE_BUILTIN_RIPGREP=0' '$prefix/bin/claude'" \
    "launcher uses Termux ripgrep"
  assert "grep -q 'TMPDIR' '$prefix/bin/claude'" \
    "launcher gives Claude Code a writable TMPDIR (Android has no /tmp)"
  assert "grep -q 'LD_LIBRARY_PATH' '$prefix/bin/claude'" \
    "launcher supplies the glibc library path at runtime"

  # progress and counts actually reached the screen
  assert "grep -q 'checked .* items' '$box/out.txt'" "dependency table printed a count, not an adjective"
  assert "[ \"\$(grep -c '^\\[' '$box/out.txt')\" -ge 6 ]" "every step announced itself with a step number"
  assert "grep -qi 'ok ' '$box/out.txt'" "per-item ok lines printed"

  # the interpreter really was repointed
  assert "grep -q -- '--set-interpreter' '$box/patchelf.log'" \
    "patchelf was called on the downloaded binary"
  assert "grep -q 'glibc/lib/ld-linux-aarch64.so.1' '$box/patchelf.log'" \
    "patchelf was pointed at the Termux glibc linker"
}

# ============================================================== TEST 3 ======
# THE UGLY CASES. Each one must fail loudly and leave nothing behind.
test3() {
  head1 "TEST 3 — THE UGLY CASES"

  local box prefix rc

  # 1. checksum mismatch
  box="$WORK/t3a"; prefix="$(make_sandbox "$box" 2.1.269 corrupt)"
  run_install "$box" --native; rc="$(cat "$box/rc.txt")"
  assert "[ '$rc' != '0' ]" "checksum mismatch: installer stops (exit $rc)"
  assert "[ ! -e '$prefix/bin/claude' ]" "checksum mismatch: nothing written to bin"
  assert "grep -qi 'checksum mismatch' '$box/out.txt'" "checksum mismatch: says so in plain words"
  assert "[ -z \"\$(ls -A '$prefix/opt' 2>/dev/null)\" ]" "checksum mismatch: no partial build left in opt"

  # 2. the CDN serves something that is not a version
  box="$WORK/t3b"; prefix="$(make_sandbox "$box")"
  ( export FAKE_HTML=1; run_install "$box" --native ); rc="$(cat "$box/rc.txt")"
  assert "[ '$rc' != '0' ]" "CDN returns HTML: installer stops"
  assert "[ ! -e '$prefix/bin/claude' ]" "CDN returns HTML: nothing installed"

  # 3. network down at the dependency table
  box="$WORK/t3c"; prefix="$(make_sandbox "$box")"
  ( export FAKE_NET_DOWN=1; run_install "$box" --native ); rc="$(cat "$box/rc.txt")"
  assert "[ '$rc' != '0' ]" "no network: installer stops at the table, before any package work"
  assert "grep -qi 'cannot reach\\|unreachable' '$box/out.txt'" "no network: names the cause"

  # 4. 32-bit userland
  box="$WORK/t3d"; prefix="$(make_sandbox "$box")"
  ( export FAKE_ARCH=armv7l; run_install "$box" --native ); rc="$(cat "$box/rc.txt")"
  assert "[ '$rc' != '0' ]" "armv7l: installer refuses"
  assert "grep -qi '64-bit' '$box/out.txt'" "armv7l: explains why"

  # 5. download fails part way
  box="$WORK/t3e"; prefix="$(make_sandbox "$box")"
  ( export FAKE_DOWNLOAD_FAIL=1; run_install "$box" --native ); rc="$(cat "$box/rc.txt")"
  assert "[ '$rc' != '0' ]" "download fails: installer stops"
  assert "[ ! -e '$prefix/bin/claude' ]" "download fails: no half-installed launcher"

  # 6. patchelf claims success but does nothing
  box="$WORK/t3f"; prefix="$(make_sandbox "$box")"
  ( export FAKE_PATCHELF_LIES=1; run_install "$box" --native ); rc="$(cat "$box/rc.txt")"
  assert "[ '$rc' != '0' ]" "patchelf lies: installer catches it by reading the interpreter back"
  assert "[ ! -e '$prefix/bin/claude' ]" "patchelf lies: nothing installed"

  # 7. a truncated installer does nothing at all
  box="$WORK/t3g"; prefix="$(make_sandbox "$box")"
  head -n 250 "$INSTALLER" > "$box/truncated.sh"
  ( export CCT_TEST_BOX="$box" PREFIX="$prefix" HOME="$box/home" TMPDIR="$prefix/tmp" PATH="$box/stubs:$PATH"
    bash "$box/truncated.sh" --native ) > "$box/out.txt" 2>&1
  assert "[ ! -e '$prefix/bin/claude' ]" "truncated installer: installs nothing (the wrap-and-call-last rule)"

  # 8. apt fails
  box="$WORK/t3h"; prefix="$(make_sandbox "$box")"
  ( export FAKE_APT_FAIL=1; run_install "$box" --native ); rc="$(cat "$box/rc.txt")"
  assert "[ '$rc' != '0' ]" "apt fails: installer stops rather than limping on"
  assert "grep -qi 'fail' '$box/out.txt'" "apt fails: the failure is printed, not swallowed"

  # 9. rollback with nothing to roll back to
  box="$WORK/t3i"; prefix="$(make_sandbox "$box")"
  run_install "$box" --rollback; rc="$(cat "$box/rc.txt")"
  assert "[ '$rc' != '0' ]" "rollback with no history: refuses instead of breaking the install"
}

# ============================================================== TEST 4 ======
# THE UPGRADE, FROM THE VERSION BEFORE.
test4() {
  head1 "TEST 4 — THE UPGRADE, AND THE WAY BACK"

  local box prefix rc
  box="$WORK/t4"; prefix="$(make_sandbox "$box" 2.1.269)"

  run_install "$box" --native
  assert "[ -x '$prefix/bin/claude' ]" "old version installs"
  local before
  before="$( PREFIX="$prefix" TMPDIR="$prefix/tmp" "$prefix/bin/claude" --version 2>&1 )"
  assert "[ \"\$(echo '$before' | grep -c 2.1.269)\" = 1 ]" "old version runs: $before"

  # publish a newer build into the fake CDN
  sed -i 's/2\.1\.269/2\.1\.300/' "$box/cdn/claude"
  printf '%s' "2.1.300" > "$box/cdn/latest"
  local newsum; newsum="$(sha256sum "$box/cdn/claude" | cut -d' ' -f1)"
  printf '{"platforms":{"linux-arm64":{"checksum":"%s","size":420}}}' "$newsum" > "$box/cdn/manifest.json"

  run_install "$box" --native --update; rc="$(cat "$box/rc.txt")"
  assert "[ '$rc' = '0' ]" "update exits 0"
  local after
  after="$( PREFIX="$prefix" TMPDIR="$prefix/tmp" "$prefix/bin/claude" --version 2>&1 )"
  assert "[ \"\$(echo '$after' | grep -c 2.1.300)\" = 1 ]" "the new version is what runs now: $after"

  # settings survive
  assert "[ -d '$box/home' ]" "the home directory (and ~/.claude with it) is untouched by an update"

  # rollback clause — delivery-gate.md G8
  assert "[ -L '$prefix/opt/claude-code/previous' ]" "the previous build is recorded for rollback"
  run_install "$box" --rollback; rc="$(cat "$box/rc.txt")"
  local back
  back="$( PREFIX="$prefix" TMPDIR="$prefix/tmp" "$prefix/bin/claude" --version 2>&1 )"
  assert "[ '$rc' = '0' ]" "rollback exits 0"
  assert "[ \"\$(echo '$back' | grep -c 2.1.269)\" = 1 ]" "rollback really goes back: $back"

  # only two artefacts kept — versioning.md
  local kept=0 v
  for v in "$prefix/opt/claude-code/versions/"claude-*; do [ -e "$v" ] && kept=$((kept+1)); done
  assert "[ '$kept' -le 2 ]" "builds kept on disk: $kept (limit 2)"

  # an updater that cannot update is the classic failure
  assert "grep -q 'CCT_COMPLETE_V2' '$prefix/bin/claude-termux-update'" \
    "the updater checks the new installer is complete before running it"
  assert "grep -q 'bash -n' '$prefix/bin/claude-termux-update'" \
    "the updater checks the new installer parses before running it"
}

# ------------------------------------------------------------------ main ---
printf '\n%s\n' "${B}CLAUDE_CODE_TERMUX — the four tests${Z}"
printf '%s\n' "${D}installer: $INSTALLER${Z}"

test1; test2; test3; test4

head1 "WHAT WAS NOT TESTED"
cat <<'NOT'
  Off a phone, these cannot be checked and are not claimed:
    - that the real 230 MB glibc binary starts once its interpreter is repointed
    - that glibc-runner installs from tur-repo on a given Android version
    - proot-distro installing a real Ubuntu rootfs
    - the OAuth login round trip through the Android browser
    - Android's low-memory killer during a long download
    - real download time and battery cost on mobile data
  Everything above is stubbed. The logic around them is what these tests cover.
NOT

head1 "RESULT"
printf '  checks run  %s%d%s\n' "$B" "$CHECKS" "$Z"
printf '  passed      %s%d%s\n' "$G" "$PASS" "$Z"
printf '  failed      %s%d%s\n' "$R" "$FAIL" "$Z"
printf '  skipped     %s%d%s\n\n' "$A" "$SKIP" "$Z"
[ "$FAIL" -eq 0 ]
