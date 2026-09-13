# DELIVERY RECORD — CLAUDE_CODE_TERMUX edition v9 — 13.9.2026

ARTEFACT   install.sh, fetched by name at
           https://raw.githubusercontent.com/markoboskoauroville/CLAUDE_CODE_TERMUX/main/install.sh
           The number lives in the `edition:` header, in `CCT_EDITION`, and in
           the last two lines of the file. `# CCT_COMPLETE_V2` is carried.

VERSION    new: v9   previous: v8, in the repository history (tag-less; the
           commit before this one) and installed on the phone this was built on.

BUILT      on the phone itself, inside Termux + PRoot, edited in place.
           No build service. See NOT TESTED.

---

## WHAT CHANGED, IN THE POSITIVE

One line of the generated launcher, on the proot path. Claude Code is now
started with an explicit cross-session messaging socket:

    mkdir -p -m 700 "$HOME/.claude/inbox"
    exec claude --messaging-socket-path "$HOME/.claude/inbox/cc-$$.sock" "$@"

Without it, every start printed a yellow warning: *Cross-session messaging is
off: its socket directory could not be set up: this process runs in a user
namespace without a uid mapping*. PRoot gives the process no
`/proc/self/uid_map`, so Claude Code reads its own uid as the kernel overflow
uid, cannot verify who owns the default socket directory, and refuses it. An
explicit path skips that check — provided the directory is mode 0700, which
Claude Code checks and refuses otherwise (measured: "directory /root/.claude is
not private (mode 755)").

The socket is also what `termux-tools/notify` uses: the phone's notification
buttons push a message back into the session through it.

Nothing else in the installer changed. The native path is untouched.

---

## GATES

    G1 provenance   pass   edition agrees in 3 places (v9); higher than v8;
                           v8 still in history
    G2 secrets      pass   grep for key-shaped strings over the tree: 0 hits
    G3 analysis     pass   bash -n on install.sh prints nothing; the generated
                           launcher on the phone parses (bash -n) and runs
    G4 dead code    n/a    no code added, one line changed
    G5 dead loops   n/a    no loop or wait added
    G6 stress       n/a
    G7 budgets      pass   install.sh +9 lines; no new network destination
    G8 upgrade      PARTIAL — see below
    G9 record       this document

## THE FOUR TESTS

    TEST 1  the mechanism, alone      an explicit socket in a 0700 dir: a
                                      print-mode session created the socket,
                                      and a Stop hook inside it saw
                                      CLAUDE_CODE_MESSAGING_SOCKET and
                                      CLAUDE_CODE_MESSAGING_TOKEN in its
                                      environment. Measured on the phone.
    TEST 2  the running app           an interactive session on a pty with the
                                      same flag: a message written to the
                                      socket was answered by the session
                                      (termux-tools/tests/test7_notify.py,
                                      17 checks)
    TEST 3  the ugly cases            a 755 directory is refused with a clear
                                      message (measured); a second session gets
                                      its own path (cc-<pid>.sock), so two
                                      sessions do not collide on one socket
    TEST 4  the upgrade               the patched launcher was installed over
                                      the v8 one on the phone by editing it in
                                      place; the v8 copy is kept at
                                      ~/.claude/backups/claude-launcher.bak-*

## NOT TESTED

* **This repository's own four-test suite does not run on the phone.** It
  builds a stubbed Termux and 25 of its 54 checks fail here — identically on
  the untouched v8 `install.sh` and on this one (measured both ways, same 25),
  so the failures are the suite's sandbox meeting a real Termux, not this
  change. The suite was written to run off the phone, and no off-phone
  machine was available for this edition.
* **The native path was not exercised.** Its launcher was not changed.
* **A fresh `curl | bash` install of v9 was not run.** The launcher line was
  verified as installed on the phone by hand, and the installer parses; the
  installer was not executed end to end for this edition.
* **Rollback** is the v8 launcher copy in `~/.claude/backups`, not a
  re-run of the v8 installer.
