# DELIVERY — edition v10, tested in an Android emulator (16–17.10.2026)

FOR        Marko's phone install of 16.10.2026, which stopped twice: patchelf would not
           start (libc++ older than it), then the native build segfaulted on start.
TESTED     in the Claude Code cloud session's Android emulator: Android 11 `aosp_atd`
           x86_64, Termux 0.118.3 from F-Droid, the one-line install typed into the
           Termux app itself (`untrusted_app_27`, as on a phone), install.sh fetched
           from `main` each run. The emulator is kept for later sessions:
           MANTRA_MANIFEST `modules/cloud-android.md` §9, repository
           `termux-emulator-image`.

## RESULT

    curl -fsSL .../main/install.sh -o cct.sh && bash cct.sh --yes

    INSTALL_EXIT=0, step 10: "claude --version says: 2.1.301 (Claude Code)"
    a second run over the first: "ubuntu is already here", same result, no warnings
    interactive `claude` in the app: running after 45 s, no crash
    restored from the saved image in a fresh session: the same, typed into the app

## WHAT THE EMULATOR FOUND (each fixed on main, each with a test that fails without it)

1. `--yes` picked native, the path never shown working on a phone. proot is now the default.
2. A patchelf newer than libc++ would not start. The installer upgrades libc++, then all packages.
3. dpkg's `openssl.cnf` question hung a fresh Termux for 30 minutes. apt runs with
   `--force-confdef --force-confold` and no stdin; an interrupted dpkg is finished first.
4. Docker Hub refused the Ubuntu image (429). The installer falls back to `mirror.gcr.io`.
5. `curl https://claude.ai/install.sh | bash` hid a failed download and step 7 said ok.
   It downloads to a file, uses pipefail, and ends by running `claude --version`.
6. The Python proot-distro keeps the rootfs in `containers/<name>/rootfs`; a second run
   could not see it. Both layouts are checked on disk.
7. The launcher bound the home directory twice and warned on every start. Fixed for the
   new layout; the bind stays for proot-distro 4 and for directories outside home.
8. An apt run killed inside Ubuntu blocked the next one. Step 7 finishes it first.

## NOT TESTED

- **Anything ARM.** The emulator is x86_64. The native path (`--native`, the patched
  `linux-arm64` binary) and its segfault on the Nothing Phone (2a) were not reproduced
  or explained; `--native` stays marked experimental.
- **The phone itself** after these fixes.
- **The mirror.gcr.io fallback live**: Docker Hub answered on the run that mattered; the
  fallback is proven by test 3 only.
- **Login.** Claude Code was started, never logged in.
- In the emulator the session's proxy and CA were written into Termux and Ubuntu; a phone
  needs neither, and the emulator cannot show a problem that only appears without them.
