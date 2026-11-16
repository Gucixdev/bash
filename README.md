# bash

Small terminal tools in bash, one file each. They wrap the real
program (`flatpak`, `docker`/`podman`, `nmcli`, `grim`, `journalctl`)
instead of reimplementing it, fall back to the next-best backend when
it is missing, and run on their own once copied out of this repo.

```sh
git clone https://github.com/Gucixdev/bash && cd bash
./logcollector -n       # try one: a summary of what went wrong in the last day
ln -s "$PWD/logcollector" ~/.local/bin/    # put any tool on PATH
```

`bats tests/` runs the tests. Scripts are also kept clean under
`shellcheck -S warning`.

## Interactive managers

Built on `lib/lazytui`: arrows or Tab to move, space to mark rows
like nnn, `/` to search, a key bar always showing what is available.
The views need fzf 0.63 or newer. The C fzf they were built with draws the key
bar itself; with upstream fzf the bar is a footer, and 0.71 or newer also keeps
the cursor on its row when a view refreshes. An older fzf gets a numbered list.

| Tool | What it does | Needs |
|---|---|---|
| `gh` | lazygit, gh and GitHub in one. The git repo here: changes (stage, commit, push, pull, discard, stash, amend), log (show, checkout, cherry-pick, revert, reset), branches, stash. GitHub: your repos (public/private, remove, new), search, and `lens`, a repo's files without cloning it. Commands: `grab` (a file, a folder or a shallow clone), `grabdir`, `create`, `remove`, `public`, `private`, `lens`, `search`; anything else is the real gh. | git, curl, jq (or python3), fzf for the views; the real gh optional |
| `ezcontainers` | Containers, images, volumes, networks, pods and QEMU VMs in one list. Docker and Podman rows show up together, each action goes to the row's own engine. | docker or podman, qemu for VMs, fzf |
| `flatseal` | Flatpak apps and their permissions, layered the way flatpak layers them (manifest, global override, app override). Also scriptable: `flatseal allow\|deny\|default APP KEY`, `export`/`import`. | flatpak, fzf |
| `hf` | Browse the Hugging Face Hub and the local cache, sizes first, download or delete marked files; anything else (`hf download`, `hf auth login`, `hf cache ls`) is the real hf. | curl and jq (or python3), the real `hf` optional |
| `scenario` | Record and replay keyboard and mouse input, one recorder per device. | evemu (root) or xnee |
| `screenshot` | Full, screen, area, window or active window on Wayland or X11, to file and clipboard, with a notification. `-c` is clipboard only, nothing written to disk; `-d N` waits first. | grim/slurp, spectacle, maim, scrot, ... |

## Utilities

| Tool | What it does |
|---|---|
| `logcollector` | Support bundle for a time window: journal, warnings, errors, kernel log, failed units, package history, disk and memory. Secrets are redacted before anything is written, and it prints a summary of the most repeated errors. `-s "2 hours ago"`, `-I` also masks IPs and MACs. |
| `cleaner` | Bloat across package cache, journal, containers, Flatpak runtimes, language caches, `~/.cache` and Trash. Dry run first, one confirmation. Backend: pacman, apt, dnf, zypper, apk, xbps or portage. |
| `trash` | The freedesktop.org Trash spec, implemented directly, so file managers can restore what it deletes. |
| `todo` | todo.txt capture: `todo "task"`, `todo ls`, `todo done N`. |
| `skilltree` | Tree of Claude Code skills from their SKILL.md headers: priority, parts (`references/`), requirements, and the always-loaded description cost. `-w NAME` shows who requires NAME. |
| `claude_maintain` | Checks `~/.claude` for rot: broken skill links, memory index drift, bad settings JSON, hooks that point nowhere, what weighs most. Reports only; `-f` trashes broken skill links, nothing is deleted. |
| `agx` | Runs tools for AI agents (MCP servers, CLIs) without installing them, like npx: a registry row says npm, pip, git, a checked download or a Claude Code skill (`agx skill install`, pinned commit, links into ~/.claude/skills), the first run fetches into a cache after a yes, later runs work offline. `agx mcp NAME` prints the `claude mcp add` line. | npm, uv or python3, git, curl |
| `bake` | Describe an image once in a small `NAME.bake` file (base, pkg, `git URL REF DEST`, run, `check CMD => TEXT`, port/mount/gpu), then build a container, export a rootfs tarball, or run a QEMU VM (`kind vm`, ISO + disk). Git sources and ISOs follow upstream: `bake build` refetches, `bake outdated` says what moved. Ready-made `bakes/comfyui.bake` and `bakes/templeos.bake`. | podman or docker, qemu, git |
| `roblox` | Roblox games from the command line: `roblox new NAME` scaffolds a Rojo project, `check` runs luau-analyze/selene/stylua when installed, `build` runs rojo, `publish` uploads the place through Open Cloud as a dry run unless `--yes` (key from env or ~/.secrets, never on the command line). |
| `leads` | Finds public posts where someone asks for or complains about what you sell: `leads.queries` (SOURCE, TAB, QUERY) over HN Algolia, Reddit search JSON, a Mastodon instance's hashtag timeline and RSS/Atom; X, Facebook and LinkedIn are skipped (no free official API). `run` appends new hits to `leads.tsv` with a 0-100 score, `list --min N`, `open N` prints the url. Read-only, no keys, 1 request/s per host, 1 h cache, stops on 403/429. | python3 |
| `repos` | Keeps every git repo of one folder (`$REPOS_ROOT`, default `/data/dev/github`) in step with GitHub: `status`, `fetch`, `pull`, `push`, `needmerge`, `merge`. Never forces, never resets, never deletes; when both sides moved, the remote's version goes to the branch `needmerge/BRANCH` and nothing else changes. | git, fzf optional |
| `lean4/` | Proofs next to the tools they describe: `lean4/repos.lean` models `repos` (pull and push never lose a commit, a fast-forward only on a clean tree). `lean4/check` compiles every file and fails on `sorry`, an error or an unusual axiom. | lean (elan, no default needed) |
| `wifi` | Wi-Fi picker over NetworkManager, iwd or wpa_supplicant. |
| `btth` | Bluetooth picker over `bluetoothctl`. |
| `metadata_cleaner` | Strip EXIF and other metadata into a new `clean-NAME` file. mat2 or exiftool, else ffmpeg or ImageMagick. |
| `nmap` | Presets in front of the real nmap, `nmap -- ARGS` passes through. Finds the real nmap by skipping itself, so it is safe on PATH under that name, though linking it as `nmap-presets` keeps plain `nmap` untouched. |
| `sniff` | What is this machine talking to: capture N seconds and get totals, protocol mix, busiest conversations, services and DNS names. `-r` reads a pcap, `-` reads `tcpdump -nn` text, `sniff conns` shows live connections per process without root. |
| `findfat` | Biggest directories and files under a path, one filesystem only. `-dir`, `-file`, `-n COUNT`. |
| `morph` | `mv` for formats: `morph a.png a.webp`, picks magick/ffmpeg/assimp/fontforge/pandoc by the two extensions. Never overwrites without `-f`. |
| `fixmedia` | Find why a video, song, subtitle or picture misbehaves (cuts out, no or silent sound, DTS/AC3, 10-bit, subtitle garbage) and write `fixed-NAME`; VLC is the judge. `-c` only checks, `--sync`, `--shift`, `--embed`. |
| `manwriter` | Turn a script's header comment into a man page: `manwriter -d man tool...`. `manwriter new` writes a skeleton. |
| `textswap` | Privacy filter for a screenshot, photo or clip: swaps a fraction of the words (`--ratio`, default half) for random Chinese characters in the text's own colour on its own background; `--seed` repeats it exactly. Words from tesseract or `--boxes FILE`; videos at `--fps`, no flicker, audio kept ([container recipe](docs/textswap.md)). |

## Installers, launchers

| path | what |
|---|---|
| `comfy/comfylauncher` | ComfyUI in one folder (venv, no container): `install update start stop status models nodes logs doctor`, plus `gen flow loop qa card window` for the asset helpers in `comfy/helpers/`. No arguments: a menu. Data (models, nodes, output) in `comfy/data`, git-ignored. Adds `--lowvram` under 6 GB of VRAM. |
| `protonlauncher` | run a Windows exe through Proton (GE-Proton from Steam's `compatibilitytools.d`), one prefix per game, env presets, gamemode/mangohud/gamescope when present: `tools list run presets prefix winecfg winetricks doctor`. |
| `installer/blenderlauncher` | clone, build and run Blender. |
| `installer/templeos` | TempleOS in QEMU. |

`installer/` holds only real one-shot installers; long-lived tools sit at the top level or in their own folder.

## More

[What it looks like](docs/look.md), [principles](docs/principles.md), [libraries](docs/libs.md), [ideas](docs/ideas.md).

## Layout

```
<tool>           the tools, one file each
lib/lazytui      reference copy of the lt_* UI helpers tools carry
lib/settings     per-app KEY=VALUE settings: get, set, unset, list, export
lib/wizard       ask a list of questions, print answers as eval-able assignments
lib/dspq, evq    download queue and event queue for shell scripts
comfy/           comfylauncher + helpers (asset generation), one folder
installer/       one-shot clone, build, run scripts
templates/       run, build, setup, requirements, wizard, bench, compare, test, download_references: starting points
tests/           bats: libs, every tool's offline behaviour, --help, shellcheck
```

## Status

Tested on Arch (CachyOS) with Hyprland. `wifi` (iwd, wpa_supplicant
paths), `scenario` (cnee backend) and the non-pacman branches of
`cleaner` follow the tools' documented syntax and have not been run on a
live system. The tests cover what can run without root, network or a display;
`sniff` capture itself needs root and was verified on synthetic
`tcpdump` output only.

MIT, see `LICENSE`.
