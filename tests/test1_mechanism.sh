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

# ------------------------------------------------------------ draw_bar -----
TTY=0
assert_contains "0 of 100 draws an empty bar"  "[......................]" "$(draw_bar 0 100 x)"
assert_contains "0 of 100 reads 0 percent"     "  0%"                     "$(draw_bar 0 100 x)"
assert_contains "100 of 100 fills the bar"     "[######################]" "$(draw_bar 100 100 x)"
assert_contains "100 of 100 reads 100 percent" "100%"                     "$(draw_bar 100 100 x)"
assert_contains "half draws half"              "[###########...........]" "$(draw_bar 50 100 x)"
# the boundary that bites: a total of zero must not divide by zero
assert_contains "a total of 0 does not divide by zero" "  0%" "$(draw_bar 0 0 x)"
# more bytes than the manifest promised must clamp rather than overflow the bar
assert_contains "overshooting clamps at 100 percent" "100%" "$(draw_bar 300 100 x)"
assert_contains "megabytes are shown, not bytes" "1/2 MB" "$(draw_bar 1048576 2097152 x)"

t_summary "TEST 1"
