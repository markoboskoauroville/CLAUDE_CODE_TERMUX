# CLAUDE_CODE_TERMUX

Install Claude Code on an Android phone through Termux, with one command.

```bash
curl -fsSL https://raw.githubusercontent.com/markoboskoauroville/CLAUDE_CODE_TERMUX/main/install.sh | bash
```

Then just:

```bash
claude
```

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

Run with no flags and the script asks which one you want. If you are piping from `curl` (no interactive terminal) it defaults to `--native`.

```bash
bash install.sh --native      # light
bash install.sh --proot       # sturdy
bash install.sh --extras      # also install node, python, openssh, jq
bash install.sh --native --update
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

Both paths also install `claude-termux-update`.

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

## Security note

This script downloads a binary from Anthropic's CDN and verifies its published SHA-256 before installing it. It asks for no credentials and stores none. Read it before you pipe it into bash — that is good practice with any installer, including this one.

The native path relies on a community compatibility shim, not on official Android support. Anthropic tracks Android support at [anthropics/claude-code#50270](https://github.com/anthropics/claude-code/issues/50270). If an official `android-arm64` build ever ships, all of this becomes unnecessary.

## Credits

The patched-binary technique for Termux was worked out by the community — see [ferrumclaudepilgrim/claude-code-android](https://github.com/ferrumclaudepilgrim/claude-code-android) and [wallentx/claude-code-termux](https://github.com/wallentx/claude-code-termux), and the original description in the upstream issue above. This repo is an independent, smaller implementation of the same idea.

Claude Code is made by [Anthropic](https://www.anthropic.com). Termux is made by the [Termux project](https://github.com/termux/termux-app). `glibc-runner` comes from [termux/glibc-packages](https://github.com/termux/glibc-packages).

## License

MIT. See [LICENSE](LICENSE).
