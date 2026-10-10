# make install            symlink every tool into $(BIN)   (default ~/.local/bin)
# make uninstall          remove those links
# make test               bats tests/
# make lint               shellcheck, warnings and errors only
# make man                write man pages from the script headers into ./man

PREFIX ?= $(HOME)/.local
BIN    ?= $(PREFIX)/bin

# nmap is installed as nmap-presets: a wrapper named nmap would shadow the real one
TOOLS = btth cleaner ezcontainers ezhf flatseal gitgrab logcollector manwriter \
        metadata_cleaner scenario screenshot sniff snip todo trash wifi
SCRIPTS = $(TOOLS) nmap lib/lazytui.sh lib/dspq lib/evq \
          installer/blenderlauncher installer/comfysetup installer/tos

.PHONY: install uninstall test lint man

install:
	mkdir -p $(BIN)
	for t in $(TOOLS); do ln -sf $(CURDIR)/$$t $(BIN)/$$t; done
	ln -sf $(CURDIR)/nmap $(BIN)/nmap-presets

uninstall:
	for t in $(TOOLS) nmap-presets; do \
		if [ -L $(BIN)/$$t ]; then rm $(BIN)/$$t; fi; \
	done

test:
	bats tests/

lint:
	shellcheck -S warning $(SCRIPTS)

man:
	./manwriter -d man $(TOOLS) nmap
