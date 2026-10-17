#!/usr/bin/env bash
# TEST 1 — THE MECHANISM, ALONE
#
# The pure logic of the installer with inputs chosen by hand. No network, no
# apt, no Android. Closes "the logic is wrong".
#
# Run: bash tests/test1_mechanism.sh

HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export PREFIX="$WORK/prefix"
export BIN_DIR="$PREFIX/bin"
mkdir -p "$BIN_DIR"
export CCT_SOURCE_ONLY=1
# shellcheck disable=SC1090
. "$HERE/../install.sh"
BIN_DIR="$PREFIX/bin"   # the script recomputes these from PREFIX; keep them here

t_head "TEST 1 — the mechanism, alone"

# --------------------------------------------------------- is_version ------
# the case it is FOR
assert_ok        "version 2.1.269 is a version"            is_version "2.1.269"
assert_ok        "version 10.0.0 is a version"             is_version "10.0.0"
assert_ok        "version 2.1.269-beta.1 is a version"     is_version "2.1.269-beta.1"
# the case it must REFUSE — this is the captive-portal and error-page defence
assert_fails     "an HTML page is not a version"           is_version "<!DOCTYPE html><html>"
assert_fails     "an empty string is not a version"        is_version ""
assert_fails     "2.1 is not a version"                    is_version "2.1"
assert_fails     "the word latest is not a version"        is_version "latest"
assert_fails     "a leading space breaks it"               is_version " 2.1.269"

# ---------------------------------------------------------- is_sha256 ------
VALID_SHA="4c84a33adc34c60d4de3acd43cfe7c64ba966591e51587c04867b8d589021be4"
assert_ok        "a real 64-hex sha256 is accepted"        is_sha256 "$VALID_SHA"
# both sides of the boundary: 63, 64, 65
assert_fails     "63 hex characters are refused"           is_sha256 "${VALID_SHA:0:63}"
assert_fails     "65 hex characters are refused"           is_sha256 "${VALID_SHA}a"
assert_fails     "uppercase hex is refused"                is_sha256 "$(printf '%s' "$VALID_SHA" | tr 'a-f' 'A-F')"
assert_fails     "empty is refused"                        is_sha256 ""
assert_fails     "non-hex of the right length is refused"  is_sha256 "$(printf 'z%.0s' $(seq 64))"

# ------------------------------------------------------ manifest_field -----
REAL_MANIFEST='{"version":"2.1.269","platforms":{"darwin-arm64":{"checksum":"aaaa","size":1},"linux-arm64":{"checksum":"'"$VALID_SHA"'","size":244318208},"linux-x64":{"checksum":"bbbb","size":2}}}'
assert_eq "the linux-arm64 checksum is read"  "$VALID_SHA"   "$(printf '%s' "$REAL_MANIFEST" | manifest_field checksum)"
assert_eq "the linux-arm64 size is read"      "244318208"    "$(printf '%s' "$REAL_MANIFEST" | manifest_field size)"
# two rules colliding: the neighbouring platforms must not bleed in
assert_not_contains "darwin's checksum is not taken" "aaaa"  "$(printf '%s' "$REAL_MANIFEST" | manifest_field checksum)"
assert_not_contains "linux-x64's checksum is not taken" "bbbb" "$(printf '%s' "$REAL_MANIFEST" | manifest_field checksum)"
# the case it must REFUSE
assert_eq "a manifest with no linux-arm64 yields nothing" "" \
  "$(printf '%s' '{"platforms":{"darwin-arm64":{"checksum":"aaaa"}}}' | manifest_field checksum)"
assert_eq "an HTML error page yields nothing" "" \
  "$(printf '%s' '<html><body>404</body></html>' | manifest_field checksum)"
assert_eq "empty input yields nothing" "" "$(printf '' | manifest_field checksum)"
# the same input twice
assert_eq "reading it twice gives the same answer" \
  "$(printf '%s' "$REAL_MANIFEST" | manifest_field checksum)" \
  "$(printf '%s' "$REAL_MANIFEST" | manifest_field checksum)"

# the fallback parser, used when python3 is absent, must agree with python3
manifest_field_nopython() {
  tr -d '\n\r\t' \
    | grep -o '"linux-arm64"[[:space:]]*:[[:space:]]*{[^{}]*}' \
    | grep -o "\"$1\"[[:space:]]*:[[:space:]]*\"\?[0-9a-fA-F]*" \
    | sed 's/.*[:"]//'
}
assert_eq "the no-python fallback agrees on the checksum" "$VALID_SHA" \
  "$(printf '%s' "$REAL_MANIFEST" | manifest_field_nopython checksum)"
assert_eq "the no-python fallback agrees on the size" "244318208" \
  "$(printf '%s' "$REAL_MANIFEST" | manifest_field_nopython size)"

# -------------------------------------------------- validate_installer -----
# Each of the four checks must be able to fail while the other three pass.
WHOLE="$WORK/whole.sh"
{
  printf '#!/data/data/com.termux/files/usr/bin/bash\n'
  printf '# padding line %s\n' $(seq 1 900)
  printf 'echo hello\n'
  printf '# %s edition v3\n' "$CCT_SENTINEL"
  printf '# CCT_COMPLETE_V2\n'
} > "$WHOLE"
assert_ok "a whole installer validates" validate_installer "$WHOLE"

# fault 1: too small, but shebang + parse + sentinel all fine
SMALL="$WORK/small.sh"
printf '#!/bin/bash\necho hi\n# %s\n# CCT_COMPLETE_V2\n' "$CCT_SENTINEL" > "$SMALL"
assert_fails "a 60-byte file is refused on size"  validate_installer "$SMALL"
assert_contains "and the reason names the size" "too small" "$(validate_installer "$SMALL" 2>&1)"

# fault 2: no shebang, everything else fine
NOSHE="$WORK/noshebang.sh"
sed '1s|.*|# not a shebang|' "$WHOLE" > "$NOSHE"
assert_fails "a file with no shebang is refused" validate_installer "$NOSHE"

# fault 3: cut mid-heredoc AND wearing the sentinel. bash -n exits 0 here and
# prints a warning, so only the silence check catches this one.
HEREDOC="$WORK/heredoc.sh"
{
  printf '#!/bin/bash\n'
  printf '# padding line %s\n' $(seq 1 900)
  printf 'cat <<EOF\n'
  printf 'half a here document and then the file stops\n'
  printf '# %s edition v3\n' "$CCT_SENTINEL"
  printf '# CCT_COMPLETE_V2\n'
} > "$HEREDOC"
if bash -n "$HEREDOC" >/dev/null 2>&1; then
  pass "the mid-heredoc file still exits 0 from bash -n, as the module says"
else
  fail "the mid-heredoc file still exits 0 from bash -n" "it exited non-zero, so this case no longer separates the checks"
fi
assert_fails "a file cut mid-heredoc is refused even wearing the sentinel" validate_installer "$HEREDOC"
assert_contains "and the reason is the parser's warning" "bash -n printed" "$(validate_installer "$HEREDOC" 2>&1)"

# fault 4: parses silently, right size, has a shebang, no sentinel. Only the
# sentinel check catches this one, which is what keeps it a separate check.
NOSENT="$WORK/nosentinel.sh"
grep -v "$CCT_SENTINEL" "$WHOLE" > "$NOSENT"
assert_eq "the sentinel-less file parses silently" "" "$(bash -n "$NOSENT" 2>&1)"
assert_fails "a file with no sentinel is refused" validate_installer "$NOSENT"
assert_contains "and the reason is the missing last line" "sentinel missing" "$(validate_installer "$NOSENT" 2>&1)"

# fault 5: whole, parsing, correctly sized, carrying this edition's marker, but
# missing the marker the PREVIOUS edition's updater greps for. Only the fifth
# check catches it, and without it every phone still on edition 2 is stranded.
NOCOMPAT="$WORK/nocompat.sh"
grep -v '^# CCT_COMPLETE_V2$' "$WHOLE" > "$NOCOMPAT"
assert_eq "the compat-less file parses silently" "" "$(bash -n "$NOCOMPAT" 2>&1)"
assert_contains "and it still carries this edition's marker" "$CCT_SENTINEL" "$(tail -2 "$NOCOMPAT")"
assert_fails "a file missing the edition-2 marker is refused" validate_installer "$NOCOMPAT"
assert_contains "and the reason names the compatibility marker" "edition-2 compatibility marker" \
  "$(validate_installer "$NOCOMPAT" 2>&1)"

# the file that does not exist at all
assert_fails "a missing file is refused" validate_installer "$WORK/not-here.sh"

# the shipped installer itself must pass its own check
assert_ok "install.sh validates itself" validate_installer "$HERE/../install.sh"

# ------------------------------------------------- install_command ---------
# A rename, never a truncation.
assert_ok "install_command writes a command" install_command probe "#!/bin/bash
echo probe-1"
assert_eq "the command is on disk" "probe-1" "$(bash "$BIN_DIR/probe")"
assert_ok "the command is executable" test -x "$BIN_DIR/probe"
assert_ok "no .new file is left behind" test ! -e "$BIN_DIR/probe.new"

# The rule this exists for: a shell reading the old file must be undisturbed.
# Proven by inode: a rename gives a NEW inode, a truncating write reuses the old
# one, and a reused inode is exactly what pulls the rug from a running shell.
OLD_INODE="$(stat -c %i "$BIN_DIR/probe")"
install_command probe "#!/bin/bash
echo probe-2"
NEW_INODE="$(stat -c %i "$BIN_DIR/probe")"
if [ "$OLD_INODE" != "$NEW_INODE" ]; then
  pass "replacing a command swaps the directory entry rather than truncating"
else
  fail "replacing a command swaps the directory entry rather than truncating" \
       "the inode stayed $OLD_INODE, so the running shell's file was overwritten"
fi
assert_eq "the replacement took effect" "probe-2" "$(bash "$BIN_DIR/probe")"

# idempotent: writing the same thing twice changes nothing
install_command probe "#!/bin/bash
echo probe-2"
assert_eq "writing the same body twice is harmless" "probe-2" "$(bash "$BIN_DIR/probe")"

# ----------------------------------------------------------- add_alias -----
RC="$WORK/rc"
# the case it is FOR
printf 'export PATH=/usr/bin\n' > "$RC"
assert_eq "an alias is added to a normal rc" "added" "$(add_alias "$RC" c claude)"
assert_contains "and the line is there"  "alias c='claude'" "$(cat "$RC")"
assert_contains "and the old content survives" "export PATH=/usr/bin" "$(cat "$RC")"
# the same input twice
assert_eq "adding it again reports already" "already" "$(add_alias "$RC" c claude)"
assert_eq "and the line appears exactly once" "1" "$(grep -c "^alias c='claude'$" "$RC")"
# the case it must REFUSE: c already means something else
printf 'alias c=cargo\n' > "$RC"
assert_eq "an existing different alias is a conflict" "conflict" "$(add_alias "$RC" c claude)"
assert_eq "and the person's own alias is untouched" "alias c=cargo" "$(cat "$RC")"
# boundary: a file whose last line has no newline
printf 'export FOO=1' > "$RC"
add_alias "$RC" c claude >/dev/null
assert_eq "a file with no trailing newline does not swallow the alias" "1" \
  "$(grep -c "^alias c='claude'$" "$RC")"
assert_contains "and its last line is still intact" "export FOO=1" "$(head -1 "$RC")"
# boundary: empty file, and a file that does not exist yet
: > "$RC"
assert_eq "an empty rc takes the alias" "added" "$(add_alias "$RC" c claude)"
rm -f "$RC"
assert_eq "a missing rc is created" "added" "$(add_alias "$RC" c claude)"
# ABSENT: a read-only rc must fail rather than half-write. Root bypasses file
# permissions, so this case is only reachable as an ordinary user, which is
# what Termux runs as on a phone.
printf 'export PATH=/usr/bin\n' > "$RC"; chmod 444 "$RC"
if [ "$(id -u)" -eq 0 ]; then
  skip "a read-only rc reports failed" "running as root, which can write to it anyway"
else
  assert_eq "a read-only rc reports failed" "failed" "$(add_alias "$RC" c claude)"
  assert_not_contains "and nothing was written to it" "alias c=" "$(cat "$RC")"
fi
chmod 644 "$RC"

# shell_rc picks the file the person's shell actually reads
assert_eq "zsh users get .zshrc" "$HOME/.zshrc" "$(SHELL=/usr/bin/zsh shell_rc)"
assert_eq "bash users get .bashrc" "$HOME/.bashrc" "$(SHELL=/bin/bash shell_rc)"
assert_eq "an unknown shell falls back to .bashrc" "$HOME/.bashrc" "$(SHELL=/bin/dash shell_rc)"

# ------------------------------------------------------------ draw_bar -----
TTY=0
assert_contains "0 of 100 draws an empty bar"  "[......................]" "$(draw_bar 0 100 x)"
assert_contains "0 of 100 reads 0 percent"     "  0%"                     "$(draw_bar 0 100 x)"
assert_contains "100 of 100 fills the bar"     "[######################]" "$(draw_bar 100 100 x)"
assert_contains "100 of 100 reads 100 percent" "100%"                     "$(draw_bar 100 100 x)"
assert_contains "half draws half"              "[###########...........]" "$(draw_bar 50 100 x)"
# the boundary that bites: a total of zero must not divide by zero
# a total of 0 means the size is unknown: no percentage, and no division by it
assert_contains "a total of 0 does not divide by zero" "0 MB" "$(draw_bar 0 0 x)"
# more bytes than the manifest promised must clamp rather than overflow the bar
assert_contains "overshooting clamps at 100 percent" "100%" "$(draw_bar 300 100 x)"
assert_contains "megabytes are shown, not bytes" "1/2 MB" "$(draw_bar 1048576 2097152 x)"

# ------------------------------------------------- speed, ETA, spinner -----
# Marko, 17.10.2026: Braille spinners, Midnight Commander bars, speed monitors.
assert_eq "4.2 MB/s"  "4.2 MB/s"  "$(fmt_rate 4404224)"
assert_eq "830 KB/s"  "830 KB/s"  "$(fmt_rate 849920)"
assert_eq "12 B/s"    "12 B/s"    "$(fmt_rate 12)"
assert_eq "an ETA under an hour reads m:ss"  "0:26"    "$(fmt_eta 26)"
assert_eq "an ETA over an hour reads h:mm:ss" "1:02:03" "$(fmt_eta 3723)"
TTY=0
B="$(draw_bar 52428800 104857600 claude 2097152)"
assert_contains "the bar shows the speed"           "2.0 MB/s" "$B"
assert_contains "and the time left at that speed"   "ETA 0:25" "$B"
assert_contains "an unknown total shows MB, no bar" "7 MB"     "$(draw_bar 7340032 0 x 1024)"
assert_not_contains "and no bar at all"            "["        "$(draw_bar 7340032 0 x 1024)"
assert_not_contains "a log line carries no control characters" $'\033' "$B"
# On a terminal: Braille, block bars, and never wider than the screen. A phone
# in portrait is about 50 columns; a wrapped status line cannot be redrawn.
TTY=1; COLS=50; SPIN=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏); BAR_ON="█"; BAR_OFF="░"
T="$(LC_ALL=C.UTF-8 draw_bar 52428800 104857600 "claude 2.1.301 for linux-arm64" 2097152 ⠹)"
assert_contains "the spinner is Braille"            "⠹" "$T"
assert_contains "the bar is Midnight Commander's"    "█" "$T"
VIS="$(printf '%s' "$T" | sed $'s/\033\\[[0-9;]*[A-Za-z]//g; s/\r//g')"
W="$(printf '%s' "$VIS" | python3 -c 'import sys; print(len(sys.stdin.buffer.read().decode("utf-8")))')"
assert_ok "a status line fits 50 columns ($W)" test "$W" -le 50
T="$(draw_bar 52428800 104857600 "label" 2097152 ⠹)"; COLS=120
T2="$(draw_bar 52428800 104857600 "claude 2.1.301 for linux-arm64" 2097152 ⠹)"
assert_contains "a wide screen keeps the label" "claude 2.1.301 for linux-arm64" "$T2"
COLS=50
# Recorded in the emulator, 17.10.2026: 336/272 MB; a bar that changed width
# with the numbers; and 0 B/s for minutes after 100% while Claude Code set up.
COLS=56
assert_not_contains "more bytes than the total show as the total" "336/272" "$(draw_bar 352321536 285212672 x 1024 ⠹)"
assert_contains "all arrived, still working: it says so" "setting up" "$(draw_bar 285212672 285212672 x 0 ⠹)"
assert_not_contains "and shows no falling speed" "B/s" "$(draw_bar 285212672 285212672 x 0 ⠹)"
barw() { printf '%s' "$1" | python3 -c 'import sys,re; t=sys.stdin.buffer.read().decode(); m=re.search(r"\[([█░]+)\]", t); print(len(m.group(1)) if m else -1)'; }
A="$(barw "$(draw_bar 8388608 285212672 x 581632 ⠹)")"
B="$(barw "$(draw_bar 209715200 285212672 x 2831155 ⠹)")"
assert_eq "the bar keeps one width as the numbers change" "$A" "$B"
TTY=0; SPIN=('|' '/' '-' '\'); BAR_ON="#"; BAR_OFF="."

# --------------------------------------------------------- watch_grown -----
# The emulator, 17.10.2026: an old 256 MB build sat in versions/ while the new
# download went to downloads/; the bar must show the new bytes, from zero.
WD="$(mktemp -d)"; mkdir -p "$WD/versions" "$WD/downloads"
head -c 5242880 /dev/zero > "$WD/versions/old"
watch_start "$WD/downloads $WD/versions"
assert_eq "nothing new yet reads 0" "0" "$(watch_grown "$WD/downloads $WD/versions")"
head -c 2097152 /dev/zero > "$WD/downloads/new"
G="$(watch_grown "$WD/downloads $WD/versions")"
assert_ok "the new download counts from zero, the old build not at all ($G)" test "$G" -ge 2097152 -a "$G" -lt 3145728
cp "$WD/downloads/new" "$WD/versions/new"
G="$(watch_grown "$WD/downloads $WD/versions")"
assert_ok "the same bytes copied on are not counted twice ($G)" test "$G" -lt 3145728
rm -rf "$WD"

# --------------------------------------------------------- choose_mode -----
# With nothing to ask on, the default is proot: the path proven on a phone.
# native installed and then segfaulted on a Nothing Phone (2a), 16.10.2026.
assert_eq "--yes with no mode picks proot" "proot" \
  "$(MODE=""; ASSUME_YES=1; STEP=0; choose_mode >/dev/null; echo "$MODE")"
assert_eq "--native on the command line is still honoured" "native" \
  "$(MODE="native"; ASSUME_YES=1; STEP=0; choose_mode >/dev/null; echo "$MODE")"
assert_eq "no terminal on stdin (curl | bash) picks proot" "proot" \
  "$(MODE=""; ASSUME_YES=0; STEP=0; choose_mode </dev/null >/dev/null 2>&1; echo "$MODE")"

t_summary "TEST 1"
