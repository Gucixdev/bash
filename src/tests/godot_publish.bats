#!/usr/bin/env bats
# godot_publish: no network. Fake butler, gh and zip on PATH record what they were given.

setup() {
	cd "$BATS_TEST_DIRNAME/.." || return
	T=$BATS_TEST_TMPDIR
	GP=$PWD/godot_publish
	export HOME=$T/home
	mkdir -p "$HOME" "$T/fake" "$T/work/demo/build/linux"
	unset BUTLER_API_KEY GODOT_ITCH_TARGET GODOT_ITCH_CHANNEL GODOT_RELEASE_TAG GODOT_PUBLISH_DIR
	KEY=bk-SECRET-key-123
	cd "$T/work/demo" || return
	printf 'config_version=5\n\n[application]\n\nconfig/name="Demo Game"\n' > project.godot
	printf EXPORT > build/linux/game.x86_64
	export GODOT_ITCH_TARGET=me/demo GODOT_RELEASE_TAG=v1.0.0
	fakes
}

fakes() {
	printf '#!/bin/sh\necho "$@" > "%s/butler.argv"\necho "key=$BUTLER_API_KEY" > "%s/butler.env"\nexit ${BUTLER_RC:-0}\n' "$T" "$T" > "$T/fake/butler"
	printf '#!/bin/sh\necho "$@" >> "%s/gh.argv"\nexit ${GH_RC:-0}\n' "$T" > "$T/fake/gh"
	printf '#!/bin/sh\necho "$@" > "%s/zip.argv"\nout=; for a; do case $a in -*) ;; *) [ -z "$out" ] && out=$a ;; esac; done\nprintf Z > "$out"\n' "$T" > "$T/fake/zip"
	chmod +x "$T/fake/"*
	export PATH=$T/fake:$PATH
}

@test "godot_publish: --help prints the header" {
	run "$GP" --help
	[ "$status" -eq 0 ]
	[[ $output == *"godot_publish itch"* ]]
	[[ $output == *"Exit status"* ]]
}

@test "godot_publish: usage errors exit 2" {
	run "$GP"
	[ "$status" -eq 2 ]
	run "$GP" steam
	[ "$status" -eq 2 ]
	run "$GP" itch --frob
	[ "$status" -eq 2 ]
	run "$GP" itch a b
	[ "$status" -eq 2 ]
}

@test "godot_publish: outside a project, or with no export folder, is exit 3" {
	cd "$T"
	run "$GP" itch
	[ "$status" -eq 3 ]
	cd "$T/work/demo"
	run "$GP" itch nothere
	[ "$status" -eq 3 ]
	mkdir empty
	run "$GP" itch empty
	[ "$status" -eq 3 ]
}

@test "godot_publish itch: dry run shows the command, masks the key, runs nothing" {
	export BUTLER_API_KEY=$KEY
	run "$GP" itch build/linux
	[ "$status" -eq 0 ]
	[[ $output == *"DRY RUN"* ]]
	[[ $output == *"butler push build/linux me/demo:linux"* ]]
	[[ $output == *"********"* ]]
	[[ $output != *"$KEY"* ]]
	[ ! -e "$T/butler.argv" ]
}

@test "godot_publish itch --yes: butler gets the key in its environment only" {
	export BUTLER_API_KEY=$KEY
	run "$GP" itch build/linux --yes
	[ "$status" -eq 0 ]
	[ "$(cat "$T/butler.argv")" = "push build/linux me/demo:linux" ]
	[ "$(cat "$T/butler.env")" = "key=$KEY" ]
	[[ $output != *"$KEY"* ]]
}

@test "godot_publish itch --yes: key from ~/.secrets; channel from godot.conf" {
	echo "export BUTLER_API_KEY=\"$KEY\"" > "$HOME/.secrets"
	echo 'GODOT_ITCH_CHANNEL=win' > godot.conf
	run "$GP" itch build/linux --yes
	[ "$status" -eq 0 ]
	[ "$(cat "$T/butler.argv")" = "push build/linux me/demo:win" ]
	[ "$(cat "$T/butler.env")" = "key=$KEY" ]
}

@test "godot_publish itch --yes: no key is exit 3 and butler is not called; failure is exit 1" {
	run "$GP" itch build/linux --yes
	[ "$status" -eq 3 ]
	[ ! -e "$T/butler.argv" ]
	BUTLER_API_KEY=$KEY BUTLER_RC=1 run "$GP" itch build/linux --yes
	[ "$status" -eq 1 ]
}

@test "godot_publish itch: a missing or odd target is exit 3" {
	unset GODOT_ITCH_TARGET
	run "$GP" itch build/linux
	[ "$status" -eq 3 ]
	GODOT_ITCH_TARGET='me/demo; echo x' run "$GP" itch build/linux
	[ "$status" -eq 3 ]
	GODOT_ITCH_TARGET=nogame run "$GP" itch build/linux
	[ "$status" -eq 3 ]
}

@test "godot_publish github: dry run, then --yes zips and uploads, --create makes the release" {
	run "$GP" github build/linux
	[ "$status" -eq 0 ]
	[[ $output == *"gh release upload v1.0.0 build/Demo_Game-linux.zip --clobber"* ]]
	[ ! -e "$T/gh.argv" ]
	run "$GP" github build/linux --yes
	[ "$status" -eq 0 ]
	[ "$(cat "$T/gh.argv")" = "release upload v1.0.0 build/Demo_Game-linux.zip --clobber" ]
	[ -f build/Demo_Game-linux.zip ]
	run "$GP" github build/linux --yes --create
	[ "$(tail -n 1 "$T/gh.argv")" = "release create v1.0.0 build/Demo_Game-linux.zip --generate-notes" ]
	GH_RC=1 run "$GP" github build/linux --yes
	[ "$status" -eq 1 ]
}

@test "godot_publish github: tag is required and checked" {
	unset GODOT_RELEASE_TAG
	run "$GP" github build/linux
	[ "$status" -eq 3 ]
	GODOT_RELEASE_TAG='v1 && x' run "$GP" github build/linux
	[ "$status" -eq 3 ]
}

@test "godot_publish zip: dry run writes nothing, --yes writes the archive" {
	run "$GP" zip build/linux
	[ "$status" -eq 0 ]
	[ ! -e build/Demo_Game-linux.zip ]
	run "$GP" zip build/linux --yes
	[ "$status" -eq 0 ]
	[ -f build/Demo_Game-linux.zip ]
}

@test "godot_publish: DIR defaults to build/ (or GODOT_PUBLISH_DIR)" {
	run "$GP" zip
	[[ $output == *"Demo_Game-build.zip build"* ]]
	GODOT_PUBLISH_DIR=build/linux run "$GP" zip
	[[ $output == *"build/linux"* ]]
}

@test "godot_publish: shellcheck clean" {
	command -v shellcheck > /dev/null || skip "shellcheck missing"
	cd "$BATS_TEST_DIRNAME/.." || return
	run shellcheck -S warning godot_publish
	[ "$status" -eq 0 ]
}
