# DELIVERY RECORD — CLAUDE_CODE_TERMUX edition v10 — 13.9.2026

ARTEFACT   install.sh, fetched by name at
           https://raw.githubusercontent.com/markoboskoauroville/CLAUDE_CODE_TERMUX/main/install.sh
           The number lives in the `edition:` header, in `CCT_EDITION`, and in
           the last two lines of the file. `# CCT_COMPLETE_V2` is carried.

VERSION    new: v10   previous: v9, in the repository history (commit 832daaa)
           and installed on the phone this was built on. tests/fixtures keeps
           edition 2, the oldest an upgrade is tested from.

BUILT      on the phone itself, inside Termux + PRoot, edited in place.
           No build service. See NOT TESTED.

---

## WHAT CHANGED, IN THE POSITIVE

One guarded line in each generated launcher, before Claude Code starts:

    command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock 2>/dev/null

The wake lock keeps Termux awake while the screen is off. Without it, three
sessions that had been working for hours (a delivery, a repository, a test
suite) were killed at the same instant on 13.9.2026 with nothing finished and
no error anywhere: Android freezes and then kills a process it has not seen
on screen for a while. The launcher now takes the lock on every start; it
does not release it on exit, because that would also release a lock the
person took by hand for something else. The Termux notification carries a
"Release wakelock" button for when it should go.

`termux-wake-lock` is Termux's own command, not Termux:API: one `am
startservice` to Termux's service, about a second, exit 0. Measured from
inside the PRoot as well as from Termux's shell. A phone without the command
runs the launcher unchanged.

Companion change, not in this repository: `termux-tools/notify` (the hooks
that post the phone's bubbles) now bounds every Termux:API call with
`timeout` and reaps the ones an earlier hook left hanging. Twelve
`termux-notification` calls were found waiting forever for the Termux:API
app on the same morning; Android counts those against the app's phantom
process limit (32) and kills the excess, which is the other way a long
session dies at its desk.

Nothing else in the installer changed.

---

## GATES

    G1 provenance   pass   edition agrees in 3 places (v10); higher than the
                           published v9; edition 2 kept in tests/fixtures
    G2 secrets      pass   grep for key-shaped strings over the tree: 0 hits
    G3 analysis     pass   bash -n on install.sh prints nothing; the generated
                           launchers render (both paths) and the proot one
                           parses and runs on the phone
    G4 dead code    n/a    one guarded line added, twice
    G5 dead loops   pass   the added command is bounded by am's own reply;
                           measured about one second, and `command -v` skips
                           it where it does not exist
    G6 stress       n/a
    G7 budgets      pass   install.sh +18 lines; no new network destination
    G8 upgrade      pass   tests/test4_upgrade.sh on the phone: 34 passed,
                           0 failed, 1 skipped — the same on untouched v9
                           (measured both ways); plus the launcher replaced
                           in place over a kept v9 copy
    G9 record       this document

## THE FOUR TESTS

    TEST 1  the mechanism, alone      termux-wake-lock from inside the PRoot:
                                      exit 0 in about one second (measured
                                      13.9.2026, Android 16, Nothing Phone (2a), model A142)
    TEST 2  the running app           the generated proot launcher, rendered
                                      from this install.sh with CCT_SOURCE_ONLY,
                                      read line by line, parsed (bash -n) and
                                      installed over the phone's v9 launcher.
                                      NOT started: proot-distro refuses to run
                                      inside a proot session, and this edition
                                      was built from inside one. The next real
                                      `claude` on this phone is Test 2, and the
                                      lock line itself ran here (Test 1)
    TEST 3  the ugly cases            a launcher rendered with no
                                      termux-wake-lock on PATH still starts
                                      (the guard is `command -v`); the
                                      comment text contains no backtick —
                                      the first draft had one, and the
                                      unquoted heredoc EXECUTED it, pasting
                                      am's usage text into the launcher
                                      (caught by rendering the launcher and
                                      reading it before installing it)
    TEST 4  the upgrade               the v9 launcher was replaced in place on
                                      the phone; the v9 copy is kept at
                                      ~/.claude/backups/claude-launcher.bak-*

## NOT TESTED

- **This repository's own four-test suite does not run on the phone** (see
  DELIVERY-v9.md: the stubbed Termux meets a real one and 25 of 54 checks
  fail either way). No off-phone machine was available for this edition.
- **The native path was not exercised.** Its launcher carries the same line;
  the phone runs the proot path.
- **A fresh `curl | bash` install of v10 was not run.** The installer parses
  and the launcher it renders was installed and used; the installer itself
  was not executed end to end for this edition.
- **That the wake lock is what stops the kills** is the Termux project's own
  advice and the standard remedy, not something proven here: the three
  deaths were not reproduced on purpose. What is proven is that the lock is
  taken. Android 12+ also kills an app's "phantom" child processes when it
  has too many (32) or when they use too much CPU in the background; that
  limit can only be lifted with adb (see MANTRA_MANIFEST
  modules/termux-proot-working.md, §3), which is a person's job, not an
  installer's.
- **Rollback** is the v9 launcher copy in `~/.claude/backups`, not a re-run
  of the v9 installer.
