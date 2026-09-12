# DELIVERY RECORD — CLAUDE_CODE_TERMUX edition v8 — 12.9.2026

ARTEFACT   install.sh, fetched by name at
           https://raw.githubusercontent.com/markoboskoauroville/CLAUDE_CODE_TERMUX/main/install.sh
           The filename is frozen because `claude-termux-update` fetches it by
           that address. The number lives in the `edition:` header, in
           `CCT_EDITION`, and in the last two lines of the file.

VERSION    new: v8   previous: v7, still in the repository history and kept at
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

    TEST 1  the mechanism, alone        69 passed, 0 failed, 1 skipped
    TEST 2  the real CDN and binary     37 passed, 0 failed, 2 skipped
    TEST 3  the ugly cases              45 passed, 0 failed
    TEST 4  the upgrade and the way back 34 passed, 0 failed, 1 skipped

Test 2 downloads the real 219,536,808-byte binary. Anthropic's own published
byte count and SHA-256 both agree with what lands on disk, which is an outside
party confirming the result rather than the test agreeing with itself.

Three failures during development were in the tests: fixtures under the 8 KB
floor, a size compared against the patched file instead of the downloaded one,
and a hardcoded edition number. All three are fixed in the tests, not worked
around in the code.

---

## WHAT EDITION 8 FIXES

**Measured on a phone, proot-distro 5.8.0.** The installer asked
`proot-distro list --installed` whether Ubuntu was there. That command answered
nothing, so the installer tried a fresh install, got back

    Error: container 'ubuntu' already exists

and stopped, with a working Ubuntu sitting on the disk the whole time. Anyone
re-running the proot install after the first success hit this.

Two changes. The question is now asked of the disk —
`$PREFIX/var/lib/proot-distro/installed-rootfs/<distro>` — because the
directory is the fact and the listing command is a version-dependent opinion
about it. And an install that fails **because it is already installed** is
treated as success rather than as a failure.

Test 3 now drives a stand-in `proot-distro` that behaves exactly like 5.8.0 did:
silent listing, "already exists" on install. It also checks that a genuine
rootfs failure still stops the run, so the two cannot be confused.

## WHAT EDITION 7 ADDED

A one-letter shortcut. `c` starts Claude Code, added as `alias c='claude'` to
whichever start-up file the person's shell actually reads: `.zshrc` for zsh,
`.bashrc` otherwise.

Editing somebody's shell start-up file is not something an installer should do
quietly, so: interactively it asks, and `--no-alias` refuses outright. Piped
from curl there is no terminal to ask on, so it adds the line and prints both
what it added and the one command that removes it again.

The file is appended to, never rewritten. An rc is the person's own work and a
wholesale rewrite is how it gets lost. If `c` already means something else the
line is left alone and the conflict is reported.

## WHAT EDITION 6 FIXED

**The proot path works on a phone.** Claude Code v2.1.269, Opus 5, running in
Termux on Android. That is the first end-to-end confirmation in this project.

One defect came with it. `proot-distro login` always starts in the container's
home directory, so `cd myproject && claude` opened Claude Code in the home
directory and it could see none of the project's files. The launcher now
resolves the working directory with `pwd -P` (because `~/storage/downloads` is
a symlink and the target is what has to be bound), binds that directory into
the container at the same absolute path, and changes into it before starting.

Three checks cover it, none of which can prove it: the launcher is generated
and inspected, but no `proot-distro` exists on a test machine.

## THE FAILURE THAT EDITION 5 FIXED

Edition 4 was run on a phone and `claude` still would not start:

    error while loading shared libraries: .../glibc/lib/libc.so: invalid ELF header

`LD_DEBUG=libs` settled it. The failing request for `libc.so` carries
`RUNPATH from .../lib/libtermux-exec-ld-preload.so`. Termux exports
`LD_PRELOAD=$PREFIX/lib/libtermux-exec-ld-preload.so` into every shell. That
library is a Bionic object and needs Android's libc, which is named `libc.so`.
Under glibc's loader the preload is honoured, its dependency is searched for in
the glibc directory, and the file found there under that name is a text linker
script. Nothing was wrong with the binary: NEEDED listed `libc.so.6`, the rpath
was correct, and `libc.so.6` was a real 2.3 MB ELF object. Termux's own preload
was being dragged into a glibc process.

The launcher now runs `unset LD_PRELOAD` before the exec. The surrounding shell
keeps its own preload, so `termux-exec` still works for everything else.

Two checks, each able to fail alone: the launcher must clear the preload, and
it must clear it before the exec rather than after. Both mutation-tested
against a launcher with the `unset` deleted.

## THE FAILURE THAT EDITION 4 FIXED

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
  was involved. Only the device can prove the patched binary runs. Editions 3
  and 4 each passed every test here and each failed on the phone, for two
  different reasons. That is the measure of what this list is worth.
- The Termux runtime environment itself: `LD_PRELOAD`, `termux-exec`, and
  anything else Termux injects into a shell. None of it exists on a test
  machine, and both phone failures came from exactly there.
- `pkg install` against real Termux repositories, including `tur-repo`,
  `glibc-runner` and `patchelf`. Package installs were stood in for.
- Whether Termux's real `ld-linux-aarch64.so.1` loads this binary. The linker
  in the tests is a stand-in file; patchelf only writes the path string.
- The proot path end to end. No `proot-distro` here, so the Ubuntu rootfs, the
  install inside it, and the launcher that enters it are code inspection only.
  It has now been confirmed working by hand on one phone; it is still not
  covered by any test that runs here.
- Whether the working-directory bind actually lands. Generated and inspected,
  never executed. The one phone available had not yet run an edition carrying
  it at the time of writing.
- Real `proot-distro` behaviour. Test 3 drives a stand-in written from one
  observed version, 5.8.0. Other versions may answer differently again.
- A read-only start-up file. The tests run as root, which bypasses file
  permissions, so that branch is unreachable here. On a phone Termux runs as an
  ordinary user and it is reachable; the test skips with that reason rather
  than asserting something this machine cannot produce.
- Whether `c` is free on every Termux setup. It is on a stock one.
- The login flow, the browser callback, MCP, voice, and PDF reading.
- Any behaviour on a real upgrade over a real Claude login.
- Android's low-memory killer during a 220 MB download.
- The artefact was built on a container rather than on a build service, so
  G1's "built by CI" clause is not satisfied.

## KNOWN

- **The native path does not work on the one phone it was tried on.** After the
  preload fix it stopped failing to load and started segfaulting instead. The
  binary was intact: NEEDED listed `libc.so.6`, the rpath was correct. The
  remaining suspect is the 128 KB of header padding `patchelf` adds to a
  bun-packed binary. Not chased further; the proot path was taken instead.
  Anyone reaching for `--native` should expect to debug it.
- Inside proot, Claude Code warns that cross-session messaging is off, because
  the process runs in a user namespace with no uid mapping. It is a warning,
  not a failure, and everything else works.

- The native path is a compatibility shim, not Android support. An upstream
  change to how Claude Code is packaged can break it. Tracked upstream at
  anthropics/claude-code#50270.
- `patchelf` adds 128 KB of header padding. Re-patching an already-patched
  binary adds a little more; measured at under 3 KB and bounded by a test.
- This repository also holds `tests/run_tests.sh`, `gates/run_gates.sh`,
  `DELIVERY.md` and `RESULTS.txt` from the edition-2 delivery. They are left
  in place. The edition-3 files are `tests/test1..test4`, `tests/lib.sh`,
  `gates/gate.sh` and this record.
- Editions 3 and 4 are published and superseded. Anyone who installed it has a
  launcher that will not start; re-running the installer replaces it.
