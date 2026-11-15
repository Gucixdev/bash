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
