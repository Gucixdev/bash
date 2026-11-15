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
