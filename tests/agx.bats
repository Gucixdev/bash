#!/usr/bin/env bats
# agx against a real local npm package and a real local git repo (no network); pip and url against fakes.

setup() {
	cd "$BATS_TEST_DIRNAME/.." || return
	T=$BATS_TEST_TMPDIR
	export AGX_HOME=$T/cache AGX_REGISTRY=$T/reg.tsv XDG_DATA_HOME=$T/data HOME=$T/home
	mkdir -p "$HOME" "$T/pkg/bin" "$T/repo"
	printf '{"name":"hello-agx","version":"1.0.0","bin":{"hello-agx":"bin/h.js"}}\n' > "$T/pkg/package.json"
	printf '#!/usr/bin/env node\nconsole.log("hello", process.argv.slice(2).join(","));\n' > "$T/pkg/bin/h.js"
	chmod +x "$T/pkg/bin/h.js"
	git -C "$T/repo" init -q
	printf '#!/bin/sh\necho git-tool "$@" in $AGX_DIR\n' > "$T/repo/tool.sh"
	git -C "$T/repo" add tool.sh
	git -C "$T/repo" -c user.name=t -c user.email=t@t commit -qm init
	./agx add hello npm "$T/pkg" latest "" "local npm" > /dev/null
	./agx add gt git "$T/repo" HEAD 'sh "$AGX_DIR/src/tool.sh"' "local git" 'echo setup-ran > ../setup.txt' > /dev/null
}

@test "agx: refuses to fetch without a terminal and without -y" {
	run env AGX_YES= ./agx run hello a < /dev/null
	[ "$status" -ne 0 ]
	[[ "$output" == *"needs your yes"* ]]
	[ ! -e "$AGX_HOME/hello/.ok" ]
}

@test "agx: npm fetch, run with args, then run offline from the cache" {
	run env AGX_YES=1 ./agx run hello a b
	[ "$output" = "hello a,b" ]
	run env AGX_OFFLINE=1 ./agx hello x
	[ "$output" = "hello x" ]
}

@test "agx: npm lifecycle scripts run only with AGX_SCRIPTS=1" {
	mkdir -p "$T/pkg2/bin"
	printf '{"name":"post-agx","version":"1.0.0","bin":{"post-agx":"bin/p.js"},"scripts":{"postinstall":"touch %s/ran"}}\n' "$T" > "$T/pkg2/package.json"
	printf '#!/usr/bin/env node\nconsole.log("p");\n' > "$T/pkg2/bin/p.js"
	chmod +x "$T/pkg2/bin/p.js"
	(cd "$T/pkg2" && npm pack --silent > /dev/null)
	./agx add post npm "$T/pkg2/post-agx-1.0.0.tgz" latest post-agx > /dev/null
	AGX_YES=1 ./agx run post > /dev/null
	[ ! -e "$T/ran" ]
	AGX_YES=1 ./agx update post > /dev/null && AGX_YES=1 AGX_SCRIPTS=1 ./agx update post > /dev/null
	[ -e "$T/ran" ]
}

@test "agx: git rows fetch the ref, run setup once and run the command with AGX_DIR" {
	run env AGX_YES=1 ./agx run gt 1 2
	[ "$output" = "git-tool 1 2 in $AGX_HOME/gt" ]
	[ -f "$AGX_HOME/gt/setup.txt" ]
}

@test "agx: list, search, info and mcp" {
	AGX_YES=1 ./agx run hello > /dev/null
	run ./agx list
	[[ "$output" == *$'hello\tnpm\tcached'* ]]
	[[ "$output" == *$'context7\tnpm\t-'* ]]
	run ./agx search npm
	[[ "$output" == *context7* && "$output" != *$'fetch\tpip'* ]]
	run ./agx mcp hello
	[[ "$output" == "claude mcp add hello -- "*"/agx run hello" ]]
}

@test "agx: pip row installs into a venv (fake uv) and runs" {
	mkdir "$T/fakebin"
	cat > "$T/fakebin/uv" << 'U'
#!/bin/sh
case $1 in venv) shift; [ "$1" = -q ] && shift; mkdir -p "$1/bin"; : > "$1/bin/python" ;;
pip) printf '#!/bin/sh\necho pip-tool "$@"\n' > "$FAKE_VENV/bin/faketool"; chmod +x "$FAKE_VENV/bin/faketool" ;; esac
U
	chmod +x "$T/fakebin/uv"
	./agx add ft pip faketool 2.0 > /dev/null
	run env PATH="$T/fakebin:$PATH" FAKE_VENV="$AGX_HOME/ft/venv" AGX_YES=1 ./agx ft q
	[ "$output" = "pip-tool q" ]
}

@test "agx: url row refuses a wrong sha256 and runs with the right one" {
	printf '#!/bin/sh\necho url-tool\n' > "$T/u.sh"
	sum=$(sha256sum "$T/u.sh" | cut -d' ' -f1)
	./agx add bad url "file://$T/u.sh" 0000 u.sh > /dev/null
	./agx add good url "file://$T/u.sh" "$sum" u.sh > /dev/null
	run env AGX_YES=1 ./agx run bad
	[ "$status" -ne 0 ]
	[[ "$output" == *"does not match"* ]]
	run env AGX_YES=1 ./agx run good
	[ "$output" = "url-tool" ]
}

@test "agx: clean moves the cache to the trash, remove drops only the user row" {
	AGX_YES=1 ./agx run hello > /dev/null
	run ./agx clean hello
	[ ! -e "$AGX_HOME/hello" ]
	compgen -G "$XDG_DATA_HOME/Trash/files/agx-hello*" > /dev/null
	./agx remove hello > /dev/null
	run ./agx info hello
	[[ "$output" == *"no row"* ]]
}

@test "agx: unknown name is a clear error" {
	run ./agx nonsense-name < /dev/null
	[ "$status" -ne 0 ]
	[[ "$output" == *"no registry row"* ]]
}

skillrepo() {
	mkdir -p "$T/skrepo/skills/foo/scripts" "$T/skrepo/skills/foo/refs"
	printf -- '---\nname: foo\ndescription: test skill\n---\nbody\n' > "$T/skrepo/skills/foo/SKILL.md"
	printf 'echo hi\n' > "$T/skrepo/skills/foo/scripts/setup.sh"
	git -C "$T/skrepo" init -q && git -C "$T/skrepo" add . && git -C "$T/skrepo" -c user.name=t -c user.email=t@t commit -qm skill
	export AGX_SKILLS_DIR=$T/skills
	./agx add foo skill "$T/skrepo" HEAD skills/foo "a skill" 'bash scripts/setup.sh' > /dev/null
}

@test "agx skill: install fetches the pinned checkout and links it, never runs the setup" {
	skillrepo
	run env AGX_YES=1 ./agx skill install foo
	[ "$status" -eq 0 ]
	[ -f "$AGX_SKILLS_DIR/foo/SKILL.md" ]
	[ -L "$AGX_SKILLS_DIR/foo" ]
	[[ "$output" == *"one-time setup, not run for you"* ]]
	run ./agx skill list
	[[ "$output" == foo* ]]
	run env AGX_YES=1 ./agx skill install foo
	[[ "$output" == *"already linked"* ]]
}

@test "agx skill: an existing folder is never overwritten, a wrong subfolder is refused" {
	skillrepo
	mkdir -p "$AGX_SKILLS_DIR/foo"; echo mine > "$AGX_SKILLS_DIR/foo/SKILL.md"
	run env AGX_YES=1 ./agx skill install foo
	[ "$status" -ne 0 ]
	[[ "$output" == *"exists and is not agx's link"* ]]
	[ "$(cat "$AGX_SKILLS_DIR/foo/SKILL.md")" = mine ]
	./agx add bad skill "$T/skrepo" HEAD skills/nothere > /dev/null
	run env AGX_YES=1 ./agx skill install bad
	[[ "$output" == *"SKILL.md is not in"* ]]
	./agx add esc skill "$T/skrepo" HEAD ../../etc > /dev/null
	run env AGX_YES=1 ./agx skill install esc
	[[ "$output" == *"must stay inside the repo"* ]]
}

@test "agx skill: remove moves only agx's own link to the trash; run refuses a skill" {
	skillrepo
	AGX_YES=1 ./agx skill install foo > /dev/null
	run ./agx foo
	[[ "$output" == *"is a skill, not a program"* ]]
	run ./agx skill remove foo
	[ "$status" -eq 0 ]
	[ ! -e "$AGX_SKILLS_DIR/foo" ]
	compgen -G "$XDG_DATA_HOME/Trash/files/agx-skill-foo*" > /dev/null
	[ -d "$AGX_HOME/foo/src/skills/foo" ]
	run ./agx skill remove foo
	[ "$status" -ne 0 ]
}

@test "agx skill: the built-in reanimate row is pinned to a commit" {
	run ./agx info reanimate
	[[ "$output" == *"kind"*"skill"* ]]
	[[ "$output" =~ ref[[:space:]]+[0-9a-f]{40} ]]
}

@test "agx: every built-in skill row is pinned to a full commit and names a folder" {
	run ./agx list
	n=0
	while IFS=$'\t' read -r name kind _; do
		[ "$kind" = skill ] || continue
		n=$((n + 1))
		info=$(./agx info "$name")
		[[ $info =~ ref[[:space:]]+[0-9a-f]{40} ]] || { echo "unpinned: $name"; false; }
		[[ $info =~ cmd[[:space:]]+skills/ ]] || { echo "no folder: $name"; false; }
	done <<< "$output"
	[ "$n" -ge 8 ]
}
