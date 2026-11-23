#!/usr/bin/env bats
# todoq against a fake `openapi` (records what it was asked, answers from a file) and two real local git repos.

setup() {
	cd "$BATS_TEST_DIRNAME/.." || return
	T=$BATS_TEST_TMPDIR
	export HOME=$T/home XDG_CACHE_HOME=$T/cache TODOQ_ASK=$T/openapi
	mkdir -p "$HOME" "$T/base/notes" "$T/base/parser/src" "$T/base/unused"
	git -C "$T/base/parser" init -q
	printf 'int tokenize(void);\n/* api_key = sk-abcdefghijklmnopqrstuv12345 */\n' > "$T/base/parser/src/lexer.c"
	printf '# parser\nA small parser.\n' > "$T/base/parser/README.md"
	git -C "$T/base/parser" add . && git -C "$T/base/parser" -c user.name=t -c user.email=t@t commit -qm "first parser commit"
	git -C "$T/base/notes" init -q
	cat > "$T/base/notes/todo.md" <<'EOT'
# todo

1. parser: tokenize should handle utf-8
2. parser lexer rewrite -> zrobione 2026-11-15
- [ ] write the changelog (no repo named)
3. fix the thing (blocked: needs a decision)
EOT
	printf '#!/bin/sh\ncat > "%s/prompt.$$"\n[ -f "%s/empty" ] && exit 0\necho "step 1: look at src/lexer.c"\n' "$T" "$T" > "$T/openapi"
	chmod +x "$T/openapi"
}

@test "dry run maps lines to repos, skips headings and status notes, asks nothing" {
	run ./todoq -n "$T/base/notes/todo.md"
	[ "$status" -eq 0 ]
	[[ ${lines[0]} == $'3\tparser\t'* ]]
	[[ ${lines[1]} == $'5\t-\t'* ]]
	[ ${#lines[@]} -eq 2 ]
	[ ! -e "$T/cache/todoq" ]
}

@test "-a keeps the status notes; a generic folder name like unused is never a repo" {
	printf 'fix unused warnings in parser\n' >> "$T/base/notes/todo.md"
	run ./todoq -n -a "$T/base/notes/todo.md"
	[ ${#lines[@]} -eq 5 ]
	[[ $output == *$'\tparser\tfix unused warnings'* ]]
}

@test "the model sees the repo context (files, log, README, grep) and keys in it are masked" {
	run ./todoq -j 1 "$T/base/notes/todo.md"
	[ "$status" -eq 0 ]
	[[ $output == *"## line 3: parser: tokenize should handle utf-8"* && $output == *"step 1: look at src/lexer.c"* ]]
	p=$(grep -l 'tokenize should handle' "$T"/prompt.* | head -1)
	grep -q 'first parser commit' "$p" && grep -q 'README.md (head)' "$p" && grep -q 'lexer.c' "$p"
	grep -q 'not in context' "$p"
	! grep -q 'sk-abcdefghijklmnopqrstuv12345' "$p"
	grep -q 'no repo named in the item' "$(grep -l 'write the changelog' "$T"/prompt.* | head -1)"
}

@test "saved answers are reused; -f asks again" {
	./todoq -j 1 "$T/base/notes/todo.md" > /dev/null
	n=$(ls "$T"/prompt.* | wc -l)
	./todoq -j 1 "$T/base/notes/todo.md" > /dev/null
	[ "$(ls "$T"/prompt.* | wc -l)" -eq "$n" ]
	./todoq -f -j 1 "$T/base/notes/todo.md" > /dev/null
	[ "$(ls "$T"/prompt.* | wc -l)" -eq $((n * 2)) ]
}

@test "an empty answer is not saved, the run exits 1 and the next run retries it" {
	touch "$T/empty"
	run ./todoq -j 2 "$T/base/notes/todo.md"
	[ "$status" -eq 1 ]
	[[ $output == *"no answer"* ]]
	mv "$T/empty" "$T/empty.off"
	run ./todoq -j 2 "$T/base/notes/todo.md"
	[ "$status" -eq 0 ]
	[[ $output == *"step 1"* ]]
}

@test "bad usage: missing file, bad -j, missing openapi" {
	run ./todoq "$T/nope.md"; [ "$status" -eq 2 ]
	run ./todoq -j x "$T/base/notes/todo.md"; [ "$status" -eq 2 ]
	TODOQ_ASK=/nonexistent/openapi run ./todoq "$T/base/notes/todo.md"; [ "$status" -eq 2 ]
}
