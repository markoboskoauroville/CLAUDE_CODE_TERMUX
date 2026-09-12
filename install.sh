#!/usr/bin/env bash
#
# CLAUDE_CODE_TERMUX — install Claude Code on Android / Termux
# Version 2 (whole numbers only, per versioning.md)
#
#   curl -fsSL https://raw.githubusercontent.com/markoboskoauroville/CLAUDE_CODE_TERMUX/main/install.sh -o cct.sh
#   bash cct.sh
#
# Options:
#   --native      patched linux-arm64 binary on Termux glibc   (~600 MB)
#   --proot       official installer inside Ubuntu via proot   (~2.5 GB)
#   --update      re-download and re-patch the newest build
#   --extras      also install node, python, openssh
#   --rollback    switch back to the previously installed build
#   --quiet       fewer lines (progress bars stay)
#   --help
#
# Everything is wrapped in cct_main and called on the last line. A truncated
# download therefore does nothing at all instead of installing half an app.
# (termux-app.md section 10: bash -n is not a completeness check.)

cct_main() {

set -uo pipefail

CCT_VERSION=2
CDN="https://downloads.claude.ai/claude-code-releases"
PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
BIN_DIR="$PREFIX/bin"
OPT_DIR="$PREFIX/opt/claude-code"
STAGE=""
DISTRO="ubuntu"
LOG="${TMPDIR:-/tmp}/cct-install.log"

MODE=""
UPDATE=0
EXTRAS=0
ROLLBACK=0
QUIET=0
STEP=0
STEPS=7
WAKELOCK=0
GLIBC_LIB=""

# ---------------------------------------------------------------- colours ---
# design-language.md: green means on, amber means the active thing, red means
# stop. Colour only when stdout is a terminal (termux-app.md section 9).
if [ -t 1 ]; then
  C_G=$'\033[38;5;35m'; C_A=$'\033[38;5;214m'; C_R=$'\033[38;5;167m'
  C_D=$'\033[38;5;244m'; C_B=$'\033[1m'; C_0=$'\033[0m'
else
  C_G=""; C_A=""; C_R=""; C_D=""; C_B=""; C_0=""
fi

log()  { printf '%s\n' "$*" >> "$LOG" 2>/dev/null || true; }
out()  { printf '%s\n' "$*"; log "$*"; }
step() { STEP=$((STEP+1)); out ""; out "${C_A}[$STEP/$STEPS]${C_0} ${C_B}$*${C_0}"; }
info() { [ "$QUIET" = 1 ] || out "      $*"; }
ok()   { out "      ${C_G}ok${C_0}   $*"; }
bad()  { out "      ${C_R}fail${C_0} $*"; }
note() { out "      ${C_A}note${C_0} $*"; }
die()  { out ""; out "${C_R}stopped:${C_0} $*"; out "      full log: $LOG"; exit 1; }

# ------------------------------------------------------- terminal safety ---
# termux-app.md section 8: arm the trap BEFORE the first stty, not after.
CURSOR_HIDDEN=0
cct_cleanup() {
  local rc=$?
  [ "$CURSOR_HIDDEN" = 1 ] && printf '\033[?25h'
  [ -t 0 ] && stty sane 2>/dev/null
  [ -n "$STAGE" ] && [ -d "$STAGE" ] && rm -rf "$STAGE"
  if [ "$WAKELOCK" = 1 ] && command -v termux-wake-unlock >/dev/null 2>&1; then
    termux-wake-unlock >/dev/null 2>&1
  fi
  if [ "$rc" -gt 1 ]; then
    printf '\n%s\n' "${C_R}interrupted (code $rc)${C_0} — nothing was left half-installed."
  fi
  return $rc
}
trap cct_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ------------------------------------------------------------- progress ----
# A bar that moves on elapsed time, printed beside the command that is running.
# Its purpose is to prove the script is alive during apt and proot, which can
# print nothing for minutes at a stretch.
bar_line() {
  local pct="$1" label="$2" secs="$3" width=24 filled empty
  filled=$(( pct * width / 100 ))
  [ "$filled" -gt "$width" ] && filled=$width
  [ "$filled" -lt 0 ] && filled=0
  empty=$(( width - filled ))
  printf '\r      %s%s%s%s%s %3d%%  %s %ss   ' \
    "$C_A" "$(printf '%*s' "$filled" '' | tr ' ' '#')" \
    "$C_D" "$(printf '%*s' "$empty" '' | tr ' ' '.')" "$C_0" \
    "$pct" "$label" "$secs"
}

# run_watched <label> <expected_seconds> <command...>
# Shows a live bar and the elapsed time, then prints the real outcome. On
# failure the last 25 lines of output are shown — silent-failure.md: a failure
# nobody sees is the expensive kind.
run_watched() {
  local label="$1" expect="$2"; shift 2
  local tmp; tmp="$(mktemp)"
  log "--- $label: $* ---"
  ( "$@" >"$tmp" 2>&1 ) &
  local pid=$! secs=0 pct=0 denom start
  denom=$expect; [ "$denom" -lt 1 ] && denom=30
  start=$(date +%s)
  if [ -t 1 ]; then printf '\033[?25l'; CURSOR_HIDDEN=1; fi
  # Polled five times a second so the bar moves, but elapsed time is read from
  # the clock, never counted in loop iterations.
  while kill -0 "$pid" 2>/dev/null; do
    secs=$(( $(date +%s) - start ))
    pct=$(( secs * 90 / denom ))
    [ "$pct" -gt 95 ] && pct=95
    [ -t 1 ] && bar_line "$pct" "$label" "$secs"
    sleep 0.2
  done
  wait "$pid"; local rc=$?
  secs=$(( $(date +%s) - start ))
  if [ -t 1 ]; then bar_line 100 "$label" "$secs"; printf '\033[?25h\r\033[K'; CURSOR_HIDDEN=0; fi
  cat "$tmp" >> "$LOG" 2>/dev/null || true
  if [ "$rc" -eq 0 ]; then
    ok "$label (${secs}s)"
  else
    bad "$label (${secs}s, exit $rc)"
    out ""
    tail -25 "$tmp" | sed "s/^/      ${C_D}| ${C_0}/"
    out ""
  fi
  rm -f "$tmp"
  return $rc
}

have() { command -v "$1" >/dev/null 2>&1; }

# --------------------------------------------------------------- options ---
for arg in "$@"; do
  case "$arg" in
    --native)   MODE="native" ;;
    --proot)    MODE="proot" ;;
    --update)   UPDATE=1 ;;
    --extras)   EXTRAS=1 ;;
    --rollback) ROLLBACK=1 ;;
    --quiet)    QUIET=1 ;;
    -h|--help)  sed -n '3,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
    *) printf '%s\n' "unknown option: $arg (try --help)" >&2; return 1 ;;
  esac
done

: > "$LOG" 2>/dev/null || LOG=/dev/null

printf '\n%s\n' "${C_B}CLAUDE_CODE_TERMUX v$CCT_VERSION${C_0}  ${C_D}Claude Code for Android / Termux${C_0}"
printf '%s\n' "${C_D}log: $LOG${C_0}"

# ============================================================== STEP 1 =====
# The dependency table, printed before anything is decided and before anything
# is written. termux-app.md section 9: the installer is the only interface it has.
dep_table() {
  step "Environment and dependencies"
  local missing=0 present=0 total=0

  check_row() { # name  state(ok|missing|note)  detail
    total=$((total+1))
    case "$2" in
      ok)      present=$((present+1)); printf '      %-16s %sok%s      %s\n' "$1" "$C_G" "$C_0" "$3" ;;
      missing) missing=$((missing+1)); printf '      %-16s %smissing%s %s\n' "$1" "$C_A" "$C_0" "$3" ;;
      *)       printf '      %-16s %s%s%s\n' "$1" "$C_D" "$3" "$C_0" ;;
    esac
  }

  printf '\n      %-16s %-8s %s\n' "WHAT" "STATE" "DETAIL"
  printf '      %s\n' "${C_D}------------------------------------------------------${C_0}"

  if [ -n "${PREFIX:-}" ] && [ -d "$PREFIX/bin" ]; then
    case "$PREFIX" in
      *com.termux*) check_row "termux" ok "$PREFIX" ;;
      *)            check_row "termux" note "PREFIX=$PREFIX, not Termux — continuing" ;;
    esac
  else
    check_row "termux" missing "no PREFIX"
    die "this installer only runs inside Termux"
  fi

  local machine; machine="$(uname -m)"
  case "$machine" in
    aarch64|arm64) check_row "architecture" ok "$machine" ;;
    armv7l|armv8l) check_row "architecture" missing "$machine is a 32-bit userland"
                   die "$machine cannot run Claude Code. 64-bit ARM is required." ;;
    *)             check_row "architecture" missing "$machine"
                   die "unsupported architecture: $machine" ;;
  esac

  check_row "android" note "$(getprop ro.build.version.release 2>/dev/null || echo unknown)"

  local free_mb; free_mb=$(df -Pm "$HOME" 2>/dev/null | awk 'NR==2{print $4}')
  if [ -n "$free_mb" ]; then
    if [ "$free_mb" -lt 800 ]; then
      check_row "free space" missing "${free_mb} MB (native needs ~600, proot ~2500)"
    else
      check_row "free space" ok "${free_mb} MB"
    fi
  else
    check_row "free space" note "could not measure"
  fi

  local tool
  for tool in curl sha256sum git; do
    if have "$tool"; then check_row "$tool" ok "$(command -v "$tool")"
    else check_row "$tool" missing "will be installed"; fi
  done
  for tool in python3 jq ripgrep patchelf proot-distro; do
    if have "$tool"; then check_row "$tool" ok "$(command -v "$tool")"
    else check_row "$tool" missing "installed only if the chosen path needs it"; fi
  done

  if curl -fsS --max-time 20 -o /dev/null "$CDN/latest" 2>>"$LOG"; then
    check_row "claude CDN" ok "downloads.claude.ai reachable"
  else
    check_row "claude CDN" missing "unreachable"
    die "cannot reach $CDN — check the network, and check Anthropic serves your region: https://www.anthropic.com/supported-countries"
  fi

  printf '      %s\n\n' "${C_D}------------------------------------------------------${C_0}"
  # four-tests.md meta-rule 5: print the count, never an adjective.
  out "      checked ${C_B}$total${C_0} items — ${C_G}$present ok${C_0}, ${C_A}$missing to install${C_0}"
}

# ============================================================== STEP 2 =====
choose_mode() {
  step "Choosing an install path"
  if [ "$ROLLBACK" = 1 ]; then MODE="rollback"; ok "rollback requested"; return 0; fi
  if [ -n "$MODE" ]; then ok "requested on the command line: --$MODE"; return 0; fi

  if [ ! -t 0 ]; then
    MODE="native"
    note "no interactive terminal (piped from curl) — defaulting to native"
    note "for the other path, download first: bash cct.sh --proot"
    return 0
  fi

  cat <<MENU

      ${C_B}1) native${C_0}   ~600 MB, starts instantly.
                  Anthropic's linux-arm64 binary with its ELF interpreter
                  repointed at Termux glibc. A compatibility shim: an
                  upstream change can break it until this script catches up.

      ${C_B}2) proot${C_0}    ~2500 MB, a second or two slower to start.
                  Anthropic's own installer inside an Ubuntu rootfs.
                  A real glibc userland, so nothing is patched.

MENU
  local reply=""
  read -r -p "      choose 1 or 2 [1]: " reply
  case "${reply:-1}" in
    1|native) MODE="native"; ok "native" ;;
    2|proot)  MODE="proot";  ok "proot" ;;
    *) die "invalid choice: $reply" ;;
  esac
}

# ============================================================== STEP 3 =====
wake_lock() {
  if have termux-wake-lock; then
    termux-wake-lock >/dev/null 2>&1 && WAKELOCK=1 && info "wake lock held for the duration"
  else
    note "termux-api not installed — keep Termux in the foreground or Android may kill the download"
  fi
}

base_packages() {
  step "Termux packages"
  wake_lock
  run_watched "apt-get update" 45 \
    bash -c 'DEBIAN_FRONTEND=noninteractive apt-get update -y' \
    || note "package lists may be stale — continuing"

  info "installing: curl ca-certificates git which coreutils ripgrep"
  run_watched "install base packages" 90 \
    bash -c 'DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates git which coreutils ripgrep' \
    || die "could not install base packages — see $LOG"

  if [ "$EXTRAS" = 1 ]; then
    info "installing extras: nodejs-lts python openssh jq zstd"
    run_watched "install extras" 120 \
      bash -c 'DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs-lts python openssh jq zstd' \
      || note "some extras failed — not fatal"
  else
    run_watched "install jq and zstd" 40 \
      bash -c 'DEBIAN_FRONTEND=noninteractive apt-get install -y jq zstd' \
      || note "jq/zstd unavailable — the fallback manifest parser will be used"
  fi
}

# ============================================================ STEPS 4-7 ====
manifest_field() {
  local field="$1"
  if have python3; then
    python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["platforms"]["linux-arm64"].get(sys.argv[1],""))' "$field"
  elif have jq; then
    jq -r ".platforms[\"linux-arm64\"].$field // empty"
  else
    tr -d '\n\r\t' \
      | grep -o "\"linux-arm64\"[[:space:]]*:[[:space:]]*{[^{}]*}" \
      | grep -o "\"$field\"[[:space:]]*:[[:space:]]*\"\{0,1\}[^,\"}]*" \
      | sed 's/.*[:"]//'
  fi
}

install_native() {
  step "glibc compatibility layer"
  run_watched "enable tur-repo" 40 \
    bash -c 'DEBIAN_FRONTEND=noninteractive apt-get install -y tur-repo' \
    || note "tur-repo may already be enabled"
  run_watched "refresh package lists" 40 \
    bash -c 'DEBIAN_FRONTEND=noninteractive apt-get update -y' || true
  run_watched "install glibc-runner and patchelf" 180 \
    bash -c 'DEBIAN_FRONTEND=noninteractive apt-get install -y glibc-runner patchelf' \
    || die "could not install glibc-runner — try: pkg install tur-repo && pkg install glibc-runner"

  local ld="" candidate
  for candidate in "$PREFIX/glibc/lib/ld-linux-aarch64.so.1" "$PREFIX/opt/glibc/lib/ld-linux-aarch64.so.1"; do
    [ -e "$candidate" ] && ld="$candidate" && break
  done
  [ -z "$ld" ] && ld="$(find "$PREFIX" -name 'ld-linux-aarch64.so.1' -type f 2>/dev/null | head -1)"
  [ -n "$ld" ] || die "glibc dynamic linker not found after install — see $LOG"
  GLIBC_LIB="$(dirname "$ld")"
  ok "dynamic linker: $ld"
  info "glibc libraries: $GLIBC_LIB ($(find "$GLIBC_LIB" -maxdepth 1 -name '*.so*' 2>/dev/null | wc -l) objects)"

  step "Download and verify"
  local version manifest checksum size
  version="$(curl -fsSL --max-time 30 "$CDN/latest" | tr -d '\r\n')"
  case "$version" in
    [0-9]*.[0-9]*.[0-9]*) ok "current release: $version" ;;
    *) die "the CDN did not return a version (got ${#version} bytes of something else)" ;;
  esac

  manifest="$(curl -fsSL --max-time 30 "$CDN/$version/manifest.json")"
  checksum="$(printf '%s' "$manifest" | manifest_field checksum | tr -d ' \r\n')"
  size="$(printf '%s' "$manifest" | manifest_field size | tr -d ' \r\n')"
  if [ "${#checksum}" -ne 64 ]; then
    die "no usable linux-arm64 checksum in the manifest — Anthropic may have changed the platform list"
  fi
  ok "expected sha256: ${checksum:0:16}..."
  [ -n "$size" ] && ok "expected size: $(( size / 1048576 )) MB"

  # Nothing touches $PREFIX until this succeeds. termux-app.md section 9.
  STAGE="$(mktemp -d "${TMPDIR:-$PREFIX/tmp}/cct.XXXXXX")" || die "cannot create a staging directory"
  local staged="$STAGE/claude-$version"

  if [ -x "$OPT_DIR/versions/claude-$version" ] && [ "$UPDATE" != 1 ]; then
    ok "$version is already installed and patched — nothing to download"
    cp "$OPT_DIR/versions/claude-$version" "$staged"
  else
    out ""
    info "downloading claude $version for linux-arm64"
    info "curl prints its own progress bar below; on mobile data this is the long part"
    out ""
    # No --max-time: a 230 MB download on mobile data is legitimately slow.
    # Bounded instead by a connect timeout and a stall detector — if throughput
    # drops under 1 KB/s for 60s the transfer is abandoned rather than hanging
    # forever. (delivery-gate.md G5: what can wait forever.)
    curl -fL --progress-bar --retry 3 --retry-delay 2 \
      --connect-timeout 30 --speed-limit 1024 --speed-time 60 \
      -o "$staged" "$CDN/$version/linux-arm64/claude" || die "download failed or stalled — see $LOG"
    out ""
  fi

  info "verifying sha256 over $(du -m "$staged" | cut -f1) MB"
  local actual; actual="$(sha256sum "$staged" | cut -d' ' -f1)"
  if [ "$actual" != "$checksum" ]; then
    bad "expected $checksum"
    bad "actual   $actual"
    die "checksum mismatch — this is not what Anthropic published. Nothing was installed."
  fi
  ok "checksum verified"

  step "Patching for Android"
  chmod +x "$staged"
  # Only the interpreter is rewritten. The library path is supplied at runtime
  # by the launcher, so patchelf never has to move section headers on a binary
  # that carries an appended payload.
  patchelf --set-interpreter "$ld" "$staged" || die "patchelf failed — see $LOG"
  local now; now="$(patchelf --print-interpreter "$staged" 2>/dev/null)"
  [ "$now" = "$ld" ] || die "patchelf returned success but the interpreter is still '$now'"
  ok "interpreter: $now"

  step "Installing"
  mkdir -p "$OPT_DIR/versions"
  # Rename, never truncate: the file being replaced may be running right now.
  # termux-app.md section 4.
  mv "$staged" "$OPT_DIR/versions/claude-$version.new" || die "could not stage into $OPT_DIR"
  mv -f "$OPT_DIR/versions/claude-$version.new" "$OPT_DIR/versions/claude-$version"
  chmod +x "$OPT_DIR/versions/claude-$version"

  if [ -L "$OPT_DIR/current" ]; then
    local prev; prev="$(readlink "$OPT_DIR/current")"
    if [ "$prev" != "$OPT_DIR/versions/claude-$version" ] && [ -x "$prev" ]; then
      ln -sfn "$prev" "$OPT_DIR/previous"
      info "rollback target kept: $(basename "$prev")"
    fi
  fi
  ln -sfn "$OPT_DIR/versions/claude-$version" "$OPT_DIR/current.new"
  mv -f "$OPT_DIR/current.new" "$OPT_DIR/current"
  ok "current -> claude-$version"

  write_native_launcher
  prune_versions
}

write_native_launcher() {
  local tmp="$BIN_DIR/.claude.$$"
  mkdir -p "$BIN_DIR"
  cat > "$tmp" <<WRAPPER
#!$PREFIX/bin/bash
# Claude Code launcher for Termux — CLAUDE_CODE_TERMUX v$CCT_VERSION
export LD_LIBRARY_PATH="$GLIBC_LIB\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
# Android has no /tmp, and Claude Code needs somewhere writable.
export TMPDIR="\${TMPDIR:-$PREFIX/tmp}"
mkdir -p "\$TMPDIR"
# Termux's own ripgrep, not the glibc one packed inside the binary.
export USE_BUILTIN_RIPGREP=0
# The built-in updater would replace this patched binary with one that cannot
# start on Android. Use claude-termux-update instead.
export DISABLE_AUTOUPDATER=1
exec "$OPT_DIR/current" "\$@"
WRAPPER
  chmod +x "$tmp"
  mv -f "$tmp" "$BIN_DIR/claude"

  tmp="$BIN_DIR/.claude-termux-update.$$"
  cat > "$tmp" <<'UPDATER'
#!/usr/bin/env bash
# Fetch the installer to a file, check it is complete, then run it.
# Never pipe an updater straight into bash: a truncated download parses fine
# and installs half an app. termux-app.md section 10.
set -euo pipefail
URL="https://raw.githubusercontent.com/markoboskoauroville/CLAUDE_CODE_TERMUX/main/install.sh"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
echo "==> fetching the installer"
curl -fsSL --max-time 60 -o "$TMP" "$URL"
echo "==> $(wc -c < "$TMP") bytes, $(wc -l < "$TMP") lines"
bash -n "$TMP" || { echo "installer does not parse — aborting"; exit 1; }
grep -q '^# CCT_COMPLETE_V2$' "$TMP" || { echo "installer is truncated — aborting"; exit 1; }
echo "==> complete, and it parses"
exec bash "$TMP" --native --update "$@"
UPDATER
  chmod +x "$tmp"
  mv -f "$tmp" "$BIN_DIR/claude-termux-update"
  ok "claude and claude-termux-update installed in $BIN_DIR"
}

prune_versions() {
  # versioning.md: only two artefacts kept.
  local keep_prev; keep_prev="$(readlink "$OPT_DIR/previous" 2>/dev/null || echo '')"
  local old
  if [ -d "$OPT_DIR/versions" ]; then
    ( cd "$OPT_DIR/versions" && ls -1t 2>/dev/null | tail -n +3 ) | while read -r old; do
      [ -z "$old" ] && continue
      [ "$OPT_DIR/versions/$old" = "$keep_prev" ] && continue
      rm -f "$OPT_DIR/versions/$old"
    done
  fi
  info "builds on disk: $(ls -1 "$OPT_DIR/versions" 2>/dev/null | wc -l)"
}

install_proot() {
  step "proot-distro"
  run_watched "install proot-distro" 60 \
    bash -c 'DEBIAN_FRONTEND=noninteractive apt-get install -y proot-distro' \
    || die "could not install proot-distro"

  if proot-distro list --installed 2>/dev/null | grep -q "$DISTRO"; then
    ok "$DISTRO rootfs already present"
  else
    step "Ubuntu rootfs"
    info "a few hundred MB — proot-distro prints its own progress below"
    proot-distro install "$DISTRO" || die "proot-distro install $DISTRO failed"
    ok "$DISTRO installed"
  fi

  step "Claude Code inside Ubuntu"
  run_watched "apt update inside ubuntu" 90 \
    proot-distro login "$DISTRO" --termux-home -- bash -lc \
      'export DEBIAN_FRONTEND=noninteractive; apt-get update -y' || note "continuing"
  run_watched "dependencies inside ubuntu" 120 \
    proot-distro login "$DISTRO" --termux-home -- bash -lc \
      'export DEBIAN_FRONTEND=noninteractive; apt-get install -y curl ca-certificates git ripgrep less' \
    || die "could not install dependencies inside $DISTRO"
  run_watched "anthropic installer" 300 \
    proot-distro login "$DISTRO" --termux-home -- bash -lc \
      'curl -fsSL --connect-timeout 30 --speed-limit 1024 --speed-time 120 https://claude.ai/install.sh | bash' \
    || die "Anthropic's installer failed inside $DISTRO — see $LOG"
  proot-distro login "$DISTRO" --termux-home -- bash -lc \
    'grep -q ".local/bin" "$HOME/.bashrc" 2>/dev/null || echo "export PATH=\"\$HOME/.local/bin:\$PATH\"" >> "$HOME/.bashrc"' \
    >/dev/null 2>&1

  step "Installing"
  local tmp="$BIN_DIR/.claude.$$"
  cat > "$tmp" <<WRAPPER
#!$PREFIX/bin/bash
# Claude Code launcher for Termux (proot path) — CLAUDE_CODE_TERMUX v$CCT_VERSION
exec proot-distro login $DISTRO --termux-home -- bash -lc \\
  'export PATH="\$HOME/.local/bin:\$PATH"; exec claude "\$@"' claude "\$@"
WRAPPER
  chmod +x "$tmp"; mv -f "$tmp" "$BIN_DIR/claude"

  tmp="$BIN_DIR/.claude-termux-update.$$"
  cat > "$tmp" <<WRAPPER
#!$PREFIX/bin/bash
exec proot-distro login $DISTRO --termux-home -- bash -lc \\
  'export PATH="\$HOME/.local/bin:\$PATH"; claude update'
WRAPPER
  chmod +x "$tmp"; mv -f "$tmp" "$BIN_DIR/claude-termux-update"
  ok "claude and claude-termux-update installed in $BIN_DIR"
}

do_rollback() {
  step "Rollback"
  [ -L "$OPT_DIR/previous" ] || die "no previous build recorded — nothing to roll back to"
  local target; target="$(readlink "$OPT_DIR/previous")"
  [ -x "$target" ] || die "the recorded previous build is gone: $target"
  ln -sfn "$target" "$OPT_DIR/current.new"
  mv -f "$OPT_DIR/current.new" "$OPT_DIR/current"
  ok "current -> $(basename "$target")"
}

verify() {
  step "Verifying"
  local text rc
  text="$("$BIN_DIR/claude" --version 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    ok "claude --version -> $text"
    return 0
  fi
  bad "claude --version exited $rc"
  printf '%s\n' "$text" | sed "s/^/      ${C_D}| ${C_0}/"
  note "the launcher is installed but did not run. See Troubleshooting in the README."
  return 1
}

# ------------------------------------------------------------------ main ---
dep_table
choose_mode
[ "$MODE" = "rollback" ] || base_packages

case "$MODE" in
  native)   STEPS=8; install_native ;;
  proot)    STEPS=7; install_proot ;;
  rollback) STEPS=3; do_rollback ;;
esac

verify_rc=0
verify || verify_rc=1

out ""
out "${C_B}Installed:${C_0} $MODE"
out ""
out "      start it with        ${C_B}claude${C_0}"
out "      update later with    ${C_B}claude-termux-update${C_0}"
[ "$MODE" = "native" ] && out "      go back a version    ${C_B}bash cct.sh --rollback${C_0}"
out "      remove it with       ${C_B}bash uninstall.sh${C_0}"
out ""
out "      First run opens a browser to log in. Claude Code needs a paid Claude"
out "      plan (Pro, Max, Team, Enterprise) or a Console API key."
out ""
out "${C_D}      log: $LOG${C_0}"

return $verify_rc
}

# Last line, and the completeness marker the updater greps for.
cct_main "$@"
# CCT_COMPLETE_V2
