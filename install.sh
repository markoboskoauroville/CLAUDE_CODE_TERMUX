#!/usr/bin/env bash
#
# CLAUDE_CODE_TERMUX — install Claude Code on Android / Termux
#
#   curl -fsSL https://raw.githubusercontent.com/markoboskoauroville/CLAUDE_CODE_TERMUX/main/install.sh | bash
#
# Usage:
#   bash install.sh                 interactive path chooser
#   bash install.sh --native        patched linux-arm64 binary (light, ~300 MB)
#   bash install.sh --proot         Claude Code inside Ubuntu via proot (~2 GB, most compatible)
#   bash install.sh --native --update   re-download + re-patch the newest version
#   bash install.sh --extras        also install node, python, ripgrep, openssh, jq
#
# Why this exists: Anthropic ships Claude Code as a glibc-linked linux-arm64
# binary. Android/Termux uses Bionic libc, so the official installer's binary
# will not start. --native patches the ELF interpreter to Termux's glibc-runner.
# --proot sidesteps the problem with a real glibc userland.

set -euo pipefail

CCT_VERSION="1.0.0"
CDN="https://downloads.claude.ai/claude-code-releases"
OPT_DIR="${PREFIX:-/data/data/com.termux/files/usr}/opt/claude-code"
BIN_DIR="${PREFIX:-/data/data/com.termux/files/usr}/bin"
DISTRO="ubuntu"

MODE=""
UPDATE=0
EXTRAS=0

# ----------------------------------------------------------------- output ---
if [ -t 1 ]; then
  B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
else
  B=""; G=""; Y=""; R=""; N=""
fi
say()  { printf '%s\n' "${B}==>${N} $*"; }
ok()   { printf '%s\n' "${G}  ok${N} $*"; }
warn() { printf '%s\n' "${Y}  !!${N} $*" >&2; }
die()  { printf '%s\n' "${R}error:${N} $*" >&2; exit 1; }

# ------------------------------------------------------------------- args ---
for arg in "$@"; do
  case "$arg" in
    --native)  MODE="native" ;;
    --proot)   MODE="proot" ;;
    --update)  UPDATE=1 ;;
    --extras)  EXTRAS=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "unknown option: $arg (try --help)" ;;
  esac
done

# --------------------------------------------------------------- preflight ---
preflight() {
  say "Checking the environment"

  [ -n "${PREFIX:-}" ] && [ -d "$PREFIX/bin" ] \
    || die "PREFIX is not set. Run this inside Termux, not in a plain adb shell."

  case "$PREFIX" in
    *com.termux*) ok "Termux detected at $PREFIX" ;;
    *) warn "PREFIX does not look like Termux ($PREFIX) — continuing anyway" ;;
  esac

  local machine
  machine="$(uname -m)"
  case "$machine" in
    aarch64|arm64) ok "architecture $machine" ;;
    armv7l|armv8l) die "$machine means a 32-bit Android userland. Claude Code needs 64-bit ARM." ;;
    *) die "unsupported architecture: $machine" ;;
  esac

  local free_mb
  free_mb=$(df -Pm "$HOME" 2>/dev/null | awk 'NR==2{print $4}')
  if [ -n "$free_mb" ]; then
    if [ "$free_mb" -lt 1200 ]; then
      warn "only ${free_mb} MB free — the native path needs ~600 MB, proot ~2.5 GB"
    else
      ok "${free_mb} MB free on the Termux filesystem"
    fi
  fi
}

pkg_install() {
  # apt-get avoids pkg's "no stable CLI interface" warning on every call
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" >/dev/null 2>&1 \
    || DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

base_packages() {
  say "Updating Termux packages (this can take a minute)"
  DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || true
  pkg_install curl ca-certificates git which coreutils
  ok "base packages installed"

  if [ "$EXTRAS" = "1" ]; then
    say "Installing extras (node, python, ripgrep, openssh, jq, zstd)"
    pkg_install nodejs-lts python ripgrep openssh jq zstd || warn "some extras failed — not fatal"
    ok "extras installed"
  else
    pkg_install ripgrep jq zstd || true
  fi
}

# ------------------------------------------------------- native (path A) ---
manifest_field() {
  # usage: printf '%s' "$manifest" | manifest_field checksum
  # python3 when present, otherwise a grep/sed fallback so the script still
  # works on a bare Termux install.
  local field="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import json,sys
d=json.load(sys.stdin)
print(d["platforms"]["linux-arm64"].get(sys.argv[1],""))
' "$field"
  else
    tr -d "\n\r\t" \
      | grep -o "\"linux-arm64\"[[:space:]]*:[[:space:]]*{[^{}]*}" \
      | grep -o "\"$field\"[[:space:]]*:[[:space:]]*\"\?[^,\"}]*" \
      | sed "s/.*[:\"]//"
  fi
}

install_native() {
  say "Installing glibc compatibility layer"
  pkg_install tur-repo || warn "tur-repo may already be enabled"
  DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1 || true
  pkg_install glibc-runner patchelf || die "could not install glibc-runner / patchelf"

  local ld=""
  for candidate in \
      "$PREFIX/glibc/lib/ld-linux-aarch64.so.1" \
      "$PREFIX/opt/glibc/lib/ld-linux-aarch64.so.1"; do
    [ -e "$candidate" ] && ld="$candidate" && break
  done
  if [ -z "$ld" ]; then
    ld="$(find "$PREFIX" -name 'ld-linux-aarch64.so.1' -type f 2>/dev/null | head -1 || true)"
  fi
  [ -n "$ld" ] || die "glibc dynamic linker not found. Try: pkg install glibc-runner"
  local glibc_lib
  glibc_lib="$(dirname "$ld")"
  ok "dynamic linker: $ld"

  say "Asking Anthropic's CDN for the current version"
  local version
  version="$(curl -fsSL "$CDN/latest" | tr -d '\r\n')"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] \
    || die "did not get a version from the CDN (blocked network, or region not supported)"
  ok "Claude Code $version"

  local manifest checksum
  manifest="$(curl -fsSL "$CDN/$version/manifest.json")"
  checksum="$(printf '%s' "$manifest" | manifest_field checksum | tr -d ' \r\n')"
  [[ "$checksum" =~ ^[a-f0-9]{64}$ ]] || die "no linux-arm64 checksum in the manifest"

  mkdir -p "$OPT_DIR/versions"
  local target="$OPT_DIR/versions/claude-$version"

  if [ -x "$target" ] && [ "$UPDATE" != "1" ]; then
    ok "$version already downloaded"
  else
    say "Downloading the linux-arm64 binary (~230 MB) — be patient on mobile data"
    curl -fSL --progress-bar -o "$target.part" "$CDN/$version/linux-arm64/claude" \
      || die "download failed"

    say "Verifying the SHA-256 checksum"
    local actual
    actual="$(sha256sum "$target.part" | cut -d' ' -f1)"
    if [ "$actual" != "$checksum" ]; then
      rm -f "$target.part"
      die "checksum mismatch — refusing to install this file"
    fi
    mv "$target.part" "$target"
    chmod +x "$target"
    ok "checksum verified"
  fi

  say "Patching the ELF interpreter for Android"
  # Only the interpreter is rewritten. The library path is supplied at runtime
  # by the wrapper, which avoids rewriting section headers of a bun-packed
  # binary that carries an appended payload.
  patchelf --set-interpreter "$ld" "$target" || die "patchelf failed"
  ok "interpreter now points at Termux glibc"

  ln -sfn "$target" "$OPT_DIR/current"

  say "Writing the claude launcher"
  cat > "$BIN_DIR/claude" <<WRAPPER
#!$PREFIX/bin/bash
# Claude Code launcher for Termux — generated by CLAUDE_CODE_TERMUX $CCT_VERSION
export LD_LIBRARY_PATH="$glibc_lib\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
# Android has no /tmp; Claude Code needs a writable scratch directory.
export TMPDIR="\${TMPDIR:-$PREFIX/tmp}"
mkdir -p "\$TMPDIR"
# Use Termux's own ripgrep instead of the glibc one bundled in the binary.
export USE_BUILTIN_RIPGREP=0
# The built-in updater would replace this binary with an unpatched one.
export DISABLE_AUTOUPDATER=1
exec "$OPT_DIR/current" "\$@"
WRAPPER
  chmod +x "$BIN_DIR/claude"

  cat > "$BIN_DIR/claude-termux-update" <<UPDATER
#!$PREFIX/bin/bash
# Re-download and re-patch the newest Claude Code build.
exec bash <(curl -fsSL https://raw.githubusercontent.com/markoboskoauroville/CLAUDE_CODE_TERMUX/main/install.sh) --native --update
UPDATER
  chmod +x "$BIN_DIR/claude-termux-update"

  # keep only the two newest builds
  ( cd "$OPT_DIR/versions" && ls -1t | tail -n +3 | xargs -r rm -f ) 2>/dev/null || true

  ok "launcher installed at $BIN_DIR/claude"
}

# -------------------------------------------------------- proot (path B) ---
install_proot() {
  say "Installing proot-distro"
  pkg_install proot-distro || die "could not install proot-distro"

  if proot-distro list --installed 2>/dev/null | grep -q "$DISTRO"; then
    ok "$DISTRO rootfs already present"
  else
    say "Downloading the $DISTRO rootfs (a few hundred MB)"
    proot-distro install "$DISTRO" || die "proot-distro install $DISTRO failed"
  fi

  say "Installing Claude Code inside $DISTRO"
  proot-distro login "$DISTRO" --termux-home -- bash -lc '
    set -e
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null
    apt-get install -y curl ca-certificates git ripgrep less >/dev/null
    curl -fsSL https://claude.ai/install.sh | bash
    grep -q ".local/bin" "$HOME/.bashrc" 2>/dev/null || \
      echo "export PATH=\"\$HOME/.local/bin:\$PATH\"" >> "$HOME/.bashrc"
  ' || die "installation inside $DISTRO failed"

  say "Writing the claude launcher"
  cat > "$BIN_DIR/claude" <<WRAPPER
#!$PREFIX/bin/bash
# Claude Code launcher for Termux (proot path) — CLAUDE_CODE_TERMUX $CCT_VERSION
exec proot-distro login $DISTRO --termux-home -- bash -lc \\
  'export PATH="\$HOME/.local/bin:\$PATH"; exec claude "\$@"' claude "\$@"
WRAPPER
  chmod +x "$BIN_DIR/claude"

  cat > "$BIN_DIR/claude-termux-update" <<UPDATER
#!$PREFIX/bin/bash
exec proot-distro login $DISTRO --termux-home -- bash -lc \\
  'export PATH="\$HOME/.local/bin:\$PATH"; claude update'
UPDATER
  chmod +x "$BIN_DIR/claude-termux-update"

  ok "launcher installed at $BIN_DIR/claude"
}

# ------------------------------------------------------------------ verify ---
verify() {
  say "Verifying"
  if out="$("$BIN_DIR/claude" --version 2>&1)"; then
    ok "claude --version -> $out"
    return 0
  fi
  warn "claude --version did not succeed. Output was:"
  printf '%s\n' "$out" >&2
  warn "See the Troubleshooting section of the README."
  return 1
}

# -------------------------------------------------------------------- main ---
choose_mode() {
  [ -n "$MODE" ] && return 0
  if [ ! -t 0 ]; then
    MODE="native"
    say "Not an interactive shell — defaulting to --native"
    return 0
  fi
  printf '\n%s\n' "${B}Which install do you want?${N}"
  cat <<'MENU'

  1) native   Patched linux-arm64 binary running on Termux glibc.
              ~600 MB, starts fast, uses Termux packages directly.
              Depends on a compatibility shim, so an upstream change
              can break it until this script is updated.

  2) proot    Official installer inside an Ubuntu rootfs.
              ~2.5 GB, slower to start, but a real glibc userland,
              so it behaves like Claude Code on any Linux box.

MENU
  local reply
  read -r -p "Choose 1 or 2 [1]: " reply || reply=1
  case "${reply:-1}" in
    1|native) MODE="native" ;;
    2|proot)  MODE="proot" ;;
    *) die "invalid choice: $reply" ;;
  esac
}

main() {
  printf '\n%s\n\n' "${B}CLAUDE_CODE_TERMUX $CCT_VERSION${N} — Claude Code for Android/Termux"
  preflight
  choose_mode
  base_packages

  if [ -e "$BIN_DIR/claude" ] && [ "$UPDATE" != "1" ]; then
    warn "an existing $BIN_DIR/claude will be replaced"
  fi

  case "$MODE" in
    native) install_native ;;
    proot)  install_proot ;;
  esac

  verify || true

  cat <<EOF

${G}Done.${N} Start it with:

    claude

First run opens a browser for your Anthropic login. Claude Code needs a paid
Claude plan (Pro, Max, Team, Enterprise) or a Console API key — the free plan
does not include it.

Update later with:

    claude-termux-update

Installed mode: ${MODE}
EOF
}

main "$@"
