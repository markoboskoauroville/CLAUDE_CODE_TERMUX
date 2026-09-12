#!/data/data/com.termux/files/usr/bin/bash
#
# CLAUDE_CODE_TERMUX — Claude Code on Android, through Termux.
# edition: v7
#
#   curl -fsSL https://raw.githubusercontent.com/markoboskoauroville/CLAUDE_CODE_TERMUX/main/install.sh | bash
#
# Flags:
#   --native      patched linux-arm64 binary on Termux glibc  (~600 MB)
#   --proot       official installer inside Ubuntu via proot   (~2.5 GB)
#   --update      re-fetch and re-install
#   --extras      also install node, python, openssh
#   --yes         take every default, ask nothing
#   --no-alias    skip the one-letter shortcut
#
# Anthropic ships Claude Code as one glibc-linked binary. The CDN carries
# darwin, linux and win32 builds; there is no android-arm64. Android runs on
# Bionic. --native repoints the ELF interpreter at Termux's glibc-runner;
# --proot runs the official installer inside a real glibc userland.

set -uo pipefail

CCT_EDITION=7
CCT_REPO="markoboskoauroville/CLAUDE_CODE_TERMUX"
# These three are overridable so a fork, a mirror, or a test harness can point
# them elsewhere. The defaults are the real ones.
CCT_RAW="${CCT_RAW:-https://raw.githubusercontent.com/$CCT_REPO/main/install.sh}"
CDN="${CCT_CDN:-https://downloads.claude.ai/claude-code-releases}"

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
BIN_DIR="$PREFIX/bin"
OPT_DIR="$PREFIX/opt/claude-code"
DISTRO="ubuntu"

MODE=""; UPDATE=0; EXTRAS=0; ASSUME_YES=0; WANT_ALIAS=1
STEP=0; STEPS=10
T_START=$(date +%s)

# Every wait on something outside this process carries a deadline.
NET_CONNECT_TIMEOUT="${CCT_CONNECT_TIMEOUT:-20}"
NET_SMALL_TIMEOUT="${CCT_SMALL_TIMEOUT:-60}"
NET_BIG_TIMEOUT="${CCT_BIG_TIMEOUT:-1800}"

# ============================================================ appearance ===
# Colour only when stdout is a terminal, so a piped or logged run stays readable.
if [ -t 1 ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; AMBER=$'\033[38;5;214m'
  GREEN=$'\033[38;5;114m'; RED=$'\033[38;5;174m'; OFF=$'\033[0m'
  TTY=1
else
  BOLD=""; DIM=""; AMBER=""; GREEN=""; RED=""; OFF=""
  TTY=0
fi

elapsed() { printf '%s' "$(( $(date +%s) - T_START ))"; }

step() {
  STEP=$((STEP + 1))
  printf '\n%s[ %d / %d ]%s %s%s%s  %s(%ss elapsed)%s\n' \
    "$AMBER" "$STEP" "$STEPS" "$OFF" "$BOLD" "$1" "$OFF" "$DIM" "$(elapsed)" "$OFF"
}
info() { printf '        %s\n' "$*"; }
ok()   { printf '        %sok%s    %s\n' "$GREEN" "$OFF" "$*"; }
bad()  { printf '        %sno%s    %s\n' "$RED" "$OFF" "$*"; }
note() { printf '        %s%s%s\n' "$DIM" "$*" "$OFF"; }
die()  { printf '\n%sStopped:%s %s\n\n' "$RED" "$OFF" "$*" >&2; exit 1; }

# Stream a command's output indented, so a long install never looks stalled.
run() {
  local label="$1"; shift
  printf '        %srunning%s %s\n' "$DIM" "$OFF" "$label"
  local t0 rc
  t0=$(date +%s)
  "$@" 2>&1 | while IFS= read -r line; do printf '        %s| %s%s\n' "$DIM" "$line" "$OFF"; done
  rc=${PIPESTATUS[0]}
  if [ "$rc" -eq 0 ]; then
    ok "$label  ($(( $(date +%s) - t0 ))s)"
  else
    bad "$label  exit $rc"
  fi
  return "$rc"
}

# -------------------------------------------------------------- progress ---
# Draws a bar from a byte count against a known total.
draw_bar() {
  local now="$1" total="$2" label="$3"
  local width=22 pct=0 filled i bar="" mb_now mb_tot
  [ "$total" -gt 0 ] && pct=$(( now * 100 / total ))
  [ "$pct" -gt 100 ] && pct=100
  [ "$pct" -lt 0 ] && pct=0
  filled=$(( pct * width / 100 ))
  for ((i=0; i<width; i++)); do
    if [ "$i" -lt "$filled" ]; then bar="$bar#"; else bar="$bar."; fi
  done
  mb_now=$(( now / 1048576 )); mb_tot=$(( total / 1048576 ))
  if [ "$TTY" = "1" ]; then
    printf '\r        %s[%s]%s %3d%%  %s/%s MB  %s' \
      "$AMBER" "$bar" "$OFF" "$pct" "$mb_now" "$mb_tot" "$label"
  else
    printf '        [%s] %3d%%  %s/%s MB  %s\n' "$bar" "$pct" "$mb_now" "$mb_tot" "$label"
  fi
}

# Download with a live bar. Polls the partial file rather than trusting curl's
# own meter, so the number on screen is the number of bytes really on disk.
download_bar() {
  local url="$1" out="$2" total="$3" label="$4"
  local last_line_at=0 pid rc now t final
  rm -f "$out"
  curl -fsSL --connect-timeout "$NET_CONNECT_TIMEOUT" --max-time "$NET_BIG_TIMEOUT" \
       -o "$out" "$url" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    now=0
    [ -f "$out" ] && now=$(stat -c %s "$out" 2>/dev/null || echo 0)
    if [ "$TTY" = "1" ]; then
      draw_bar "$now" "$total" "$label"
    else
      t=$(date +%s)
      if [ $(( t - last_line_at )) -ge 10 ]; then draw_bar "$now" "$total" "$label"; last_line_at=$t; fi
    fi
    sleep 1
  done
  wait "$pid"; rc=$?
  final=0; [ -f "$out" ] && final=$(stat -c %s "$out" 2>/dev/null || echo 0)
  draw_bar "$final" "$total" "$label"
  [ "$TTY" = "1" ] && printf '\n'
  return "$rc"
}

# ================================================================= seams ===
# Everything Android-specific lives here and in the launchers. The rest of the
# script is ordinary shell, so it can be exercised on any Linux machine.
pkg_refresh() { run "apt-get update" env DEBIAN_FRONTEND=noninteractive apt-get update -y; }
pkg_add()     { local what="$*"; run "apt-get install $what" env DEBIAN_FRONTEND=noninteractive apt-get install -y $what; }

# ============================================================== mechanism ===
# Pure functions. No network, no package manager, no Android.

# Reads the linux-arm64 checksum or size out of a manifest on stdin.
manifest_field() {
  local field="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys
try:
    d=json.load(sys.stdin)
    print(d["platforms"]["linux-arm64"].get(sys.argv[1],""))
except Exception:
    pass' "$field"
  else
    tr -d '\n\r\t' \
      | grep -o '"linux-arm64"[[:space:]]*:[[:space:]]*{[^{}]*}' \
      | grep -o "\"$field\"[[:space:]]*:[[:space:]]*\"\?[0-9a-fA-F]*" \
      | sed 's/.*[:"]//'
  fi
}

is_sha256()  { [[ "${1:-}" =~ ^[a-f0-9]{64}$ ]]; }
is_version() { [[ "${1:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; }

# The four-way check a downloaded installer passes before it replaces anything.
# Each can fail while the other three pass.
#   1 plausible size        a captive-portal page is not 10 KB of installer
#   2 first line is #!      it is a script, not an HTML error
#   3 bash -n is SILENT     exit 0 alone is not enough: a file cut mid-heredoc
#                           prints a warning and still exits 0
#   4 the sentinel is last  only a whole file can carry its own last line
CCT_SENTINEL="CLAUDE_CODE_TERMUX_COMPLETE_MARKER"
validate_installer() {
  local f="$1" size first parse_out
  [ -f "$f" ] || { echo "missing file"; return 1; }
  size=$(stat -c %s "$f" 2>/dev/null || echo 0)
  [ "$size" -ge 8000 ] || { echo "too small: $size bytes"; return 1; }
  first=$(head -1 "$f")
  [[ "$first" == "#!"* ]] || { echo "first line is not a shebang"; return 1; }
  parse_out=$(bash -n "$f" 2>&1)
  [ -z "$parse_out" ] || { echo "bash -n printed: $parse_out"; return 1; }
  # The last two lines, not the last one: a second marker rides there for the
  # benefit of the edition-2 updater, which refuses any installer lacking its
  # own. Dropping that line would strand every phone still on v2.
  tail -2 "$f" | grep -q "$CCT_SENTINEL" || { echo "sentinel missing, the file is truncated"; return 1; }
  tail -2 "$f" | grep -q '^# CCT_COMPLETE_V2$' || { echo "the edition-2 compatibility marker is missing"; return 1; }
  echo "size $size, shebang ok, parse silent, sentinel present"
  return 0
}

# Which start-up file the person's shell actually reads.
shell_rc() {
  case "${SHELL##*/}" in
    zsh) printf '%s\n' "$HOME/.zshrc" ;;
    *)   printf '%s\n' "$HOME/.bashrc" ;;
  esac
}

# Appends one alias line to a shell start-up file. Never rewrites the file:
# somebody's rc is their own work and a wholesale rewrite is how it gets lost.
# Prints what it did: added, already, conflict, or failed.
add_alias() {
  local rc="$1" name="$2" cmd="$3"
  local line="alias $name='$cmd'"
  [ -e "$rc" ] || : > "$rc" 2>/dev/null || { echo "failed"; return 1; }
  [ -w "$rc" ] || { echo "failed"; return 1; }
  if grep -q "^alias $name=" "$rc" 2>/dev/null; then
    if grep -qxF "$line" "$rc"; then echo "already"; return 0; fi
    echo "conflict"; return 2
  fi
  # A file whose last line has no newline would otherwise swallow the alias
  # onto the end of it. Command substitution strips trailing newlines, so a
  # non-empty result here means the last character was not one.
  if [ -s "$rc" ] && [ -n "$(tail -c1 "$rc")" ]; then printf '\n' >> "$rc" || { echo "failed"; return 1; }; fi
  printf '# added by CLAUDE_CODE_TERMUX: start Claude Code with one letter\n%s\n' "$line" >> "$rc" \
    || { echo "failed"; return 1; }
  echo "added"
  return 0
}

# Writes a command beside its own name and renames over the top. A plain
# redirect truncates the file a running shell may still be reading from, and
# that shell then carries on at its old byte offset into whatever is there now.
install_command() {
  local name="$1" body="$2"
  rm -f "$BIN_DIR/$name.new"
  printf '%s\n' "$body" > "$BIN_DIR/$name.new" || return 1
  chmod +x "$BIN_DIR/$name.new" || return 1
  mv -f "$BIN_DIR/$name.new" "$BIN_DIR/$name" || return 1
}

# ============================================================== preflight ===
preflight() {
  step "Checking this phone"

  [ -d "$BIN_DIR" ] || die "$BIN_DIR does not exist. Run this inside Termux."
  case "$PREFIX" in
    *com.termux*) ok "Termux prefix $PREFIX" ;;
    *) note "prefix $PREFIX is not Termux, so this is a test environment" ;;
  esac

  local machine; machine="$(uname -m)"
  case "$machine" in
    aarch64|arm64) ok "architecture $machine" ;;
    armv7l|armv8l)
      bad "architecture $machine"
      die "This phone runs a 32-bit Android userland. Claude Code is 64-bit only." ;;
    x86_64) note "architecture $machine, a test environment rather than a phone" ;;
    *) die "unsupported architecture $machine" ;;
  esac

  local free_mb
  free_mb=$(df -Pm "$HOME" 2>/dev/null | awk 'NR==2{print $4}')
  if [ -n "$free_mb" ]; then
    if [ "$free_mb" -lt 1200 ]; then
      bad "${free_mb} MB free. Native needs about 600 MB, proot about 2500 MB"
    else
      ok "${free_mb} MB free"
    fi
  fi

  # A previous run that died between writing and renaming leaves these.
  local orphan found=0
  for orphan in "$BIN_DIR"/claude.new "$BIN_DIR"/claude-termux-update.new; do
    [ -e "$orphan" ] && { rm -f "$orphan"; found=$((found+1)); }
  done
  [ "$found" -gt 0 ] && note "cleared $found half-written file(s) from an interrupted run"
  return 0
}

dependency_table() {
  step "Reading what is already here"
  printf '        %-22s %-8s %s\n' "DEPENDENCY" "STATUS" "VERSION OR FIX"
  printf '        %s\n' "----------------------------------------------------------"
  local missing=0 name ver
  for name in bash curl git sha256sum; do
    if command -v "$name" >/dev/null 2>&1; then
      ver=$("$name" --version 2>/dev/null | head -1 | cut -c1-34)
      printf '        %-22s %sok%s       %s\n' "$name" "$GREEN" "$OFF" "${ver:-present}"
    else
      printf '        %-22s %sMISSING%s  %s\n' "$name" "$RED" "$OFF" "pkg install $name"
      missing=$((missing+1))
    fi
  done
  if [ "$MODE" = "native" ] || [ -z "$MODE" ]; then
    for name in patchelf grun; do
      if command -v "$name" >/dev/null 2>&1; then
        printf '        %-22s %sok%s       %s\n' "$name" "$GREEN" "$OFF" "present"
      else
        printf '        %-22s %sMISSING%s  %s\n' "$name" "$RED" "$OFF" "installed at step 5"
        missing=$((missing+1))
      fi
    done
  fi
  if [ -x "$BIN_DIR/claude" ]; then
    printf '        %-22s %sok%s       %s\n' "claude" "$GREEN" "$OFF" "installed, will be replaced"
  else
    printf '        %-22s %s-%s        %s\n' "claude" "$DIM" "$OFF" "not yet installed"
  fi
  printf '        %s\n' "----------------------------------------------------------"
  note "$missing item(s) will be fetched. Nothing is written to disk before step 5."
  return 0
}

choose_mode() {
  step "Choosing the install"
  if [ -n "$MODE" ]; then ok "mode $MODE, from the command line"; return 0; fi
  if [ ! -t 0 ] || [ "$ASSUME_YES" = "1" ]; then
    MODE="native"
    ok "mode native, the lighter one, since there is no terminal to ask on"
    note "run with --proot for the Ubuntu install instead"
    return 0
  fi
  cat <<'MENU'

        1  native   The official linux-arm64 binary, its ELF interpreter
                    repointed at Termux glibc. About 600 MB, starts fast,
                    uses your Termux packages. It rests on a compatibility
                    shim, so an upstream change can need a new edition here.

        2  proot    Anthropic's own installer inside an Ubuntu rootfs.
                    About 2500 MB, a second or two slower to start, and a
                    real glibc userland, so it behaves like Linux.

MENU
  local reply
  read -r -p "        Choose 1 or 2 [1]: " reply || reply=1
  case "${reply:-1}" in
    1|native|"") MODE="native" ;;
    2|proot)     MODE="proot" ;;
    *) die "not an option: $reply" ;;
  esac
  ok "mode $MODE"
}

packages() {
  step "Installing Termux packages"
  note "apt output follows; lines scrolling past means it is working"
  pkg_refresh || note "apt-get update was unhappy. Carrying on, the mirrors may be stale"
  pkg_add curl ca-certificates git which coreutils grep sed tar || die "the base packages failed"
  pkg_add ripgrep || note "ripgrep is unavailable here, Claude Code will use its own"
  if [ "$EXTRAS" = "1" ]; then
    pkg_add nodejs-lts python openssh jq zstd || note "some extras failed, none of them are required"
  fi
}

# ========================================================= native install ===
install_native() {
  step "Installing the glibc compatibility layer"
  pkg_add tur-repo || note "tur-repo may already be enabled"
  pkg_refresh || true
  pkg_add glibc-runner patchelf || die "glibc-runner or patchelf would not install"

  local ld="" c
  for c in "$PREFIX/glibc/lib/ld-linux-aarch64.so.1" "$PREFIX/opt/glibc/lib/ld-linux-aarch64.so.1"; do
    [ -e "$c" ] && { ld="$c"; break; }
  done
  [ -n "$ld" ] || ld="$(find "$PREFIX" -name 'ld-linux-aarch64.so.1' -type f 2>/dev/null | head -1)"
  [ -n "$ld" ] || die "the glibc dynamic linker is not on this system. Try: pkg install glibc-runner"
  local glibc_lib; glibc_lib="$(dirname "$ld")"
  ok "dynamic linker $ld"

  # The binary asks for libc.so.6 by that exact name. Check it is a real ELF
  # before going further, because the sibling file libc.so is a text linker
  # script and a half-installed glibc shows up as a confusing load error much
  # later, after a 220 MB download.
  local libc="$glibc_lib/libc.so.6"
  if [ ! -e "$libc" ]; then
    die "glibc is incomplete: $libc is missing. Try: pkg install glibc-runner"
  fi
  if [ "$(head -c 4 "$libc" | od -An -tx1 | tr -d ' \n')" = "7f454c46" ]; then
    ok "libc.so.6 is a real ELF object"
  else
    die "glibc is broken: $libc is not an ELF object. Reinstall with: pkg install --reinstall glibc-runner"
  fi

  step "Asking Anthropic which version is current"
  local version
  version=$(curl -fsSL --connect-timeout "$NET_CONNECT_TIMEOUT" --max-time "$NET_SMALL_TIMEOUT" \
            "$CDN/latest" | tr -d '\r\n')
  is_version "$version" || die "the CDN did not answer with a version. Check the network, and check that Anthropic serves your region: https://www.anthropic.com/supported-countries"
  ok "Claude Code $version"

  local manifest checksum size
  manifest=$(curl -fsSL --connect-timeout "$NET_CONNECT_TIMEOUT" --max-time "$NET_SMALL_TIMEOUT" \
             "$CDN/$version/manifest.json")
  checksum=$(printf '%s' "$manifest" | manifest_field checksum | tr -d ' \r\n')
  size=$(printf '%s' "$manifest" | manifest_field size | tr -d ' \r\n')
  [[ "$size" =~ ^[0-9]+$ ]] || size=0
  is_sha256 "$checksum" || die "the manifest carries no linux-arm64 checksum"
  ok "manifest says $(( size / 1048576 )) MB, sha256 ${checksum:0:12}..."

  mkdir -p "$OPT_DIR/versions"
  local target="$OPT_DIR/versions/claude-$version"

  step "Downloading the binary"
  if [ -x "$target" ] && [ "$UPDATE" != "1" ]; then
    ok "$version is already here, skipping the download"
  else
    info "about $(( size / 1048576 )) MB. Keep Termux in the foreground so Android lets it finish"
    download_bar "$CDN/$version/linux-arm64/claude" "$target.part" "$size" "claude $version" \
      || die "the download did not finish"
    local got actual
    got=$(stat -c %s "$target.part" 2>/dev/null || echo 0)
    info "checking the sha256 against Anthropic's published manifest"
    actual=$(sha256sum "$target.part" | cut -d' ' -f1)
    if [ "$actual" != "$checksum" ]; then
      rm -f "$target.part"
      die "checksum mismatch, so nothing was installed. Got $got bytes, sha256 ${actual:0:16}..., expected ${checksum:0:16}..."
    fi
    ok "sha256 matches, $got bytes"
    mv -f "$target.part" "$target"
    chmod +x "$target"
  fi

  step "Patching the binary for Android"
  info "repointing the ELF interpreter at $ld"
  if patchelf --set-interpreter "$ld" "$target" 2>&1 | sed 's/^/        | /'; then
    ok "interpreter patched"
  else
    die "patchelf could not rewrite the interpreter"
  fi
  # The library path belongs to this binary, written into the file itself.
  # Putting the glibc directory on LD_LIBRARY_PATH instead would apply it to
  # every process the launcher starts, and Android's own libc is named
  # libc.so, which is exactly the name glibc uses for a text linker script.
  # Termux commands would then load that script as a library and die with
  # "bad ELF magic: 2f2a2047".
  info "writing the glibc library path into the binary as an rpath"
  if patchelf --set-rpath "$glibc_lib" "$target" 2>&1 | sed 's/^/        | /'; then
    ok "rpath set to $glibc_lib"
  else
    die "patchelf could not set the rpath"
  fi
  local got_interp got_rpath
  got_interp="$(patchelf --print-interpreter "$target" 2>/dev/null)"
  got_rpath="$(patchelf --print-rpath "$target" 2>/dev/null)"
  [ "$got_interp" = "$ld" ] || die "the interpreter reads back as $got_interp, not $ld"
  [ "$got_rpath" = "$glibc_lib" ] || die "the rpath reads back as $got_rpath, not $glibc_lib"
  ok "read back from the file: interpreter and rpath are both correct"
  ln -sfn "$target" "$OPT_DIR/current"
  printf 'native\n' > "$OPT_DIR/mode"

  step "Writing the commands"
  write_launcher_native "$glibc_lib" || die "could not write $BIN_DIR/claude"
  write_updater || die "could not write $BIN_DIR/claude-termux-update"
  ok "claude               runs $OPT_DIR/current"
  ok "claude-termux-update fetches and installs in one run"

  # Keep the current build and the one before it, and nothing older.
  ( cd "$OPT_DIR/versions" 2>/dev/null && ls -1t 2>/dev/null | tail -n +3 | xargs -r rm -f ) || true
}

write_launcher_native() {
  local glibc_lib="$1"
  install_command claude "$(cat <<WRAPPER
#!$PREFIX/bin/bash
# Claude Code launcher for Termux. CLAUDE_CODE_TERMUX edition v$CCT_EDITION.
#
# Termux exports LD_PRELOAD=$PREFIX/lib/libtermux-exec-ld-preload.so into every
# shell. That library is a Bionic object and needs Android's libc, which is
# named libc.so. Under glibc's loader the preload is honoured, its dependency
# on libc.so is searched for in the glibc directory, and what is found there is
# a TEXT LINKER SCRIPT of the same name. The loader then stops with
#   error while loading shared libraries: .../glibc/lib/libc.so: invalid ELF header
# Measured on a phone, 12.9.2026, with LD_DEBUG=libs. Clearing the preload for
# this one process is the fix; the surrounding shell keeps its own.
unset LD_PRELOAD

# LD_LIBRARY_PATH is deliberately NOT set here either. The same libc.so script
# would then be on the library path of every Termux command the launcher runs,
# which breaks them with "bad ELF magic: 2f2a2047". The binary carries its own
# rpath instead, written in by the installer.

# Android has no /tmp. Claude Code needs somewhere writable to work.
export TMPDIR="\${TMPDIR:-$PREFIX/tmp}"
mkdir -p "\$TMPDIR"
# Termux's own ripgrep, which is built for Bionic.
export USE_BUILTIN_RIPGREP=0
# The built-in updater would fetch an unpatched binary over the patched one and
# the next launch would not start. claude-termux-update does it correctly.
export DISABLE_AUTOUPDATER=1
exec "$OPT_DIR/current" "\$@"
WRAPPER
)"
}

# ========================================================== proot install ===
install_proot() {
  step "Installing proot-distro"
  pkg_add proot-distro || die "proot-distro would not install"

  step "Unpacking the $DISTRO rootfs"
  if proot-distro list --installed 2>/dev/null | grep -q "$DISTRO"; then
    ok "$DISTRO is already here"
  else
    info "a few hundred MB to fetch, then it unpacks, and the unpack is quiet for a while"
    run "proot-distro install $DISTRO" proot-distro install "$DISTRO" \
      || die "the $DISTRO rootfs did not install"
  fi

  step "Installing Claude Code inside $DISTRO"
  info "Anthropic's own installer runs in there and its output follows"
  run "claude install inside $DISTRO" proot-distro login "$DISTRO" --termux-home -- bash -lc '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y curl ca-certificates git ripgrep less
    curl -fsSL --connect-timeout 20 --max-time 900 https://claude.ai/install.sh | bash
    grep -q ".local/bin" "$HOME/.bashrc" 2>/dev/null || \
      echo "export PATH=\"\$HOME/.local/bin:\$PATH\"" >> "$HOME/.bashrc"
  ' || die "the install inside $DISTRO did not finish"

  mkdir -p "$OPT_DIR"
  printf 'proot\n' > "$OPT_DIR/mode"

  step "Writing the commands"
  write_launcher_proot || die "could not write $BIN_DIR/claude"
  write_updater || die "could not write $BIN_DIR/claude-termux-update"
  ok "claude               enters $DISTRO with your Termux home mounted"
  ok "claude-termux-update runs claude update inside $DISTRO"
}

write_launcher_proot() {
  install_command claude "$(cat <<WRAPPER
#!$PREFIX/bin/bash
# Claude Code launcher for Termux, proot path. CLAUDE_CODE_TERMUX edition v$CCT_EDITION.
#
# proot-distro login always starts in the container's home directory. Without
# the two steps below, "cd myproject && claude" opens Claude Code in the home
# directory instead of myproject, and it can neither see nor edit the files
# that are right there.
unset LD_PRELOAD

# pwd -P resolves symlinks first: ~/storage/downloads is a link to
# /storage/emulated/0/Download, and the link target is what has to be bound.
CCT_CWD="\$(pwd -P)"

# Bind the directory into the container at the same absolute path, then change
# into it before starting. Binding a path to itself is harmless when it already
# sits inside the Termux home that --termux-home mounts.
exec proot-distro login $DISTRO --termux-home --bind "\$CCT_CWD:\$CCT_CWD" -- \\
  bash -lc 'export PATH="\$HOME/.local/bin:\$PATH"; cd "\$1" || { echo "cannot enter \$1 inside the container" >&2; exit 1; }; shift; exec claude "\$@"' \\
  claude "\$CCT_CWD" "\$@"
WRAPPER
)"
}

# ================================================================ updater ===
# Fetches and installs in the same run. An updater that only leaves a command
# behind looks exactly like nothing happening.
write_updater() {
  install_command claude-termux-update "$(cat <<UPDATER
#!$PREFIX/bin/bash
# claude-termux-update — CLAUDE_CODE_TERMUX edition v$CCT_EDITION
set -uo pipefail
PREFIX="\${PREFIX:-$PREFIX}"
RAW="$CCT_RAW"
MODE_FILE="$OPT_DIR/mode"
SENTINEL="$CCT_SENTINEL"
MODE="native"; [ -r "\$MODE_FILE" ] && MODE="\$(cat "\$MODE_FILE")"

# The four completeness checks, emitted from the installer's own function so
# that there is one copy of the rule rather than two that must be kept in step.
CCT_SENTINEL="\$SENTINEL"
$(declare -f validate_installer)

mkdir -p "\${TMPDIR:-\$PREFIX/tmp}"
TMP="\$(mktemp "\${TMPDIR:-\$PREFIX/tmp}/cct-XXXXXX.sh")"

echo "==> fetching the current installer"
if ! curl -fsSL --connect-timeout 20 --max-time 120 -o "\$TMP" "\$RAW"; then
  rm -f "\$TMP"
  echo "Could not fetch the installer. This repository is public and the download" >&2
  echo "needs no account, so a 404 means the file moved and anything else means the" >&2
  echo "network. Nothing was changed." >&2
  exit 1
fi

echo "==> checking what arrived"
if ! detail=\$(validate_installer "\$TMP"); then
  rm -f "\$TMP"
  echo "Nothing was changed: \$detail" >&2
  exit 1
fi
echo "    \$detail"

echo "==> installing, mode \$MODE"
bash "\$TMP" "--\$MODE" --update --yes
rc=\$?
rm -f "\$TMP"
exit \$rc
UPDATER
)"
}

# ============================================================ the shortcut ===
# Editing somebody's shell start-up file is not something an installer should
# do quietly. Interactively it asks. Piped from curl there is no terminal to
# ask on, so it says plainly what it added and how to take it away again.
setup_alias() {
  step "The one-letter shortcut"
  if [ "$WANT_ALIAS" != "1" ]; then
    note "skipped, because --no-alias was given"
    return 0
  fi
  local rc; rc="$(shell_rc)"
  info "your shell reads $rc"

  if [ -t 0 ] && [ "$ASSUME_YES" != "1" ]; then
    local reply
    read -r -p "        Add  alias c='claude'  to $rc? [Y/n]: " reply || reply="y"
    case "${reply:-y}" in
      n|N|no|NO) note "left alone; add it yourself any time with: echo \"alias c='claude'\" >> $rc"; return 0 ;;
    esac
  fi

  local result; result="$(add_alias "$rc" c claude)"
  case "$result" in
    added)
      ok "added  alias c='claude'  to $rc"
      info "type  c  instead of  claude  in any new session"
      info "to remove it later:  sed -i \"/alias c='claude'/d\" $rc" ;;
    already)
      ok "$rc already has it, nothing to change" ;;
    conflict)
      bad "$rc already defines c as something else, so it was left alone"
      note "run  alias c  to see what it points at" ;;
    *)
      bad "could not write to $rc, so no shortcut was added"
      note "everything else is installed and working" ;;
  esac
  return 0
}

# ================================================================= verify ===
verify() {
  step "Verifying"
  if [ ! -x "$BIN_DIR/claude" ]; then bad "$BIN_DIR/claude was not created"; return 1; fi
  ok "$BIN_DIR/claude exists and is executable"
  local out rc
  out=$("$BIN_DIR/claude" --version 2>&1); rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'libc.so: invalid ELF header'; then
    bad "the Termux preload is being pulled into the glibc process"
    note "the launcher should clear LD_PRELOAD; check $BIN_DIR/claude for 'unset LD_PRELOAD'"
  fi
  if [ "$rc" -eq 0 ]; then
    ok "claude --version says: $out"
    return 0
  fi
  bad "claude --version exited $rc"
  printf '        %s| %s%s\n' "$DIM" "$out" "$OFF"
  note "the Troubleshooting section of the README covers what this means"
  return 1
}

# =================================================================== main ===
usage() { sed -n '2,20p' "$0"; }

parse_args() {
  local a
  for a in "$@"; do
    case "$a" in
      --native) MODE="native" ;;
      --proot)  MODE="proot" ;;
      --update) UPDATE=1 ;;
      --extras) EXTRAS=1 ;;
      --yes|-y) ASSUME_YES=1 ;;
      --no-alias) WANT_ALIAS=0 ;;
      -h|--help) usage; exit 0 ;;
      *) die "not an option: $a  (try --help)" ;;
    esac
  done
}

main() {
  parse_args "$@"
  printf '\n%s CLAUDE_CODE_TERMUX %sedition v%s%s\n' "$AMBER" "$BOLD" "$CCT_EDITION" "$OFF"
  printf ' %sClaude Code on Android. Nine steps, and every one prints what it did.%s\n' "$DIM" "$OFF"

  preflight     || exit 1
  dependency_table
  choose_mode
  packages
  case "$MODE" in
    native) install_native ;;
    proot)  install_proot ;;
  esac
  setup_alias
  verify; local vrc=$?

  printf '\n%s Finished in %s seconds.%s\n\n' "$AMBER" "$(elapsed)" "$OFF"
  cat <<EOF
        Start it:            claude      (or just  c  in a new session)
        Update it later:     claude-termux-update
        Remove it:           bash uninstall.sh

        The first run opens a browser to log in. Claude Code needs a paid
        Claude plan or a Console API key.

        Run these two once, by hand, if you have not:
            termux-setup-storage     access to the phone's files
            termux-wake-lock         stops Android sleeping during a long job

        Installed mode: $MODE

EOF
  return "$vrc"
}

# Sourcing this file for testing gets the functions and runs nothing.
if [ "${CCT_SOURCE_ONLY:-0}" != "1" ]; then
  main "$@"
fi
# CLAUDE_CODE_TERMUX_COMPLETE_MARKER edition v7 — a truncated copy cannot carry this line
# CCT_COMPLETE_V2
