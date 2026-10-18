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

## What it looks like

`logcollector -n -s "2 hours ago"` on a desktop with a couple of failing units:

```
logcollector summary (since 2 hours ago)

err      1 lines
warning  44 lines

failed units:
  cachyos-iw-set-regdomain.service     loaded failed failed Set Wireless Regulatory Domain on Timezone Change
  systemd-networkd-wait-online.service loaded failed failed Wait for Network to be Online

most repeated errors:
  1   entries --

skipped:
  coredumps.txt: no output (needs privileges, or nothing logged)
```

`sniff -` on a few lines of `tcpdump -nn` output (sample, a synthetic capture):

```
9 packets, 3.2 KiB in 4.4s (749.318 B/s)

protocols
  icmp         1 packets        64 B
  udp          4 packets       240 B
  arp          1 packets        28 B
  tcp          3 packets     2.9 KiB

busiest conversations
     1.9 KiB  142.250.74.46 <-> 192.168.1.10
      1000 B  2001:db8::1 <-> 2001:db8::2

services
     2.9 KiB  tcp/https (443)
       74 B  udp/dns (53)

DNS names asked
           1  example.com.
```

## Principles

- **One file, no runtime dependency on this repo.** Interactive tools
  carry the few `lt_*` UI functions they call (selection menus with
  preview and key hints) as a marked block copied from `lib/lazytui`,
  so a tool still runs after being copied to another machine.
- **Wrap the real thing.** `ezcontainers` drives whichever of Docker and
  Podman is installed, `flatseal` drives `flatpak`, `wifi` drives
  NetworkManager, iwd or wpa_supplicant, whichever is running. `gh`, `hf`
  and `nmap` go on PATH under the real tool's name: they add their own
  commands and views and hand everything else to the real one, which they
  find by skipping themselves. Link them into a directory that comes before
  the real one on PATH (`~/.local/bin` usually does).
- **Degrade, don't die.** A missing optional dependency means a simpler
  path and a one-line message. A missing required one fails fast with the
  install command.
- **Show before doing.** Anything destructive lists what it will touch
  and asks once. `cleaner` never removes packages on its own.
- **No secrets in the repo.** Tokens come from the environment
  (`GH_TOKEN`, `HF_TOKEN`, see `secrets.example`; the shell loads them from `~/.secrets`).
  `gh` hands its token to curl on stdin, so it never shows up in `ps`.

Every tool prints its header with `--help`.

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
| `wifi` | Wi-Fi picker over NetworkManager, iwd or wpa_supplicant. |
| `btth` | Bluetooth picker over `bluetoothctl`. |
| `metadata_cleaner` | Strip EXIF and other metadata into a new `clean-NAME` file. mat2 or exiftool, else ffmpeg or ImageMagick. |
| `nmap` | Presets in front of the real nmap, `nmap -- ARGS` passes through. Finds the real nmap by skipping itself, so it is safe on PATH under that name, though linking it as `nmap-presets` keeps plain `nmap` untouched. |
| `sniff` | What is this machine talking to: capture N seconds and get totals, protocol mix, busiest conversations, services and DNS names. `-r` reads a pcap, `-` reads `tcpdump -nn` text, `sniff conns` shows live connections per process without root. |
| `findfat` | Biggest directories and files under a path, one filesystem only. `-dir`, `-file`, `-n COUNT`. |
| `morph` | `mv` for formats: `morph a.png a.webp`, picks magick/ffmpeg/assimp/fontforge/pandoc by the two extensions. Never overwrites without `-f`. |
| `fixmedia` | Repair broken video, audio and images into `fixed-NAME`: re-mux, then re-encode; images re-saved. `-c` only checks. |
| `manwriter` | Turn a script's header comment into a man page: `manwriter -d man tool...`. `manwriter new` writes a skeleton. |

## Libraries

`lib/` holds helpers other scripts call. Each is a command, so they work
from any language, not only sh:

```sh
settings set myapp theme dark          # ~/.config/myapp/settings, mode 600
settings get myapp theme               # MYAPP_THEME in the environment wins
eval "$(settings export myapp)"        # MYAPP_THEME='dark'

eval "$(wizard <<'STEPS'
name|Your name
shell|Shell|bash,zsh,fish|zsh
STEPS
)"                                     # fzf if installed, numbered prompt if not

evq push -q jobs "resize a.png"        # file-backed FIFO, safe for many consumers
dspq -j 3 "$url|$dest|label"           # parallel, atomic, resumable downloads
```

## Installers

`installer/` has clone, build and run scripts for things that do not
belong on `$PATH`: `comfysetup` (ComfyUI in a minimal container),
`blenderlauncher`, `tos` (TempleOS in QEMU).

## Layout

```
<tool>           the tools, one file each
lib/lazytui      reference copy of the lt_* UI helpers tools carry
lib/settings     per-app KEY=VALUE settings: get, set, unset, list, export
lib/wizard       ask a list of questions, print answers as eval-able assignments
lib/dspq, evq    download queue and event queue for shell scripts
installer/       one-shot clone, build, run scripts
tests/           bats: libs, every tool's offline behaviour, --help, shellcheck
```

## Ideas

Not built yet:

- **lazytui in C/ANSI.** The shell library stays as the reference; a C
  version of the same widgets (key hints bar, `raw` and `select` modes,
  actions declared as `key = command`) is planned.
- **dspq as a tool.** `lib/dspq` is a parallel, atomic download queue for
  shell scripts; a front end with a progress view would sit on top.

## Status

Tested on Arch (CachyOS) with Hyprland. `wifi` (iwd, wpa_supplicant
paths), `scenario` (cnee backend) and the non-pacman branches of
`cleaner` follow the tools' documented syntax and have not been run on a
live system. The tests cover what can run without root, network or a display;
`sniff` capture itself needs root and was verified on synthetic
`tcpdump` output only.

MIT, see `LICENSE`.
