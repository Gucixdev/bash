# ez* — fast, easy, standalone bash tools

A collection of terminal tools, each one a single file with zero
runtime dependency on anything else in this repo or on each other.
Pick the one you want, copy it, run it — nothing else to install first.

## Philosophy

- **Standalone by construction.** Several tools share an interactive-UI
  layer (`lib/lazytui.sh` — selection menus, previews, keybindings), but
  no tool `source`s it at runtime. Each one carries its own copy of the
  functions it calls, as a clearly-marked block, so every script still
  runs on its own once copied elsewhere. `lib/lazytui.sh` is the
  reference copy; there is no sync tool, so a fix means editing the
  library and the blocks that need it.
- **Wrap the real thing, don't reinvent it.** `ezcontainers` wraps
  whatever of Docker/Podman is actually installed, `logcollector` reads
  journalctl and falls back to `/var/log` plus `dmesg`. When the real
  tool is missing, fall back to the next-best thing (curl against a
  public REST API, a different backend) rather than failing outright.
- **Fallback over hard failure.** A missing optional dependency should
  degrade gracefully with a clear message, not crash. A missing
  *required* one fails fast with the install command, not a guess.
- **No secrets in the repo.** Tokens come from the environment
  (`GH_TOKEN`, `HF_TOKEN` — see `.env.example`; `gitgrab` uses `GH_TOKEN` for private repos), never a committed file.

## Quick start

```sh
cp .env.example .env    # fill in tokens if you have them, or just export them
./logcollector -n       # or any other tool below
```

## The tools

### Interactive managers (built on `lib/lazytui.sh`)

| Tool | What it does |
|---|---|
| `ezbacksnap` | Btrfs snapshots on a schedule + a snapshot before every update, single-file restore, rotating rsync backups — a Timeshift replacement. |
| `ezcontainers` | Terminal manager for containers/images/volumes/networks — one tool for Docker *and* Podman, drives whichever is installed. |
| `flatseal` | Terminal manager for Flatpak apps and their permissions. |
| `ezhf` | Browse the Hugging Face Hub and your local cache; uses the real `huggingface-cli` when present, curl against the public API otherwise. |

### Standalone utilities

| Tool | What it does |
|---|---|
| `btth` | Bluetooth device picker over `bluetoothctl`. |
| `wifi` | Wi-Fi picker — tries NetworkManager, then iwd, then wpa_supplicant. |
| `cleaner` | System cleanup wrapping the real tool for each kind of bloat (package cache, orphans, etc.), package-manager backend auto-detected. |
| `scenario` | Keyboard/mouse macro record + playback, picks a backend (evemu, etc.) that works across X11 and Wayland. |
| `screenshot` | Screenshot on Wayland or X11 with whatever's installed. |
| `snip` | Region screenshot straight to the clipboard (no file written) — pairs with `screenshot`. |
| `trash` | A real freedesktop.org Trash spec implementation (not a `trash-cli` wrapper). |
| `gitgrab` | Download one file from a GitHub repo (URL or `owner/repo path [ref]`), no clone. `GH_TOKEN` enables private repos. |
| `logcollector` | Support bundle for a time window: journal/kernel/failed units/package history/disk+memory, secrets redacted, one archive plus a summary of the most repeated errors. |
| `manwriter` | Turn a script's `<manwriter>` header comment into a man page on demand (`manwriter new` writes a skeleton). Nothing generated is committed. |
| `todo` | Minimal todo.txt-convention task capture. |
| `bdfeditor` | Terminal editor for BDF bitmap fonts (Python). |
| `metadata_cleaner` | Strip EXIF/metadata from a file — prefers `mat2`/`exiftool`, falls back to ffmpeg/ImageMagick. |
| `nmap` | Friendlier presets over real `nmap` (quick/full/ping-sweep/service-detect); `nmap -- ARGS` passes straight through. |
| `sniff` | Quick `tcpdump` capture with interface/filter presets. |

### `installer/`

One-shot "clone, build, run" scripts for things that don't belong in
`$PATH` day to day: `comfysetup` (ComfyUI in a minimal container image),
`blenderlauncher`, `tos` (TempleOS in QEMU).

## Testing

```sh
bats tests/
```

`tests/syntax.bats` parses every script. `tests/new-tools.bats`
exercises real error paths and dispatch logic for the tools that don't
need root/network/a display to test honestly.

## Structure

```
ez*, and the standalone utilities   — the tools themselves
lib/                                 — lt_* UI helpers (reference copy of what tools carry)
docs/                                — plain-text notes for the lib/ helpers
installer/                           — one-shot clone+build+run scripts
tests/                               — bats
```
