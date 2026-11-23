#!/usr/bin/env bats
# godot: no Godot needed. A fake godot on PATH logs its arguments and behaves by what the script file says:
# FAILME in a script = exit 1, PARSEERR = prints "SCRIPT ERROR" and still exits 0.

setup() {
	cd "$BATS_TEST_DIRNAME/.." || return
	T=$BATS_TEST_TMPDIR
	G=$PWD/godot
	export HOME=$T/home
	mkdir -p "$HOME" "$T/fake" "$T/work"
	unset GODOT_BIN GODOT_BENCH_RUNS GODOT_FORCE GODOT_MCP_BRIDGE
	cd "$T/work" || return
}

teardown() {
	[ -n "${EDPID:-}" ] && kill "$EDPID" 2> /dev/null
	return 0
}

fakes() {
	cat > "$T/fake/godot" << EOF
#!/bin/sh
echo "\$@" >> "$T/godot.log"
for a in "\$@"; do [ "\$a" = --version ] && { echo 4.7.2.stable.official.abc; exit 0; }; done
path=.; script=''
while [ \$# -gt 0 ]; do
	case \$1 in
	--path) path=\$2; shift ;;
	--script | -s) script=\$2; shift ;;
	--import) mkdir -p "\$path/.godot" ;;
	--export-release | --export-debug) out=\$3; echo EXPORT > "\$out"; exit \${EXPORT_RC:-0} ;;
	esac
	shift
done
if [ -n "\$script" ]; then
	f=\$path/\${script#res://}
	[ -f "\$f" ] || exit 1
	grep -q FAILME "\$f" && { echo boom; exit 1; }
	grep -q PARSEERR "\$f" && { echo "SCRIPT ERROR: Parse Error: x"; exit 0; }
	echo "ran \$script"
fi
exit \${GODOT_RC:-0}
EOF
	chmod +x "$T/fake/godot"
	export PATH=$T/fake:$PATH
}

# bare: only the basics, no godot anywhere
bare() {
	mkdir -p "$T/bare"
	local c p
	for c in bash env sed grep awk find sort tr head tail wc dirname basename cat mkdir mktemp chmod rm stat readlink date paste ln ls cut; do
		p=$(command -v "$c") && ln -sf "$p" "$T/bare/$c"
	done
	export PATH=$T/bare
}

proj() {
	"$G" new demo > /dev/null
	cd demo || return
}

lastlog() { tail -n 1 "$T/godot.log"; }

@test "godot: --help prints the header" {
	run "$G" --help
	[ "$status" -eq 0 ]
	[[ $output == *"godot new NAME"* ]]
	[[ $output == *"Exit status"* ]]
}

@test "godot new: scaffolds the project and the entry scripts" {
	run "$G" new demo
	[ "$status" -eq 0 ]
	for f in project.godot scenes/main.tscn scripts/main.gd tests/test_main.gd tests/bench_main.gd run test check bench godot.conf .gitignore README.md; do
		[ -f "demo/$f" ] || { echo "missing $f"; return 1; }
	done
	[ -x demo/run ] && [ -x demo/test ]
	grep -q 'config/name="demo"' demo/project.godot
	[ "$(cat demo/test)" = "$(printf '#!/bin/sh\nexec godot test')" ]
}

@test "godot new: takes the feature version from the godot found" {
	fakes
	"$G" new demo > /dev/null
	grep -q 'PackedStringArray("4.7")' demo/project.godot
}

@test "godot new: idempotent, never overwrites; bad names are exit 2" {
	"$G" new demo > /dev/null
	echo mine > demo/scripts/main.gd
	run "$G" new demo
	[ "$status" -eq 0 ]
	[[ $output == *"kept scripts/main.gd"* ]]
	[ "$(cat demo/scripts/main.gd)" = mine ]
	run "$G" new 'bad name'
	[ "$status" -eq 2 ]
	run "$G" new
	[ "$status" -eq 2 ]
	run "$G" new -x
	[ "$status" -eq 2 ]
}

@test "godot: a project command outside a project is exit 3" {
	fakes
	run "$G" check
	[ "$status" -eq 3 ]
	[[ $output == *"no project.godot"* ]]
}

@test "godot: no binary says what was looked at, exit 3, installs nothing" {
	bare
	mkdir p && : > p/project.godot && cd p
	run "$G" run
	[ "$status" -eq 3 ]
	[[ $output == *"no godot binary"* ]]
	run "$G" doctor
	[ "$status" -eq 0 ]
	[[ $output == *"godot: none found"* ]]
}

@test "godot run: --path root, optional scene, args after --" {
	fakes
	proj
	run "$G" run
	[ "$status" -eq 0 ]
	[ "$(lastlog)" = "--path $T/work/demo" ]
	run "$G" run scenes/main.tscn -- --foo bar
	[ "$(lastlog)" = "--path $T/work/demo res://scenes/main.tscn --foo bar" ]
	cd scenes
	run "$G" run
	[ "$(lastlog)" = "--path $T/work/demo" ]
}

@test "godot editor: --editor on the project" {
	fakes
	proj
	run "$G" editor
	[ "$(lastlog)" = "--path $T/work/demo --editor" ]
}

@test "godot import: headless import, a failure is exit 1" {
	fakes
	proj
	run "$G" import
	[ "$status" -eq 0 ]
	[ "$(lastlog)" = "--headless --path $T/work/demo --import" ]
	GODOT_RC=1 run "$G" import
	[ "$status" -eq 1 ]
}

@test "godot check: every script parsed, then the project loads" {
	fakes
	proj
	run "$G" check
	[ "$status" -eq 0 ]
	[[ $output == *"scripts: 3 ok"* ]]
	[[ $output == *"project loads"* ]]
	grep -q -e '--check-only --script res://scripts/main.gd' "$T/godot.log"
}

@test "godot check: a script that prints SCRIPT ERROR is named, exit 1" {
	fakes
	proj
	echo PARSEERR >> scripts/main.gd
	run "$G" check
	[ "$status" -eq 1 ]
	[[ $output == *"scripts/main.gd"* ]]
	[[ $output == *"Parse Error"* ]]
}

@test "godot test: runs tests/test_*.gd one by one and counts" {
	fakes
	proj
	cp tests/test_main.gd tests/test_two.gd
	run "$G" test
	[ "$status" -eq 0 ]
	[[ $output == *"ok    tests/test_main.gd"* ]]
	[[ $output == *"2 passed, 0 failed"* ]]
	[[ $output != *"bench_main"* ]]
}

@test "godot test: a failing test or a parse error fails the run and shows the output" {
	fakes
	proj
	cp tests/test_main.gd tests/test_bad.gd; echo FAILME >> tests/test_bad.gd
	cp tests/test_main.gd tests/test_parse.gd; echo PARSEERR >> tests/test_parse.gd
	run "$G" test
	[ "$status" -eq 1 ]
	[[ $output == *"FAIL  tests/test_bad.gd"* ]]
	[[ $output == *"boom"* ]]
	[[ $output == *"FAIL  tests/test_parse.gd"* ]]
	[[ $output == *"1 passed, 2 failed"* ]]
}

@test "godot test PATTERN filters; no match or no tests/ is exit 3" {
	fakes
	proj
	cp tests/test_main.gd tests/test_two.gd
	run "$G" test two
	[ "$status" -eq 0 ]
	[[ $output == *"1 passed"* ]]
	run "$G" test nothing
	[ "$status" -eq 3 ]
	rm -r tests
	run "$G" test
	[ "$status" -eq 3 ]
}

@test "godot test: GUT in addons/ is used instead" {
	fakes
	proj
	mkdir -p addons/gut
	echo "# gut" > addons/gut/gut_cmdln.gd
	run "$G" test
	[ "$status" -eq 0 ]
	[[ $output == *"GUT found"* ]]
	[[ $(lastlog) == *"gut_cmdln.gd"* ]]
}

@test "godot bench: runs each bench file GODOT_BENCH_RUNS times, reports best" {
	fakes
	proj
	GODOT_BENCH_RUNS=2 run "$G" bench
	[ "$status" -eq 0 ]
	[[ $output == *"bench tests/bench_main.gd  best "* ]]
	[[ $output == *"of 2"* ]]
	[ "$(grep -c bench_main "$T/godot.log")" -eq 2 ]
	GODOT_BENCH_RUNS=0 run "$G" bench
	[ "$status" -eq 2 ]
}

@test "godot bench: runs from godot.conf; a failing bench is exit 1" {
	fakes
	proj
	echo 'GODOT_BENCH_RUNS=1' > godot.conf
	run "$G" bench
	[ "$status" -eq 0 ]
	[[ $output == *"of 1"* ]]
	echo FAILME >> tests/bench_main.gd
	run "$G" bench
	[ "$status" -eq 1 ]
	[[ $output == *"FAIL  tests/bench_main.gd"* ]]
}

@test "godot export: needs presets, checks the name, runs --export-release into build/" {
	fakes
	proj
	run "$G" export linux
	[ "$status" -eq 3 ]
	[[ $output == *"no export_presets.cfg"* ]]
	printf '[preset.0]\n\nname="linux"\nplatform="Linux"\n' > export_presets.cfg
	run "$G" export nope
	[ "$status" -eq 3 ]
	[[ $output == *"linux"* ]]
	run "$G" export linux
	[ "$status" -eq 0 ]
	[ "$(lastlog)" = "--headless --path $T/work/demo --export-release linux build/linux" ]
	[ -f build/linux ]
	run "$G" export linux out/game.x86_64 --debug
	[ "$(lastlog)" = "--headless --path $T/work/demo --export-debug linux out/game.x86_64" ]
	EXPORT_RC=1 run "$G" export linux
	[ "$status" -eq 1 ]
	run "$G" export
	[ "$status" -eq 2 ]
	run "$G" export linux --what
	[ "$status" -eq 2 ]
}

@test "godot mcp: status lists the ports, bridge needs the file and node" {
	run "$G" mcp status
	[ "$status" -eq 0 ]
	[[ $output == *"9090 "* ]]
	[[ $output == *"9094 "* ]]
	proj
	run "$G" mcp bridge
	[ "$status" -eq 3 ]
	run "$G" mcp frob
	[ "$status" -eq 2 ]
}

@test "godot mcp bridge: runs the project's bridge with node" {
	proj
	mkdir -p "$T/fake"
	printf '#!/bin/sh\necho "node $@" > "%s/node.log"\n' "$T" > "$T/fake/node"
	chmod +x "$T/fake/node"
	export PATH=$T/fake:$PATH
	echo '// bridge' > godot-mcp-bridge.mjs
	run "$G" mcp bridge
	[ "$status" -eq 0 ]
	[ "$(cat "$T/node.log")" = "node $T/work/demo/godot-mcp-bridge.mjs" ]
}

@test "godot: an open editor on the project stops headless commands (exit 3); GODOT_FORCE overrides" {
	fakes
	proj
	bash -c "exec -a 'godot --path $PWD --editor' sleep 30" &
	EDPID=$!
	sleep 0.3
	run "$G" test
	[ "$status" -eq 3 ]
	[[ $output == *"editor has"* ]]
	run "$G" import
	[ "$status" -eq 3 ]
	GODOT_FORCE=1 run "$G" test
	[ "$status" -eq 0 ]
	run "$G" doctor
	[[ $output == *"editor: open on this project"* ]]
}

@test "godot iso: runs the command in a throwaway copy, real .godot untouched" {
	fakes
	proj
	bash -c "exec -a 'godot --path $PWD --editor' sleep 30" &
	EDPID=$!
	sleep 0.3
	run "$G" iso import
	[ "$status" -eq 0 ]
	[ ! -e .godot ]
	[[ $output == *"copy in "* ]]
	tmp=$(printf '%s\n' "$output" | sed -n 's/^godot: copy in //p')
	[ ! -e "$tmp" ]
	run "$G" iso test
	[ "$status" -eq 0 ]
	[[ $output == *"1 passed"* ]]
}

@test "godot iso --keep keeps the copy; iso of a non-project command is exit 2" {
	fakes
	proj
	run "$G" iso --keep check
	[ "$status" -eq 0 ]
	tmp=$(printf '%s\n' "$output" | sed -n 's/^godot: kept //p')
	[ -d "$tmp" ]
	[ -L "$tmp/project.godot" ]
	rm -rf "$tmp"
	run "$G" iso mcp
	[ "$status" -eq 2 ]
	run "$G" iso
	[ "$status" -eq 2 ]
}

@test "godot: anything else goes to the real godot unchanged; raw too" {
	fakes
	run "$G" --version
	[ "$status" -eq 0 ]
	[[ $output == 4.7.2* ]]
	run "$G" --headless -s x.gd --quit
	[ "$(lastlog)" = "--headless -s x.gd --quit" ]
	run "$G" raw --help
	[ "$(lastlog)" = "--help" ]
}

@test "godot: GODOT_BIN in godot.conf wins and a godot that is this script is skipped" {
	mkdir -p "$T/self" "$T/other"
	ln -s "$G" "$T/self/godot"
	printf '#!/bin/sh\necho other "$@"\n' > "$T/other/godot"
	chmod +x "$T/other/godot"
	export PATH=$T/self:$T/other:$PATH
	run "$T/self/godot" --version
	[ "$status" -eq 0 ]
	[ "$output" = "other --version" ]
	mkdir p && : > p/project.godot && cd p
	printf '#!/bin/sh\necho conf "$@"\n' > "$T/c"
	chmod +x "$T/c"
	echo "GODOT_BIN=$T/c" > godot.conf
	run "$T/self/godot" run
	[[ $output == "conf --path "* ]]
}

@test "godot doctor: version, project, mcp" {
	fakes
	proj
	run "$G" doctor
	[ "$status" -eq 0 ]
	[[ $output == *"4.7.2"* ]]
	[[ $output == *"project: "*"(demo)"* ]]
	[[ $output == *"mcp: "* ]]
}

@test "godot: shellcheck clean" {
	command -v shellcheck > /dev/null || skip "shellcheck missing"
	cd "$BATS_TEST_DIRNAME/.." || return
	run shellcheck -S warning godot
	[ "$status" -eq 0 ]
}
