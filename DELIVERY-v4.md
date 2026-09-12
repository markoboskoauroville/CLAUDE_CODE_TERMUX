# DELIVERY RECORD — CLAUDE_CODE_TERMUX edition v4 — 12.9.2026

ARTEFACT   install.sh, fetched by name at
           https://raw.githubusercontent.com/markoboskoauroville/CLAUDE_CODE_TERMUX/main/install.sh
           The filename is frozen because `claude-termux-update` fetches it by
           that address. The number lives in the `edition:` header, in
           `CCT_EDITION`, and in the last two lines of the file.

VERSION    new: v4   previous: v3 (and v2 before it), still in the repository history and kept at
           `tests/fixtures/install-previous.sh` so the upgrade test can run.

BUILT      on a Linux container, not on a build service. See NOT TESTED.

---

## WHAT CHANGED, IN THE POSITIVE

Every step announces itself as `[ n / 9 ]` with seconds elapsed, and every
package command streams its output indented underneath. The download draws a
bar from the bytes actually on disk, polled once a second, against the byte
count Anthropic publishes.

The installer writes each command beside its own name and renames over the
top, so a shell that is reading the old file runs to the end undisturbed.

`claude-termux-update` fetches and installs in one run, and checks four things
before anything is replaced: the size is plausible, the first line is a
shebang, `bash -n` prints nothing at all, and the completeness markers are in
the last two lines. The rule exists once, as a function, and is emitted into
the updater from that one copy.

The glibc library path is written into the binary itself as an rpath. It is
never put on `LD_LIBRARY_PATH`, because that would apply to every process the
launcher starts.

The installer carries the line `# CCT_COMPLETE_V2` so that a phone still
running edition 2 can update to this one.

Before downloading anything, the installer checks that `libc.so.6` in the
glibc directory is a real ELF object, so a half-installed `glibc-runner` is
caught in seconds rather than after 220 MB.

Running it a second time over an existing install is safe: the checksum is
verified on freshly downloaded bytes only.

---

## GATES

    G1 provenance   pass   edition agrees in 3 places (v3); higher than the
                           published v2; previous artefact still downloadable
    G2 secrets      pass   16 files scanned, 0 credential-shaped strings,
                           0 token variable names; the check proved it can fail
    G3 analysis     pass   10 shell files parse and all 10 parse SILENTLY;
                           shellcheck 0 errors; set -u on
    G4 dead code    pass   30 functions examined, 0 unreached
    G5 dead loops   pass   curl invocations examined, all carrying a deadline;
                           0 unbounded loops; a never-answering server measured
    G6 stress       pass   200 command replacements, 0 half-written files,
                           0 reused inodes; 14 hostile strings, 0 crashes
    G7 budgets      pass   installer 22 KB (previous 22 KB); test 1 in ~270 ms;
                           patchelf grows the 219,536,808-byte binary by
                           131,072 bytes; no new network destination
    G8 upgrade      pass   v2 -> v3 over the top, settings, credentials and
                           project files intact, a running updater undisturbed,
                           and a documented way back that is exercised
    G9 record       this document

## THE FOUR TESTS

    TEST 1  the mechanism, alone        55 passed, 0 failed
    TEST 2  the real CDN and binary     37 passed, 0 failed, 2 skipped
    TEST 3  the ugly cases              39 passed, 0 failed
    TEST 4  the upgrade and the way back 34 passed, 0 failed, 1 skipped

Test 2 downloads the real 219,536,808-byte binary. Anthropic's own published
byte count and SHA-256 both agree with what lands on disk, which is an outside
party confirming the result rather than the test agreeing with itself.

Three failures during development were in the tests: fixtures under the 8 KB
floor, a size compared against the patched file instead of the downloaded one,
and a hardcoded edition number. All three are fixed in the tests, not worked
around in the code.

---

## THE FAILURE THAT EDITION 4 EXISTS TO FIX

Edition 3 was run on a phone and `claude` would not start:

    CANNOT LINK EXECUTABLE "mkdir": .../glibc/lib/libc.so has bad ELF magic: 2f2a2047

The launcher exported `LD_LIBRARY_PATH` pointing at the glibc directory. That
applies to every process the launcher starts. Android's own libc is named
`libc.so`, and glibc ships a **text linker script** under that same name, so
Termux's `mkdir` found the script, tried to load it as a library, and died.
`2f2a2047` is the ASCII for `/* G`.

The fix is to write the library path into the binary as an rpath, so it
applies to that one file and nothing else. The installer now reads both the
interpreter and the rpath back out of the file after patching, and fails if
either is wrong.

Two checks now exist that can each fail alone: the generated launcher must not
export `LD_LIBRARY_PATH`, and no library path may be set before the launcher
runs `mkdir`. Both were mutation-tested against a deliberately broken launcher.

**The edition-2 test harness met this same failure and concluded the test was
wrong.** Its `tests/run_tests.sh` still says, at line 43, that it deliberately
leaves `libc.so.6` out of the sandbox because "an empty libc.so.6 breaks every
host binary the sandbox runs". It was not the harness. Every fixture here now
carries a real `libc.so.6` beside a `libc.so` linker script, so the trap is
present where a test can see it.

## FINDINGS IN THE PREVIOUS EDITIONS

**Edition 2 cannot be run twice.** It re-verifies the SHA-256 of a binary that
is already on disk. `patchelf` has changed that binary, so the comparison is
against Anthropic's figure for a file that no longer exists in that form, and
it stops with `checksum mismatch — nothing was installed`. Anyone re-running
the one-line install hits this. Measured in test 4.

**The way back from v3 to v2 needs one extra step** for the same reason:

    rm -rf $PREFIX/opt/claude-code/versions
    bash install-previous.sh --native

That path is tested, not assumed.

**A new edition must carry `# CCT_COMPLETE_V2`.** Edition 2's updater greps
for that exact line and calls anything without it truncated. An edition that
drops it strands every phone on v2, reporting a truncated download forever.
This edition carries it, and test 4 fails if a future one does not.

---

## NOT TESTED

- `claude --version` actually starting. The artefact is aarch64 and no phone
  was involved. Only the device can prove the patched binary runs. Edition 3
  passed every test here and still failed on the phone; that is the measure of
  what this list is worth.
- `pkg install` against real Termux repositories, including `tur-repo`,
  `glibc-runner` and `patchelf`. Package installs were stood in for.
- Whether Termux's real `ld-linux-aarch64.so.1` loads this binary. The linker
  in the tests is a stand-in file; patchelf only writes the path string.
- The proot path end to end. No `proot-distro` here, so the Ubuntu rootfs, the
  install inside it, and the launcher that enters it are code inspection only.
- The login flow, the browser callback, MCP, voice, and PDF reading.
- Any behaviour on a real upgrade over a real Claude login.
- Android's low-memory killer during a 220 MB download.
- The artefact was built on a container rather than on a build service, so
  G1's "built by CI" clause is not satisfied.

## KNOWN

- The native path is a compatibility shim, not Android support. An upstream
  change to how Claude Code is packaged can break it. Tracked upstream at
  anthropics/claude-code#50270.
- `patchelf` adds 128 KB of header padding. Re-patching an already-patched
  binary adds a little more; measured at under 3 KB and bounded by a test.
- This repository also holds `tests/run_tests.sh`, `gates/run_gates.sh`,
  `DELIVERY.md` and `RESULTS.txt` from the edition-2 delivery. They are left
  in place. The edition-3 files are `tests/test1..test4`, `tests/lib.sh`,
  `gates/gate.sh` and this record.
- Edition 3 was published and is superseded. Anyone who installed it has a
  launcher that breaks Termux commands; re-running the installer replaces it.
