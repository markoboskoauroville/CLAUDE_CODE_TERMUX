# CLAUDE_CODE_TERMUX v2

Install Claude Code on an Android phone through Termux.

```bash
curl -fsSL https://raw.githubusercontent.com/markoboskoauroville/CLAUDE_CODE_TERMUX/main/install.sh -o cct.sh
bash cct.sh
```

Then:

```bash
claude
```

Download first, run second. Piping an installer straight into bash means a
truncated download runs anyway; this one is written so that a truncated copy
does nothing at all, but downloading it first also lets you read it.

The installer prints a dependency table before it touches anything, numbers
every step, and shows a progress bar during the long silent stretches — apt,
the glibc layer, the 230 MB download, and proot.

---

## What you need first

1. **A 64-bit ARM Android phone** (Android 8 or newer). Check with `uname -m` — it must say `aarch64`.
2. **Termux from F-Droid or the Termux GitHub releases**, not from Google Play. The Play build is an old experimental branch. <https://f-droid.org/en/packages/com.termux/>
3. **A paid Claude plan** (Pro, Max, Team, Enterprise) or a Console API key. The free Claude plan does not include Claude Code.
4. **Space**: ~600 MB for the native path, ~2.5 GB for the proot path.

## Why a special installer is needed

Anthropic ships Claude Code as a single native binary linked against **glibc**. Android uses **Bionic**, a different C library, and there is no `android-arm64` build on the CDN — only `linux-arm64`. Running Anthropic's own `install.sh` in Termux downloads a binary that will not start.

This installer gives you two ways around that.

| | `--native` | `--proot` |
|---|---|---|
| Size on disk | ~600 MB | ~2.5 GB |
| Startup | fast | a second or two slower |
| How it works | official `linux-arm64` binary with its ELF interpreter repointed at Termux's `glibc-runner` | official installer inside a real Ubuntu rootfs |
| Files live in | Termux home, directly | Termux home, shared into Ubuntu |
| Fragility | a compatibility shim — an upstream change can break it | behaves like Claude Code on any Linux machine |

Run with no flags and the script asks which one you want. Piped from `curl`, with no terminal to ask at, it defaults to `--native` and says so.

```bash
bash cct.sh --native      # light
bash cct.sh --proot       # sturdy
bash cct.sh --extras      # also install node, python, openssh, jq
bash cct.sh --native --update
bash cct.sh --rollback    # go back to the previous build
bash cct.sh --quiet       # fewer lines, progress bars stay
```

## What the script actually does

**Preflight** — confirms Termux, confirms `aarch64`, warns if disk space is short.

**Native path**

1. Installs `tur-repo`, then `glibc-runner` and `patchelf`.
2. Asks `downloads.claude.ai` for the current version and its manifest.
3. Downloads the `linux-arm64` binary and **verifies its SHA-256** against the manifest. A mismatch aborts the install.
4. Runs `patchelf --set-interpreter` so the kernel loads it through Termux's glibc linker. Only the interpreter is rewritten — the library path is supplied at runtime instead, which avoids rewriting section headers on a binary that carries an appended payload.
5. Writes `$PREFIX/bin/claude`, a wrapper that sets `LD_LIBRARY_PATH`, gives it a writable `TMPDIR` (Android has no `/tmp`), sets `USE_BUILTIN_RIPGREP=0` so Termux's own ripgrep is used, and sets `DISABLE_AUTOUPDATER=1` — otherwise the built-in updater would quietly replace your patched binary with an unpatched one that cannot start.
6. Keeps the two most recent builds and deletes older ones.

**Proot path**

1. Installs `proot-distro` and an Ubuntu rootfs.
2. Runs Anthropic's official `install.sh` inside it.
3. Writes `$PREFIX/bin/claude`, which drops into Ubuntu with your Termux home mounted and runs `claude` there.

Both paths also install `claude-termux-update`. It downloads the installer to a file, checks it parses **and** that it carries its end-of-file marker, and only then runs it — a truncated installer parses perfectly and installs half an app.

## Updating

```bash
claude-termux-update
```

On the native path this re-downloads and re-patches the newest build. On the proot path it runs `claude update` inside Ubuntu. Do not use Claude Code's own `/update` on the native path — it is disabled for a reason.

## Uninstalling

```bash
bash uninstall.sh
```

Removes the launchers and the patched binary. Add `--all` to also delete `~/.claude` (your settings and session history) and the Ubuntu rootfs.

## Troubleshooting

**`claude: command not found`** — restart Termux, or run `hash -r`.

**`CANNOT LINK EXECUTABLE` / `library "libc.so.6" not found`** — the glibc layer is missing or the wrapper was bypassed. Run `pkg install glibc-runner` and re-run the installer. Always start it as `claude`, never by calling the binary in `$PREFIX/opt/claude-code/` directly.

**`Killed` partway through** — Android's low-memory killer. Close other apps, avoid running the installer from inside a Claude session, and try again.

**Download stalls or "unexpected content" from the CDN** — check the network, and check that Anthropic serves your region: <https://www.anthropic.com/supported-countries>

**Checksum mismatch** — a corrupted or intercepted download. The script deletes the file rather than installing it. Re-run; if it repeats, do not force it.

**Stuck on a Termux mirror prompt** — run `termux-change-repo`, pick a mirror near you, then re-run.

**Login browser never returns** — Termux cannot always catch the OAuth callback. Copy the URL Claude prints into your phone browser manually, then paste the code back.

**PDF reading fails** — `pkg install poppler` and make sure `which` is installed.

**`armv7l` or `armv8l` from `uname -m`** — your phone runs a 32-bit Android userland on 64-bit hardware. Neither path will work.

## What was tested, and what was not

```bash
bash tests/run_tests.sh      # the four tests
bash gates/run_gates.sh      # the nine delivery gates
```

These run off the phone against a stubbed Termux: fake CDN, fake packages, fake
patchelf, a fake claude binary. That covers the logic — every failure path,
the upgrade, the rollback — and it cannot cover the phone.

**Not tested, and not claimed:** that the real 230 MB glibc binary starts once
its interpreter is repointed; that `glibc-runner` installs cleanly from
`tur-repo` on your Android version; a real `proot-distro` Ubuntu install; the
OAuth login round trip through the Android browser; Android's low-memory killer
during a long download; real time and battery on mobile data.

Full record in [DELIVERY.md](DELIVERY.md).

## Security note

This script downloads a binary from Anthropic's CDN and verifies its published SHA-256 before installing it. It asks for no credentials and stores none. Read it before you pipe it into bash — that is good practice with any installer, including this one.

The native path relies on a community compatibility shim, not on official Android support. Anthropic tracks Android support at [anthropics/claude-code#50270](https://github.com/anthropics/claude-code/issues/50270). If an official `android-arm64` build ever ships, all of this becomes unnecessary.

## Credits

The patched-binary technique for Termux was worked out by the community — see [ferrumclaudepilgrim/claude-code-android](https://github.com/ferrumclaudepilgrim/claude-code-android) and [wallentx/claude-code-termux](https://github.com/wallentx/claude-code-termux), and the original description in the upstream issue above. This repo is an independent, smaller implementation of the same idea.

Claude Code is made by [Anthropic](https://www.anthropic.com). Termux is made by the [Termux project](https://github.com/termux/termux-app). `glibc-runner` comes from [termux/glibc-packages](https://github.com/termux/glibc-packages).

## License

MIT. See [LICENSE](LICENSE).

---

## Edition 9

`install.sh` is edition 9. The filename never changes, because
`claude-termux-update` fetches it by that address; the number lives in the
`edition:` line at the top of the file and in its last two lines.

What edition 3 adds:

- **Every step prints.** Nine numbered steps with seconds elapsed, and the
  output of every package command streams underneath instead of going to
  `/dev/null`. A quiet installer on a phone reads as a frozen one.
- **A real progress bar** for the 220 MB download, drawn from the bytes
  actually on disk against the byte count Anthropic publishes.
- **Running it twice is safe.** The checksum is verified on freshly downloaded
  bytes only. Verifying a file already on disk compares a patched binary
  against the figure for an unpatched one and always fails.
- **One copy of the completeness rule.** The four checks the updater runs
  before replacing anything live in a single function, emitted into the
  updater from that one copy.
- **It carries `# CCT_COMPLETE_V2`**, so a phone still on edition 2 can update
  to this one. Edition 2's updater rejects any installer without that line.
- **The glibc library path lives inside the binary**, written in as an rpath,
  never on `LD_LIBRARY_PATH`. An environment variable applies to every process
  the launcher starts, and the glibc directory contains a text linker script
  called `libc.so` — the same name Android uses for its own libc. Termux
  commands then load the script and die with `bad ELF magic: 2f2a2047`.

Coming from edition 2 and want to go back? Edition 2 refuses to install over a
patched binary, so clear it first:

```bash
rm -rf $PREFIX/opt/claude-code/versions
```

### The one-letter shortcut

The installer offers to add `alias c='claude'` to your `.bashrc` (or `.zshrc`),
so a new session starts Claude Code with one keystroke. It asks first when it
can, says what it added when it cannot ask, and `--no-alias` skips it. To
remove it later:

```bash
sed -i "/alias c='claude'/d" ~/.bashrc
```

### Checking it yourself

```bash
bash tests/run_four.sh      # the four tests; test 2 downloads ~230 MB
bash gates/gate.sh          # the nine gates
```

The delivery record, including everything that was **not** tested, is in
[DELIVERY-v9.md](DELIVERY-v9.md), and the edition before it in
[DELIVERY-v8.md](DELIVERY-v8.md).
