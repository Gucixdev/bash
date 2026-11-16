#!/usr/bin/env bats
# templates/references with throwaway local git repos as the "upstreams" (no network).

setup() {
	cd "$BATS_TEST_TMPDIR" || return
	for n in alpha beta; do
		git init -q "up-$n" && git -C "up-$n" -c user.name=t -c user.email=t@t commit -q --allow-empty -m one
		echo "$n" > "up-$n/file" && git -C "up-$n" add file && git -C "up-$n" -c user.name=t -c user.email=t@t commit -q -m two
	done
	git -C up-beta tag v1
	mkdir proj && cd proj && git init -q
	cp "$BATS_TEST_DIRNAME/../templates/download_references" ./download_references
	printf '# studied\nalpha file://%s/up-alpha\nbeta  file://%s/up-beta v1\n' "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" > references.list
	export REFERENCES_TRASH=$BATS_TEST_TMPDIR/trash
}

@test "get fetches every project shallowly and ignores the folder in git" {
	run ./download_references
	[ "$status" -eq 0 ]
	[ -f references/alpha/file ] && [ -f references/beta/file ]
	[ "$(git -C references/alpha rev-list --count HEAD)" -eq 1 ]
	grep -qxF '/references/' .gitignore
	git check-ignore -q references/alpha/file
}

@test "get twice does not fetch again" {
	./download_references > /dev/null
	run ./download_references
	[ "$status" -eq 0 ]
	[[ $output == *"have     alpha"* ]]
}

@test "a REF selects the tag" {
	./download_references > /dev/null
	[ "$(git -C references/beta describe --tags)" = v1 ]
}

@test "list shows here and missing" {
	run ./download_references list
	[[ $output == *"alpha"*"missing"* ]]
	./download_references > /dev/null
	run ./download_references list
	[[ $output == *"alpha"*"here"* ]]
}

@test "update pulls new upstream commits" {
	./download_references > /dev/null
	git -C "$BATS_TEST_TMPDIR/up-alpha" -c user.name=t -c user.email=t@t commit -q --allow-empty -m three
	run ./download_references update
	[[ $output == *"updated  alpha"* ]]
}

@test "a broken source fails that project only, exit 1" {
	printf 'ghost file:///nonexistent/x\n' >> references.list
	run ./download_references
	[ "$status" -eq 1 ]
	[[ $output == *"FAILED   ghost"* ]]
	[ -f references/alpha/file ]
}

@test "clean moves to the trash and a new get restores it" {
	./download_references > /dev/null
	run ./download_references clean alpha
	[ "$status" -eq 0 ]
	[ ! -e references/alpha ] && [ -e references/beta ]
	compgen -G "$REFERENCES_TRASH/references-alpha-*" > /dev/null
	./download_references clean > /dev/null
	[ ! -e references ]
	run ./download_references
	[ -f references/alpha/file ]
}

@test "bad list lines and missing list are usage errors" {
	printf 'ba/d file:///x\n' > references.list
	run ./download_references
	[ "$status" -eq 2 ]
	mv references.list gone
	run ./download_references
	[ "$status" -eq 2 ]
}

@test "unknown command prints the help, exit 2" {
	run ./download_references frobnicate
	[ "$status" -eq 2 ]
	[[ $output == *"download_references list"* ]]
}

@test "the last line of references.list counts without a final newline" {
	printf 'alpha file://%s/up-alpha\nbeta file://%s/up-beta v1' "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" > references.list
	run ./download_references
	[ "$status" -eq 0 ]; [ -f references/beta/file ]
}

@test "a .gitignore without a final newline keeps its last line apart from /references/" {
	printf 'node_modules' > .gitignore
	run ./download_references
	[ "$status" -eq 0 ]
	grep -qxF node_modules .gitignore && grep -qxF '/references/' .gitignore
}

@test "a references/NAME.part left by an interrupted run does not make every later clone fail" {
	mkdir -p references/alpha.part/junk
	run ./download_references
	[ "$status" -eq 0 ]; [ -f references/alpha/file ]
}

@test "names . and .. are refused in the list and by clean" {
	printf '.. file://%s/up-alpha\n' "$BATS_TEST_TMPDIR" > references.list
	run ./download_references
	[ "$status" -eq 2 ]
	run ./download_references clean ..
	[ "$status" -eq 2 ]
	run ./download_references clean .
	[ "$status" -eq 2 ]
}
