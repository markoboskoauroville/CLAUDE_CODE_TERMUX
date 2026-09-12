#!/usr/bin/env bash
#
# Remove Claude Code from Termux.
#   bash uninstall.sh          launchers + patched binary
#   bash uninstall.sh --all    also ~/.claude and the Ubuntu rootfs

set -euo pipefail

PREFIX="${PREFIX:-/data/data/com.termux/files/usr}"
OPT_DIR="$PREFIX/opt/claude-code"
ALL=0
[ "${1:-}" = "--all" ] && ALL=1

say() { printf '==> %s\n' "$*"; }

say "Removing launchers"
rm -f "$PREFIX/bin/claude" "$PREFIX/bin/claude-termux-update"

say "Removing patched binaries"
rm -rf "$OPT_DIR"

if [ "$ALL" = "1" ]; then
  say "Removing ~/.claude (settings, history, credentials)"
  rm -rf "$HOME/.claude" "$HOME/.claude.json"

  if command -v proot-distro >/dev/null 2>&1 \
     && proot-distro list --installed 2>/dev/null | grep -q ubuntu; then
    say "Removing the Ubuntu rootfs"
    proot-distro remove ubuntu || true
  fi
else
  say "Keeping ~/.claude — pass --all to remove it too"
fi

say "Done."
