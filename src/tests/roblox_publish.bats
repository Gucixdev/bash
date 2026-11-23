#!/usr/bin/env bats
# roblox_publish: no network and no Roblox tools needed. Fake rojo, luau-analyze and curl on PATH record what they were given.

setup() {
	cd "$BATS_TEST_DIRNAME/.." || return
	T=$BATS_TEST_TMPDIR
	RB=$PWD/roblox
	PB=$PWD/roblox_publish
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

@test "roblox_publish: dry run prints the request, masks the key, never calls curl" {
	proj
	fakes
	export ROBLOX_API_KEY=$KEY
	run "$PB"
	[ "$status" -eq 0 ]
	[[ $output == *"DRY RUN"* ]]
	[[ $output == *"POST https://apis.roblox.com/universes/v1/111/places/222/versions?versionType=Published"* ]]
	[[ $output == *"x-api-key: ********"* ]]
	[[ $output == *"application/octet-stream"* ]]
	[[ $output != *"$KEY"* ]]
	[ ! -e "$T/curl.argv" ]
}

@test "roblox_publish: --saved changes versionType; ids from roblox.conf" {
	proj
	fakes
	unset ROBLOX_UNIVERSE_ID ROBLOX_PLACE_ID
	printf 'ROBLOX_UNIVERSE_ID=5\nROBLOX_PLACE_ID="6"\n' > roblox.conf
	run "$PB" --saved
	[ "$status" -eq 0 ]
	[[ $output == *"universes/v1/5/places/6/versions?versionType=Saved"* ]]
}

@test "roblox_publish --yes: curl gets the URL, headers and body file; key is not in argv" {
	proj
	fakes
	export ROBLOX_API_KEY=$KEY
	run "$PB" --yes
	[ "$status" -eq 0 ]
	[[ $output == *"versionNumber"* ]]
	nokey
	[[ $output != *"$KEY"* ]]
	grep -qx 'url = "https://apis.roblox.com/universes/v1/111/places/222/versions?versionType=Published"' "$T/curl.cfg"
	grep -qx 'request = "POST"' "$T/curl.cfg"
	grep -qx "header = \"x-api-key: $KEY\"" "$T/curl.cfg"
	grep -qx 'header = "Content-Type: application/octet-stream"' "$T/curl.cfg"
	grep -q "^data-binary = \"@.*/build/demo.rbxl\"" "$T/curl.cfg"
	[ "$(cat "$T/curl.mode")" = 600 ]
	[ ! -e "$(cat "$T/curl.cfgpath")" ]
}

@test "roblox_publish --yes: key from ~/.secrets" {
	proj
	fakes
	printf 'OTHER=1\nexport ROBLOX_API_KEY="%s"\n' "$KEY" > "$HOME/.secrets"
	run "$PB" --yes
	[ "$status" -eq 0 ]
	grep -qx "header = \"x-api-key: $KEY\"" "$T/curl.cfg"
	nokey
}

@test "roblox_publish --yes --api assets: PATCH with the multipart form, no universe id needed" {
	proj
	fakes
	unset ROBLOX_UNIVERSE_ID
	export ROBLOX_API_KEY=$KEY
	run "$PB" --yes --api assets
	[ "$status" -eq 0 ]
	grep -qx 'url = "https://apis.roblox.com/assets/v1/assets/222"' "$T/curl.cfg"
	grep -qx 'request = "PATCH"' "$T/curl.cfg"
	grep -qF 'form-string = "request={\"assetId\": 222, \"assetType\": \"Place\", \"published\": true}"' "$T/curl.cfg"
	grep -q '^form = "fileContent=@\\".*/build/demo.rbxl\\";type=application/octet-stream"' "$T/curl.cfg"
	nokey
}

@test "roblox_publish --yes: no key is exit 3 and curl is not called" {
	proj
	fakes
	run "$PB" --yes
	[ "$status" -eq 3 ]
	[[ $output == *"no API key"* ]]
	[ ! -e "$T/curl.argv" ]
}

@test "roblox_publish: dry run without a key still shows the request and says the key is missing" {
	proj
	fakes
	run "$PB"
	[ "$status" -eq 0 ]
	[[ $output == *"no key found"* ]]
}

@test "roblox_publish: missing ids or place file are exit 3" {
	proj
	fakes
	unset ROBLOX_PLACE_ID
	run "$PB"
	[ "$status" -eq 3 ]
	[[ $output == *"ROBLOX_PLACE_ID"* ]]
	export ROBLOX_PLACE_ID=222
	mv build/demo.rbxl "$T/moved.rbxl"
	run "$PB"
	[ "$status" -eq 3 ]
	[[ $output == *"roblox build"* ]]
}

@test "roblox_publish --yes: a failing upload is exit 1 and the temp file is gone" {
	proj
	fakes
	export ROBLOX_API_KEY=$KEY
	CURL_RC=22 run "$PB" --yes
	[ "$status" -eq 1 ]
	[ ! -e "$(cat "$T/curl.cfgpath")" ]
}

@test "roblox_publish: bad ids or key characters are refused" {
	proj
	fakes
	export ROBLOX_PLACE_ID='1;2'
	run "$PB"
	[ "$status" -eq 3 ]
	export ROBLOX_PLACE_ID=222 ROBLOX_API_KEY='a"b'
	run "$PB" --yes
	[ "$status" -eq 3 ]
	[ ! -e "$T/curl.argv" ]
}

@test "roblox_publish --yes: the key file is removed even when TMPDIR has a quote in it" {
	proj
	fakes
	export ROBLOX_API_KEY=$KEY
	mkdir -p "$T/it's tmp"
	TMPDIR="$T/it's tmp" run "$PB" --yes
	[ "$status" -eq 0 ]
	[ -z "$(ls -A "$T/it's tmp")" ]
}

@test "roblox_publish --yes --api assets: a comma or space in the place file path is one file" {
	proj
	fakes
	export ROBLOX_API_KEY=$KEY
	cp build/demo.rbxl "$T/a, b.rbxl"
	run "$PB" --yes --api assets --file "$T/a, b.rbxl"
	[ "$status" -eq 0 ]
	grep -qF "form = \"fileContent=@\\\"$T/a, b.rbxl\\\";type=application/octet-stream\"" "$T/curl.cfg"
}

@test "roblox_publish: --help prints the header" {
	run "$PB" --help
	[ "$status" -eq 0 ]
	[[ $output == *"roblox_publish [--yes]"* ]]
	[[ $output == *"Exit status"* ]]
}

@test "roblox_publish: an unknown argument is exit 2" {
	run "$PB" --frobnicate
	[ "$status" -eq 2 ]
}

@test "roblox_publish: shellcheck clean" {
	command -v shellcheck > /dev/null || skip "shellcheck missing"
	cd "$BATS_TEST_DIRNAME/.." || return
	run shellcheck -S warning roblox_publish
	[ "$status" -eq 0 ]
}
