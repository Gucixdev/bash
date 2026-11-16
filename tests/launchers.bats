#!/usr/bin/env bats
# comfylauncher and protonlauncher against fake binaries: nothing is downloaded, no game or ComfyUI really starts.

setup() {
	cd "$BATS_TEST_DIRNAME/.."
	export HOME="$BATS_TEST_TMPDIR/home" XDG_DATA_HOME="$BATS_TEST_TMPDIR/home/.local/share"
	mkdir -p "$HOME" "$BATS_TEST_TMPDIR/bin"
	export COMFY_HOME="$BATS_TEST_TMPDIR/data" COMFY_SRC="$BATS_TEST_TMPDIR/src" COMFY_VENV="$BATS_TEST_TMPDIR/venv" COMFY_YES=1 COMFY_NO_WINDOW=1 COMFY_PORT=$((20000 + RANDOM % 20000))
	export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

fake_git() {   # git clone URL DIR -> a ComfyUI-shaped directory
	cat > "$BATS_TEST_TMPDIR/bin/git" <<'EOT'
#!/bin/sh
if [ "$1" = clone ]; then for last; do :; done; mkdir -p "$last/.git"; echo 'print(1)' > "$last/main.py"; echo numpy > "$last/requirements.txt"; exit 0; fi
exit 0
EOT
	chmod +x "$BATS_TEST_TMPDIR/bin/git"
	cat > "$BATS_TEST_TMPDIR/bin/fakepy" <<'EOT'
#!/bin/bash
# fake python: `-m venv DIR` makes DIR/bin/python (this same script); `-m pip` succeeds; main.py "runs" for a while
if [ "$1" = -m ] && [ "$2" = venv ]; then mkdir -p "$3/bin"; cp "$0" "$3/bin/python"; exit 0; fi
if [ "$1" = -m ] && [ "$2" = pip ]; then echo "$*" >> "$(dirname "$0")/../pip.log"; exit 0; fi
case $1 in main.py) echo "fake comfy $*"; exec -a "python main.py" sleep 30 ;; esac
exit 0
EOT
	chmod +x "$BATS_TEST_TMPDIR/bin/fakepy"
	export COMFY_PYTHON="$BATS_TEST_TMPDIR/bin/fakepy"
}

@test "comfylauncher: --help comes from the header" {
	run ./launchers/comfylauncher/comfylauncher --help
	[ "$status" -eq 0 ]
	[[ "$output" == comfylauncher\ -* ]]
}

@test "comfylauncher: no arguments off a terminal prints the status instead of a menu" {
	run ./launchers/comfylauncher/comfylauncher < /dev/null
	[ "$status" -eq 0 ]
	[[ "$output" == *"installed : no"* ]]
}

@test "comfylauncher: start without ComfyUI degrades with the install hint" {
	run ./launchers/comfylauncher/comfylauncher start
	[ "$status" -eq 1 ]
	[[ "$output" == *"comfylauncher install"* ]]
}

@test "comfylauncher: flags get --lowvram under 6 GB, --cpu without a GPU" {
	cat > "$BATS_TEST_TMPDIR/bin/nvidia-smi" <<'EOT'
#!/bin/sh
case $* in -L) echo "GPU 0: fake" ;; *) echo 4096 ;; esac
EOT
	chmod +x "$BATS_TEST_TMPDIR/bin/nvidia-smi"
	run ./launchers/comfylauncher/comfylauncher status
	[[ "$output" == *"--lowvram"* ]]
	COMFY_ACCEL=cpu run ./launchers/comfylauncher/comfylauncher status
	[[ "$output" == *"--cpu"* ]]
	printf '#!/bin/sh\ncase $* in -L) echo GPU ;; *) echo 24576 ;; esac\n' > "$BATS_TEST_TMPDIR/bin/nvidia-smi"
	run ./launchers/comfylauncher/comfylauncher status
	[[ "$output" == *"--highvram"* ]]
}

@test "comfylauncher: install shows the plan, builds the venv; start/stop use a pid file" {
	fake_git
	run ./launchers/comfylauncher/comfylauncher install
	[ "$status" -eq 0 ]
	[[ "$output" == *"will do:"* ]]
	[ -x "$COMFY_VENV/bin/python" ]
	[ -f "$COMFY_HOME/extra_model_paths.yaml" ]
	COMFY_WAIT=1 run ./launchers/comfylauncher/comfylauncher start
	[ -f "$COMFY_HOME/comfy.pid" ]
	run ./launchers/comfylauncher/comfylauncher status
	[[ "$output" == *"running   : yes"* ]]
	run ./launchers/comfylauncher/comfylauncher stop
	[[ "$output" == *stopped* ]]
	run ./launchers/comfylauncher/comfylauncher status
	[[ "$output" == *"running   : no"* ]]
}

@test "comfylauncher: models lists files and links a directory" {
	mkdir -p "$COMFY_HOME/models/checkpoints" "$BATS_TEST_TMPDIR/other/loras"
	: > "$COMFY_HOME/models/checkpoints/a.safetensors"
	: > "$BATS_TEST_TMPDIR/other/loras/b.safetensors"
	run ./launchers/comfylauncher/comfylauncher models link "$BATS_TEST_TMPDIR/other"
	[ "$status" -eq 0 ]
	run ./launchers/comfylauncher/comfylauncher models
	[[ "$output" == *"a.safetensors"* && "$output" == *"b.safetensors"* ]]
	grep -q linked_1 "$COMFY_HOME/extra_model_paths.yaml"
}

@test "comfylauncher: unknown command fails" {
	run ./launchers/comfylauncher/comfylauncher frobnicate
	[ "$status" -eq 1 ]
}

# ---- protonlauncher -------------------------------------------------------

fake_proton() {
	T="$HOME/.steam/steam/compatibilitytools.d"
	mkdir -p "$T/GE-Proton9-1" "$T/GE-Proton10-2"
	for v in GE-Proton9-1 GE-Proton10-2; do
		cat > "$T/$v/proton" <<'EOT'
#!/bin/sh
echo "PROTON argv: $*" > "$FAKE_LOG"
echo "COMPAT=$STEAM_COMPAT_DATA_PATH" >> "$FAKE_LOG"
echo "ASYNC=${DXVK_ASYNC:-}" >> "$FAKE_LOG"
EOT
		chmod +x "$T/$v/proton"
	done
	export FAKE_LOG="$BATS_TEST_TMPDIR/fake.log"
}

@test "protonlauncher: --help and no-argument non-tty both work" {
	run ./launchers/protonlauncher/protonlauncher --help
	[ "$status" -eq 0 ]
	run ./launchers/protonlauncher/protonlauncher < /dev/null
	[ "$status" -eq 0 ]
}

@test "protonlauncher: tools sorts newest first and picks the newest GE" {
	fake_proton
	run ./launchers/protonlauncher/protonlauncher tools
	[ "${lines[1]%%	*}" = GE-Proton10-2 ]
	run ./launchers/protonlauncher/protonlauncher run -n "$BATS_TEST_DIRNAME/launchers.bats"
	[[ "$output" == *"tool    : GE-Proton10-2"* ]]
}

@test "protonlauncher: run -n only shows the plan, run executes the fake proton in its own prefix" {
	fake_proton
	mkdir -p "$BATS_TEST_TMPDIR/Games/Cool Game"
	: > "$BATS_TEST_TMPDIR/Games/Cool Game/game.exe"
	run ./launchers/protonlauncher/protonlauncher run -n "$BATS_TEST_TMPDIR/Games/Cool Game/game.exe"
	[ "$status" -eq 0 ]
	[ ! -e "$FAKE_LOG" ]
	run ./launchers/protonlauncher/protonlauncher run -e dxvk-async "$BATS_TEST_TMPDIR/Games/Cool Game/game.exe" -windowed
	[ "$status" -eq 0 ]
	grep -q 'run .*game.exe -windowed' "$FAKE_LOG"
	grep -q "COMPAT=.*prefixes/Cool_Game" "$FAKE_LOG"
	grep -q 'ASYNC=1' "$FAKE_LOG"
	run ./launchers/protonlauncher/protonlauncher list
	[[ "$output" == *"Cool_Game"*"GE-Proton10-2"*"dxvk-async"* ]]
}

@test "protonlauncher: no Proton install gives a hint, not a crash" {
	run ./launchers/protonlauncher/protonlauncher run -n "$BATS_TEST_DIRNAME/launchers.bats"
	[ "$status" -eq 1 ]
	[[ "$output" == *"no Proton install found"* ]]
}

@test "protonlauncher: bad prefix names and unknown presets are refused" {
	fake_proton
	run ./launchers/protonlauncher/protonlauncher prefix new '../evil'
	[ "$status" -eq 1 ]
	run ./launchers/protonlauncher/protonlauncher run -n -e nope "$BATS_TEST_DIRNAME/launchers.bats"
	[ "$status" -eq 1 ]
}

@test "protonlauncher: missing optional wrappers only warn" {
	fake_proton
	run ./launchers/protonlauncher/protonlauncher run -n --mangohud "$BATS_TEST_DIRNAME/launchers.bats"
	[ "$status" -eq 0 ]
}
