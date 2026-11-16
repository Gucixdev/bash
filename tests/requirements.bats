#!/usr/bin/env bats
# templates/requirements with fake package managers and tools on PATH (nothing is installed for real).

setup() {
	cd "$BATS_TEST_TMPDIR" || return
	cp "$BATS_TEST_DIRNAME/../templates/requirements" ./requirements
	mkdir -p fake; log=$PWD/calls.log; : > "$log"
	for t in sudo pacman npm cargo go; do
		printf '#!/bin/sh\necho "%s $*" >> "%s"\n' "$t" "$log" > "fake/$t"
		chmod +x "fake/$t"
	done
	# python3 -m venv .venv makes a venv whose pip is a recorder
	printf '#!/bin/sh\necho "python3 $*" >> "%s"\nmkdir -p .venv/bin\nprintf "#!/bin/sh\\necho pip \\$* >> %s\\n[ \\"\\$1\\" = show ] && exit 1\\nexit 0\\n" > .venv/bin/pip\nchmod +x .venv/bin/pip\n' "$log" "$log" > fake/python3
	chmod +x fake/python3
	export PATH=$PWD/fake:/usr/bin:/bin
}

@test "check fails while something is missing and changes nothing" {
	printf 'cmd nonexistent-tool-xyz pacman=thepkg\n' > requirements.list
	run ./requirements check
	[ "$status" -eq 1 ]
	[[ $output == *"missing cmd nonexistent-tool-xyz (package thepkg)"* ]]
	[ ! -s calls.log ]
}

@test "install runs the system package manager once with all missing packages" {
	printf 'cmd aaa-missing\ncmd bbb-missing pacman=bpkg\ncmd sh\n' > requirements.list
	run ./requirements
	[ "$status" -eq 0 ]
	grep -qx 'sudo pacman -S --needed --noconfirm aaa-missing bpkg' calls.log || { cat calls.log; false; }
}

@test "pip goes into ./.venv, npm into ./, cargo and go into ./.local" {
	printf 'pip requests==2.0\nnpm left-pad@1.3.0\ncargo ripgrep 14.0.0\ngo example.com/x/tool@v1.0.0\n' > requirements.list
	run ./requirements
	[ "$status" -eq 0 ]
	grep -q 'python3 -m venv .venv' calls.log
	grep -q 'pip install -q requests==2.0' calls.log
	grep -q 'npm install --no-audit --no-fund --ignore-scripts --prefix . left-pad@1.3.0' calls.log
	grep -q 'cargo install --locked --root .local ripgrep --version 14.0.0' calls.log
	grep -q 'go install example.com/x/tool@v1.0.0' calls.log
}

@test "what is already there is not installed again" {
	mkdir -p node_modules/left-pad .local/bin; : > .local/bin/ripgrep; chmod +x .local/bin/ripgrep
	printf 'npm left-pad@1.3.0\ncargo ripgrep\ncmd sh\n' > requirements.list
	run ./requirements
	[ "$output" = "requirements: everything is installed" ]
	[ ! -s calls.log ]
	run ./requirements check
	[ "$status" -eq 0 ]
}

@test "-n shows the commands and runs none" {
	printf 'cmd zzz-missing\n' > requirements.list
	run ./requirements -n
	[[ $output == *"run     sudo pacman"* ]]
	[ ! -s calls.log ]
}

@test "a failing step is reported and the exit code is 1" {
	printf '#!/bin/sh\nexit 1\n' > fake/npm
	printf 'npm left-pad\n' > requirements.list
	run ./requirements
	[ "$status" -eq 1 ]
	[[ $output == *FAILED* ]]
}

@test "refs runs download_references only when it is there and references/ is empty" {
	printf '#!/bin/sh\necho refs-ran >> "%s"\nmkdir -p references/x\n' "$PWD/calls.log" > download_references; chmod +x download_references
	printf 'refs\n' > requirements.list
	run ./requirements
	grep -q refs-ran calls.log
	: > calls.log
	run ./requirements
	[ ! -s calls.log ]
}

@test "usage errors: no list, bad kind, bad argument" {
	run ./requirements
	[ "$status" -eq 2 ]
	printf 'frobnicate x\n' > requirements.list
	run ./requirements
	[ "$status" -eq 2 ]
	run ./requirements --nope
	[ "$status" -eq 2 ]
}
