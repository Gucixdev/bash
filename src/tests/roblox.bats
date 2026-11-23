#!/usr/bin/env bats
# roblox: no network and no Roblox tools needed. Fake rojo, luau-analyze and curl on PATH record what they were given.

setup() {
	cd "$BATS_TEST_DIRNAME/.." || return
	T=$BATS_TEST_TMPDIR
	RB=$PWD/roblox
	export HOME=$T/home
	mkdir -p "$HOME" "$T/fake" "$T/work"
	unset ROBLOX_API_KEY ROBLOX_UNIVERSE_ID ROBLOX_PLACE_ID ROBLOX_API ROBLOX_VERSION_TYPE
	KEY=rk-SECRET-key-123
	cd "$T/work" || return
}

# fakes: install rojo, luau-analyze and curl on PATH
fakes() {
	printf '#!/bin/sh\necho "$@" > "%s/rojo.argv"\nwhile [ $# -gt 0 ]; do [ "$1" = -o ] && out=$2; shift; done\nprintf PLACE > "$out"\n' "$T" > "$T/fake/rojo"
	printf '#!/bin/sh\necho "$@" > "%s/luau.argv"\nexit ${LUAU_RC:-0}\n' "$T" > "$T/fake/luau-analyze"
	printf '#!/bin/sh\nprintf "%%s\\n" "$@" > "%s/curl.argv"\ncfg=\nwhile [ $# -gt 0 ]; do [ "$1" = --config ] && cfg=$2; shift; done\ncat "$cfg" > "%s/curl.cfg"\nstat -c %%a "$cfg" > "%s/curl.mode"\necho "$cfg" > "%s/curl.cfgpath"\necho "{\\"versionNumber\\":7}"\nexit ${CURL_RC:-0}\n' "$T" "$T" "$T" "$T" > "$T/fake/curl"
	chmod +x "$T/fake/"*
	export PATH=$T/fake:$PATH
}

# bare: a PATH with only the basics the script needs, so rojo/luau-analyze/selene/stylua/curl are surely absent
bare() {
	mkdir -p "$T/bare"
	local c p
	for c in bash env sed grep awk find sort tr head tail wc dirname basename cat mkdir mktemp chmod rm stat; do
		p=$(command -v "$c") && ln -sf "$p" "$T/bare/$c"
	done
	export PATH=$T/bare
}

nokey() { if grep -q "$KEY" "$T/curl.argv"; then echo "key found in curl argv"; return 1; fi; }

proj() { # a project with ids, a place file and no key
	"$RB" new demo > /dev/null
	cd demo || return
	mkdir -p build
	printf PLACE > build/demo.rbxl
	export ROBLOX_UNIVERSE_ID=111 ROBLOX_PLACE_ID=222
}

@test "roblox: --help prints the header" {
	run "$RB" --help
	[ "$status" -eq 0 ]
	[[ $output == *"roblox new NAME"* ]]
	[[ $output == *"Exit status"* ]]
}

@test "roblox: usage errors exit 2" {
	run "$RB"
	[ "$status" -eq 2 ]
	run "$RB" frobnicate
	[ "$status" -eq 2 ]
	run "$RB" new
	[ "$status" -eq 2 ]
	run "$RB" new 'bad name'
	[ "$status" -eq 2 ]
}

@test "roblox new: scaffolds the Rojo project" {
	run "$RB" new demo
	[ "$status" -eq 0 ]
	for f in default.project.json src/ServerScriptService/Main.server.luau src/ReplicatedStorage/Greeting.luau \
		src/StarterPlayer/StarterPlayerScripts/Client.client.luau .gitignore README.md roblox.conf selene.toml; do
		[ -s "demo/$f" ]
	done
	grep -q '"name": "demo"' demo/default.project.json
	grep -q '"\$path": "src/ServerScriptService"' demo/default.project.json
	grep -q '^build/' demo/.gitignore
	[ "$(wc -l < demo/README.md)" -le 30 ]
}

@test "roblox new: idempotent, never overwrites" {
	"$RB" new demo > /dev/null
	echo mine > demo/src/ServerScriptService/Main.server.luau
	run "$RB" new demo
	[ "$status" -eq 0 ]
	[ "$(cat demo/src/ServerScriptService/Main.server.luau)" = mine ]
	[[ $output == *"kept"* ]]
}

@test "roblox check: no project is exit 3" {
	run "$RB" check
	[ "$status" -eq 3 ]
}

@test "roblox check: no checker installed degrades with a message, exit 0" {
	proj
	bare
	run "$RB" check
	[ "$status" -eq 0 ]
	[[ $output == *"luau-analyze not installed"* ]]
	[[ $output == *"selene not installed"* ]]
	[[ $output == *"stylua not installed"* ]]
	[[ $output == *"no checker installed"* ]]
}

@test "roblox check: calls luau-analyze with the scripts and fails when it does" {
	proj
	fakes
	run "$RB" check
	[ "$status" -eq 0 ]
	grep -q 'Main.server.luau' "$T/luau.argv"
	grep -q 'Greeting.luau' "$T/luau.argv"
	LUAU_RC=1 run "$RB" check
	[ "$status" -eq 1 ]
}

@test "roblox check: a project path that does not exist is reported" {
	proj
	mv src/ReplicatedStorage "$T/gone"
	bare
	run "$RB" check
	[ "$status" -eq 1 ]
	[[ $output == *"src/ReplicatedStorage"* ]]
}

@test "roblox build: runs rojo build -o build/NAME.rbxl" {
	proj
	fakes
	run "$RB" build
	[ "$status" -eq 0 ]
	[ "$(cat "$T/rojo.argv")" = "build -o build/demo.rbxl" ]
	[ -f build/demo.rbxl ]
}

@test "roblox build: rojo missing says how to get it, exit 3, nothing installed" {
	proj
	bare
	run "$RB" build
	[ "$status" -eq 3 ]
	[[ $output == *"rojo is not installed"* ]]
	[[ $output == *"cargo install rojo"* ]]
}

@test "roblox build: a project file without a name stops before rojo runs" {
	proj
	fakes
	printf '{ "tree": { "$className": "DataModel" } }\n' > default.project.json
	run "$RB" build
	[ "$status" -eq 3 ]
	[ ! -e "$T/rojo.argv" ]
	[ ! -e build/.rbxl ]
}

@test "roblox new: a dangling symlink is kept, nothing is written through it" {
	mkdir demo
	ln -s "$T/outside.txt" demo/selene.toml
	run "$RB" new demo
	[ "$status" -eq 0 ]
	[ ! -e "$T/outside.txt" ]
	[ -L demo/selene.toml ]
}

@test "roblox new: a path that cannot be created is an error, not a ready message" {
	mkdir demo
	: > demo/src
	run "$RB" new demo
	[ "$status" -eq 1 ]
	[[ $output != *"ready:"* ]]
}

@test "roblox check: two \"\$path\" entries on one line are both checked" {
	proj
	printf '{ "name": "demo", "tree": { "$className": "DataModel", "A": { "$path": "nowhere" }, "B": { "$path": "src/ServerScriptService" } } }\n' > default.project.json
	run "$RB" check
	[ "$status" -eq 1 ]
	[[ $output == *"nowhere"* ]]
}

@test "roblox publish: runs roblox_publish (same dry run)" {
	fakes
	proj
	run "$RB" publish
	[ "$status" -eq 0 ]
	[[ $output == *"DRY RUN"* ]]
	[[ $output == *"roblox_publish:"* ]]
}

@test "roblox: shellcheck clean" {
	command -v shellcheck > /dev/null || skip "shellcheck missing"
	cd "$BATS_TEST_DIRNAME/.." || return
	run shellcheck -S warning roblox
	[ "$status" -eq 0 ]
}
