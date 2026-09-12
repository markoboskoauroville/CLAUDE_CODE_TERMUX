# DELIVERY RECORD — CLAUDE_CODE_TERMUX v2

Date: 12.9.2026
Artefact: this repository at the commit this file is part of.
Standard: MANTRA_MANIFEST `modules/four-tests.md` and `modules/delivery-gate.md`.

Reproduce both from the repository root:

```bash
bash tests/run_tests.sh      # the four tests
bash gates/run_gates.sh      # the nine gates
bash gates/run_gates.sh --remote   # G1 also compares the pushed bytes
```

---

## WHAT WAS TESTED

Against a stubbed Termux: a `$PREFIX` whose path contains `com.termux`, and
stubs for `uname`, `apt-get`, `curl`, `patchelf`, `getprop` and `proot-distro`.
The stub CDN serves a fake claude binary whose real sha256 is written into a
fake manifest, so the verification step is exercised with true and with false
checksums.

**Test 1 — the mechanism, alone.** Every script parses. The completeness marker
is the last line, and the marker check was shown to go red on a truncated file,
so it is a check and not a rumour. All three manifest parsers — python, jq and
the no-python fallback — were run against the **live** Anthropic manifest and
agree on the same 64-hex checksum. The generated launcher and updater are
themselves valid scripts.

**Test 2 — a full install, end to end.** Installer exits 0, both commands land
in `bin`, `current` points at a build, and `claude --version` prints the
installed version. The launcher sets `DISABLE_AUTOUPDATER`, `USE_BUILTIN_RIPGREP=0`,
a writable `TMPDIR` and `LD_LIBRARY_PATH`. The dependency table printed a count.
patchelf was called, and with the Termux glibc linker.

**Test 3 — the ugly cases.** Nine of them, each has to fail loudly and leave
nothing behind: corrupt checksum, CDN serving HTML instead of a version, network
down, 32-bit `armv7l`, download failure mid-file, a patchelf that returns success
without doing anything, a truncated installer, apt failing, and `--rollback` with
no history. All nine stop the install, and in every case `$PREFIX/bin/claude`
does not exist afterwards.

**Test 4 — the upgrade.** Install 2.1.269, publish 2.1.300 to the stub CDN,
run `--update`. The new version is what runs, the home directory is untouched,
the previous build is recorded, `--rollback` really goes back, and no more than
two builds stay on disk.

The suite is run five times inside G6 to check it gives the same answer every
time.

---

## WHAT WAS NOT TESTED

None of this is claimed, because none of it can be checked off a phone:

- that the real 230 MB glibc binary starts once its ELF interpreter is repointed
- that `glibc-runner` and `patchelf` install from `tur-repo` on a given Android
  version and vendor build
- a real `proot-distro` Ubuntu rootfs install, and Anthropic's installer inside it
- the OAuth login round trip through the Android browser
- Android's low-memory killer during a long download
- real download time, data cost and battery on mobile data
- any device-specific behaviour: no physical device was involved in this delivery

Everything in that list is stubbed in the harness. What the tests cover is the
logic around those calls, not the calls themselves.

---

## KNOWN LIMITS

**The native path is a shim, not official Android support.** Anthropic publishes
`darwin-arm64`, `darwin-x64`, `linux-arm64`, `linux-x64`, the two musl variants
and two Windows builds. There is no `android-arm64`. The native path takes the
`linux-arm64` binary and repoints its ELF interpreter at Termux's glibc. It is a
workaround, and an upstream change can break it between one release and the next.
Tracked at anthropics/claude-code#50270.

**patchelf is used as little as possible.** Only `--set-interpreter`. The library
path is supplied at runtime by the launcher instead, so section headers are never
moved on a binary that carries an appended payload.

**The built-in updater is disabled on the native path**, because it would
download an unpatched binary and leave a `claude` that cannot start. This is why
`claude-termux-update` exists.

**A paid Claude plan is required.** Pro, Max, Team, Enterprise, or a Console API
key. The free plan does not include Claude Code.

**The proot path costs about 2.5 GB.** On a phone that is not nothing.

---

## GATE RESULT

Captured run in [RESULTS.txt](RESULTS.txt).

    four tests    55 checks    54 passed    0 failed    1 skipped
    nine gates     9 gates      9 green     0 blocking  2 advisory

    G1  PROVENANCE   version 2 is a whole number, named in README and here;
                     completeness marker is the last line; every declared
                     artefact present. Remote byte comparison run separately
                     with --remote after the push.
    G2  SECRETS      8 files scanned, 0 pattern hits, 0 bare-40-hex hits, and
                     the supplied GitHub token appears in no artefact.
    G3  ANALYSIS     shellcheck at warning and above: 0 findings across 4
                     scripts. 21 style-level findings, not blocking.
    G4  DEAD CODE    42 functions defined, 0 never called.
    G5  DEAD LOOPS   8 curl invocations, 0 without a time bound. No unbounded
                     loops. The one interactive read is guarded by a terminal
                     check, so a piped install can never block on it.
    G6  STRESS       suite run 3 times, 3 green, 0 red. 12 sabotage switches.
    G7  BUDGETS      install.sh 22 KB / 575 lines, suite 9s, 16 packages,
                     repo 100 KB.
    G8  UPGRADE      Test 4: 11 checks, 11 passed. Rollback present and proven.
    G9  RECORD       this file.

**Two checks were broken on purpose to prove they can fail**, per the gate's own
rule that a check which has never gone red is a rumour:

- G5 was re-run with `--max-time` removed from one curl. It went red, named the
  line, and went green again when restored.
- G2 was re-run with a fake `ghp_` token pasted into README.md. **It stayed
  green — the check was broken.** The pattern used BRE quantifiers (`\{20,\}`)
  inside `grep -E`, so it matched nothing and reported a clean scan on a file
  with a token in it. Fixed to ERE, re-tested red, then green. G2 now also
  self-tests every run by matching a known-bad string, so a silently broken
  regex cannot read as a pass again.

That second one is the whole argument for the gate. It was written carefully,
it read as green, and it was proving nothing.
