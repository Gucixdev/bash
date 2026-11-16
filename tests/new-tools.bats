#!/usr/bin/env bats
# Behavior tests for the tools that don't need a GUI/network/root to
# exercise their real logic - error paths, passthrough, dispatch.

setup() {
	cd "$BATS_TEST_DIRNAME/.."
}

@test "metadata_cleaner: usage error with no args" {
	run ./metadata_cleaner
	[ "$status" -eq 2 ]
}

@test "metadata_cleaner: clean error on missing file" {
	run ./metadata_cleaner /no/such/file
	[ "$status" -eq 1 ]
	[[ "$output" == *"no such file"* ]]
}

@test "metadata_cleaner: strips an image via ImageMagick fallback" {
	tmp=$(mktemp -d)
	convert -size 4x4 xc:red "$tmp/in.png"
	run ./metadata_cleaner "$tmp/in.png"
	[ "$status" -eq 0 ]
	[ -f "$tmp/clean-in.png" ]
	rm -rf "$tmp"
}

@test "nmap: passthrough mode reaches the real nmap" {
	run ./templates/nmap -- --version
	[ "$status" -eq 0 ]
	[[ "$output" == *"Nmap version"* ]]
}

@test "nmap: unknown preset is a clean error, not a crash" {
	run ./templates/nmap nope some-host
	[ "$status" -eq 2 ]
}

@test "logbucket: summary-only run writes no archive" {
	tmp=$(mktemp -d)
	run ./logbucket -n -s "1 hour ago" -o "$tmp"
	[ "$status" -eq 0 ]
	[[ "$output" == *"logcollector summary"* ]]
	[ -z "$(ls -A "$tmp")" ]
	rm -rf "$tmp"
}

@test "logbucket: redacts tokens, passwords and private keys" {
	tmp=$(mktemp -d)
	eval "$(sed -n '/^redact() {/,/^}/p' ./logbucket)"
	redact_ip=0
	out=$(printf '%s\n' \
		'x ghp_abcdefghijklmnopqrstuvwxyz0123456789 y' \
		'db password=hunter2 ok' \
		'-----BEGIN OPENSSH PRIVATE KEY-----' 'AAAAsecret' '-----END OPENSSH PRIVATE KEY-----' \
		'plain line' | redact)
	[[ "$out" != *ghp_abc* ]]
	[[ "$out" != *0123456789* ]]
	[[ "$out" != *hunter2* ]]
	[[ "$out" != *AAAAsecret* ]]
	[[ "$out" == *"plain line"* ]]
	rm -rf "$tmp"
}

@test "manwriter: builds a man page from a script header" {
	tmp=$(mktemp -d)
	printf '%s\n' '#!/bin/sh' '# demo - does a thing' '#' '# usage: demo' '# @flag -v:be loud' '' 'echo hi' > "$tmp/demo"
	run ./manwriter -d "$tmp" "$tmp/demo"
	[ "$status" -eq 0 ]
	grep -q '^.SH NAME' "$tmp/demo.1"
	grep -q 'does a thing' "$tmp/demo.1"
	grep -q 'be loud' "$tmp/demo.1"
	rm -rf "$tmp"
}

@test "sniff: summarizes tcpdump text from stdin" {
	run sh -c "printf '%s\n' \
		'1696953601.1 IP 192.168.1.10.54321 > 142.250.74.46.443: Flags [P.], seq 1:518, ack 1, win 502, length 517' \
		'1696953601.3 IP 192.168.1.10.41234 > 192.168.1.1.53: 12345+ A? example.com. (29)' \
		| ./sniff -"
	[ "$status" -eq 0 ]
	[[ "$output" == *"2 packets"* ]]
	[[ "$output" == *"tcp/https (443)"* ]]
	[[ "$output" == *"example.com."* ]]
}

@test "findfat: lists the biggest file first" {
	tmp=$(mktemp -d)
	dd if=/dev/zero of="$tmp/big" bs=1k count=64 2>/dev/null
	dd if=/dev/zero of="$tmp/small" bs=1k count=1 2>/dev/null
	run ./findfat -file -n 1 "$tmp"
	[ "$status" -eq 0 ]
	[[ "$output" == *"/big"* ]]
	[[ "$output" != *"/small"* ]]
	rm -rf "$tmp"
}

@test "morph: refuses to overwrite and to cross kinds" {
	tmp=$(mktemp -d)
	: > "$tmp/a.png"; : > "$tmp/b.png"
	run ./morph "$tmp/a.png" "$tmp/b.png"
	[ "$status" -eq 1 ]
	[[ "$output" == *"exists"* ]]
	run ./morph "$tmp/a.png" "$tmp/a.mp3"
	[ "$status" -eq 1 ]
	[[ "$output" == *"cannot convert"* ]]
	rm -rf "$tmp"
}

@test "fixmedia: -c reports a healthy image as ok" {
	command -v convert >/dev/null || command -v magick >/dev/null || skip "ImageMagick not installed"
	tmp=$(mktemp -d)
	convert -size 4x4 xc:red "$tmp/a.png" 2>/dev/null || magick -size 4x4 xc:red "$tmp/a.png"
	run ./fixmedia -c "$tmp/a.png"
	[ "$status" -eq 0 ]
	[[ "$output" == ok* ]]
	rm -rf "$tmp"
}

# --- more behaviour of the standalone tools ----------------------------

@test "trash: moves the file and writes a .trashinfo with its original path" {
	tmp=$(mktemp -d)
	echo x > "$tmp/doomed"
	XDG_DATA_HOME="$tmp/data" run ./trash "$tmp/doomed"
	[ "$status" -eq 0 ]
	[ ! -e "$tmp/doomed" ]
	[ -f "$tmp/data/Trash/files/doomed" ]
	grep -q "^Path=$tmp/doomed$" "$tmp/data/Trash/info/doomed.trashinfo"
	rm -rf "$tmp"
}

@test "trash: a second file with the same name does not overwrite the first" {
	tmp=$(mktemp -d)
	mkdir "$tmp/a" "$tmp/b"
	echo one > "$tmp/a/f"; echo two > "$tmp/b/f"
	XDG_DATA_HOME="$tmp/data" ./trash "$tmp/a/f"
	XDG_DATA_HOME="$tmp/data" ./trash "$tmp/b/f"
	[ "$(cat "$tmp/data/Trash/files/f")" = one ]
	[ "$(cat "$tmp/data/Trash/files/f.2")" = two ]
	rm -rf "$tmp"
}

@test "todo: add, list numbered, finish moves the task to done.txt" {
	tmp=$(mktemp -d)
	XDG_DATA_HOME="$tmp" ./todo "write tests" >/dev/null
	XDG_DATA_HOME="$tmp" ./todo "ship it" >/dev/null
	XDG_DATA_HOME="$tmp" run ./todo ls
	[[ "$output" == *"1  "*"write tests"* ]]
	[[ "$output" == *"2  "*"ship it"* ]]
	XDG_DATA_HOME="$tmp" ./todo done 1 >/dev/null
	grep -q 'write tests' "$tmp/todo/done.txt"
	! grep -q 'write tests' "$tmp/todo/todo.txt"
	rm -rf "$tmp"
}

@test "todo: finishing a task that does not exist is an error" {
	tmp=$(mktemp -d)
	XDG_DATA_HOME="$tmp" run ./todo done 9
	[ "$status" -eq 1 ]
	rm -rf "$tmp"
}

@test "logbucket: writes an archive that contains the summary" {
	tmp=$(mktemp -d)
	run ./logbucket -s "10 minutes ago" -o "$tmp"
	[ "$status" -eq 0 ]
	arch=$(ls "$tmp"/logcollector-*.tar.* | head -1)
	[ -f "$arch" ]
	case $arch in
		*.zst) zstd -dc "$arch" | tar -t | grep -q 'SUMMARY.txt' ;;
		*) tar -tzf "$arch" | grep -q 'SUMMARY.txt' ;;
	esac
	rm -rf "$tmp"
}

@test "logbucket: -I masks IPv4 and MAC addresses, without it they stay" {
	eval "$(sed -n '/^redact() {/,/^}/p' ./logbucket)"
	redact_ip=0
	out=$(echo 'link 192.168.1.20 aa:bb:cc:dd:ee:ff' | redact)
	[[ "$out" == *192.168.1.20* ]]
	redact_ip=1
	out=$(echo 'link 192.168.1.20 aa:bb:cc:dd:ee:ff' | redact)
	[[ "$out" != *192.168.1.20* ]]
	[[ "$out" != *aa:bb:cc* ]]
}

@test "logbucket: Authorization headers and URL credentials are redacted" {
	eval "$(sed -n '/^redact() {/,/^}/p' ./logbucket)"
	redact_ip=0
	out=$(printf '%s\n' 'curl -H "Authorization: Bearer abcdef1234567890" https://bob:s3cret@example.com/x' | redact)
	[[ "$out" != *abcdef1234567890* ]]
	[[ "$out" != *s3cret* ]]
	[[ "$out" == *example.com* ]]
}

@test "logbucket: redaction works under mawk (the default awk on Debian/Ubuntu)" {
	command -v mawk >/dev/null || skip "mawk not installed"
	tmp=$(mktemp -d)
	ln -s "$(command -v mawk)" "$tmp/awk"
	PATH="$tmp:$PATH"
	hash -r
	eval "$(sed -n '/^redact() {/,/^}/p' ./logbucket)"
	redact_ip=1
	out=$(printf '%s\n' \
		'x ghp_abcdefghijklmnopqrstuvwxyz0123456789 y' \
		'link 192.168.1.20 aa:bb:cc:dd:ee:ff' \
		'curl -H "Authorization: Bearer abcdef1234567890" https://bob:s3cret@example.com/x' \
		'plain line' | redact)
	rm -rf "$tmp"
	[[ "$out" != *0123456789* ]]
	[[ "$out" != *192.168.1.20* ]]
	[[ "$out" != *aa:bb:cc* ]]
	[[ "$out" != *s3cret* ]]
	[[ "$out" == *"plain line"* ]]
}

@test "nmap: each preset maps to the right real flags" {
	tmp=$(mktemp -d)
	printf '#!/bin/sh\necho "$@"\n' > "$tmp/nmap"
	chmod +x "$tmp/nmap"
	PATH="$tmp:$PATH" run ./templates/nmap quick host
	[ "$output" = "-T4 -F host" ]
	PATH="$tmp:$PATH" run ./templates/nmap full host
	[ "$output" = "-p- host" ]
	PATH="$tmp:$PATH" run ./templates/nmap ping 10.0.0.0/24
	[ "$output" = "-sn 10.0.0.0/24" ]
	PATH="$tmp:$PATH" run ./templates/nmap service host
	[ "$output" = "-sV host" ]
	rm -rf "$tmp"
}

@test "nmap: does not call itself when it is the first nmap on PATH" {
	tmp=$(mktemp -d)
	mkdir "$tmp/bin" "$tmp/real"
	ln -s "$PWD/templates/nmap" "$tmp/bin/nmap"
	printf '#!/bin/sh\necho real "$@"\n' > "$tmp/real/nmap"
	chmod +x "$tmp/real/nmap"
	PATH="$tmp/bin:$tmp/real:$PATH" run nmap -- -V
	[ "$status" -eq 0 ]
	[ "$output" = "real -V" ]
	rm -rf "$tmp"
}

@test "screenshot: -c puts the image on the clipboard and writes no file" {
	tmp=$(mktemp -d)
	mkdir "$tmp/bin" "$tmp/pics"
	printf '#!/bin/sh\nfor a; do o=$a; done\nprintf PNGDATA > "$o"\n' > "$tmp/bin/grim"
	printf '#!/bin/sh\ncat > "%s/clip"\n' "$tmp" > "$tmp/bin/wl-copy"
	chmod +x "$tmp/bin/grim" "$tmp/bin/wl-copy"
	PATH="$tmp/bin:$PATH" WAYLAND_DISPLAY=w SCREENSHOT_DIR="$tmp/pics" SCREENSHOT_NOTIFY=0 run ./screenshot -c full
	[ "$status" -eq 0 ]
	[ "$(cat "$tmp/clip")" = PNGDATA ]
	[ -z "$(ls -A "$tmp/pics")" ]
	rm -rf "$tmp"
}

@test "screenshot: an unknown mode is an error that lists the valid ones" {
	run ./screenshot nonsense
	[ "$status" -ne 0 ]
	[[ "$output" == *"unknown mode"* ]]
}

@test "findfat: -dir lists directories only, biggest first" {
	tmp=$(mktemp -d)
	mkdir "$tmp/big" "$tmp/small"
	dd if=/dev/zero of="$tmp/big/f" bs=1k count=128 2>/dev/null
	dd if=/dev/zero of="$tmp/small/f" bs=1k count=4 2>/dev/null
	run ./findfat -dir -n 2 "$tmp"
	[ "$status" -eq 0 ]
	[[ "${lines[0]}" == *"/big"* ]]
	[[ "$output" != *"files:"* ]]
	rm -rf "$tmp"
}

@test "findfat: a path that is not a directory is an error" {
	run ./findfat /no/such/dir
	[ "$status" -eq 1 ]
}

@test "morph: converts an image to another format" {
	command -v magick >/dev/null || command -v convert >/dev/null || skip "ImageMagick not installed"
	tmp=$(mktemp -d)
	convert -size 8x8 xc:blue "$tmp/a.png" 2>/dev/null || magick -size 8x8 xc:blue "$tmp/a.png"
	run ./morph "$tmp/a.png" "$tmp/a.jpg"
	[ "$status" -eq 0 ]
	[ -s "$tmp/a.jpg" ]
	run ./morph -f "$tmp/a.png" "$tmp/a.jpg"
	[ "$status" -eq 0 ]
	rm -rf "$tmp"
}

@test "morph: unknown formats and missing input are clean errors" {
	run ./morph /no/such.png out.jpg
	[ "$status" -eq 1 ]
	tmp=$(mktemp -d)
	: > "$tmp/a.xyz"
	run ./morph "$tmp/a.xyz" "$tmp/b.png"
	[ "$status" -eq 1 ]
	[[ "$output" == *"don't know the format"* ]]
	rm -rf "$tmp"
}

@test "fixmedia: -c flags a truncated image as broken, repair produces a readable copy" {
	command -v magick >/dev/null || skip "ImageMagick 7 (magick) not installed"
	tmp=$(mktemp -d)
	magick -size 200x200 plasma:fractal "$tmp/p.jpg" 2>/dev/null
	sz=$(stat -c %s "$tmp/p.jpg")
	head -c $((sz * 7 / 10)) "$tmp/p.jpg" > "$tmp/cut.jpg"
	run ./fixmedia -c "$tmp/cut.jpg"
	[ "$status" -eq 1 ]
	[[ "$output" == problem*decode* ]]
	run ./fixmedia "$tmp/cut.jpg"
	[ "$status" -eq 0 ]
	[ -s "$tmp/fixed-cut.jpg" ]
	[ -s "$tmp/cut.jpg" ]
	run ./fixmedia -c "$tmp/fixed-cut.jpg"
	[ "$status" -eq 0 ]
	rm -rf "$tmp"
}

@test "manwriter: new writes a skeleton page with the given flags" {
	tmp=$(mktemp -d)
	cd "$tmp"
	run "$BATS_TEST_DIRNAME/../manwriter" new demo 1 "does a thing" "-v:be loud"
	[ "$status" -eq 0 ]
	grep -q 'does a thing' demo.1
	grep -q 'be loud' demo.1
	cd "$BATS_TEST_DIRNAME/.."
	rm -rf "$tmp"
}

@test "cleaner: answering no at the prompt removes nothing and exits 0" {
	command -v pacman >/dev/null || command -v apt-get >/dev/null || skip "no supported package manager"
	run sh -c "echo n | ./cleaner"
	[ "$status" -eq 0 ]
	[[ "$output" == *"==="* ]]
}

@test "skilltree: priorities, parts, requirements, who-requires, bad folder" {
	tmp=$(mktemp -d)
	mkdir -p "$tmp/a/references" "$tmp/grp/b"
	printf -- '---\nname: a\ndescription: "does a"\nmetadata:\n  priority: "0"\n  tags: "#x #y"\n---\n' > "$tmp/a/SKILL.md"
	: > "$tmp/a/references/part.md"
	printf -- '---\nname: b\ndescription: does b\nmetadata:\n  priority: "2"\n  requires: "skill:a ?skill:zzz"\n---\n' > "$tmp/grp/b/SKILL.md"
	run ./skilltree "$tmp"
	[ "$status" -eq 0 ]
	[[ "$output" == *"priority 0"* && "$output" == *"- part"* && "$output" == *"requires: a ?zzz"* ]]
	[[ "$output" == *"2 skills"* ]]
	run ./skilltree -w a "$tmp"
	[[ "$output" == *"b (p2)"* ]]
	run ./skilltree -t y "$tmp"
	[[ "$output" == *"1 skills"* ]]
	run ./skilltree "$tmp/nope"
	[ "$status" -eq 2 ]
	rm -rf "$tmp"
}

@test "claude_maintain: reports a broken link and index drift, -f trashes only the link" {
	tmp=$(mktemp -d)
	export XDG_DATA_HOME="$tmp/share"
	mkdir -p "$tmp/skills/ok" "$tmp/projects/p/memory"
	printf -- '---\nname: ok\ndescription: d\n---\n' > "$tmp/skills/ok/SKILL.md"
	ln -s "$tmp/nowhere" "$tmp/skills/dead"
	printf '# i\n- [x](gone.md) hook\n' > "$tmp/projects/p/memory/MEMORY.md"
	printf 'no header\n' > "$tmp/projects/p/memory/loose.md"
	run ./claude_maintain "$tmp"
	[ "$status" -eq 1 ]
	[[ "$output" == *"broken link: dead"* && "$output" == *"missing file: gone.md"* && "$output" == *"not in the index: loose.md"* ]]
	[ -L "$tmp/skills/dead" ]
	run ./claude_maintain -f "$tmp"
	[ ! -L "$tmp/skills/dead" ]
	[ -f "$tmp/projects/p/memory/loose.md" ]
	rm -rf "$tmp"
}

# --- audit round 2 -------------------------------------------------------

@test "trash: Path in the .trashinfo is percent-encoded, a newline in the name cannot break it" {
	d=$BATS_TEST_TMPDIR; mkdir -p "$d/w"
	: > "$d/w/$(printf 'a\nb c%%')"
	XDG_DATA_HOME="$d/data" run ./trash "$d/w/$(printf 'a\nb c%%')"
	[ "$status" -eq 0 ]
	for info in "$d"/data/Trash/info/*; do :; done
	[ "$(wc -l < "$info")" -eq 3 ]
	grep -q '^Path=.*/w/a%0Ab%20c%25$' "$info"
}

@test "trash: a failed move is an error, says so, and leaves no orphan .trashinfo" {
	d=$BATS_TEST_TMPDIR; mkdir -p "$d/w"
	XDG_DATA_HOME="$d/data" run ./trash "$d/w/.."
	[ "$status" -eq 1 ]
	[[ "$output" != *"trashed:"* ]]
	[ -z "$(ls -A "$d/data/Trash/info")" ]
	XDG_DATA_HOME="$d/data" run ./trash "$d/w/nope"
	[ "$status" -eq 1 ]
}

@test "trash: -- ends options and a leading-dash name works" {
	d=$BATS_TEST_TMPDIR; mkdir -p "$d/w"; cd "$d/w"
	: > ./-x
	XDG_DATA_HOME="$d/data" run "$BATS_TEST_DIRNAME/../trash" -- -x
	[ "$status" -eq 0 ]
	[ -f "$d/data/Trash/files/-x" ]
}

@test "todo: 'done' without a number is a usage error, not a task called done" {
	XDG_DATA_HOME="$BATS_TEST_TMPDIR" run ./todo done
	[ "$status" -eq 1 ]
	! grep -q . "$BATS_TEST_TMPDIR/todo/todo.txt"
}

@test "todo: done takes exactly one number, ranges and sed syntax are refused and nothing moves" {
	export XDG_DATA_HOME="$BATS_TEST_TMPDIR"
	./todo one >/dev/null; ./todo two >/dev/null; ./todo three >/dev/null
	for bad in 1,2 '1p;2' 1abc 0 '$' ' 2'; do
		run ./todo done "$bad"
		[ "$status" -eq 1 ]
	done
	[ "$(wc -l < "$XDG_DATA_HOME/todo/todo.txt")" -eq 3 ]
	[ ! -s "$XDG_DATA_HOME/todo/done.txt" ]
}

@test "todo: a newline in the task text stays one task" {
	export XDG_DATA_HOME="$BATS_TEST_TMPDIR"
	./todo "$(printf 'first\nsecond')" >/dev/null
	[ "$(wc -l < "$XDG_DATA_HOME/todo/todo.txt")" -eq 1 ]
	grep -q 'first second$' "$XDG_DATA_HOME/todo/todo.txt"
}

@test "todo: a todo.txt whose last line has no newline keeps its last task" {
	export XDG_DATA_HOME="$BATS_TEST_TMPDIR"; mkdir -p "$XDG_DATA_HOME/todo"
	printf 'old task' > "$XDG_DATA_HOME/todo/todo.txt"
	printf 'old done' > "$XDG_DATA_HOME/todo/done.txt"
	./todo "new task" >/dev/null
	run ./todo ls
	[[ "${lines[0]}" == *"old task" && "${lines[1]}" == *"new task" ]]
	./todo done 1 >/dev/null
	[ "$(sed -n 1p "$XDG_DATA_HOME/todo/done.txt")" = "old done" ]
	grep -q '^x .* old task$' "$XDG_DATA_HOME/todo/done.txt"
}

@test "todo: a symlinked todo.txt stays a symlink after done" {
	export XDG_DATA_HOME="$BATS_TEST_TMPDIR"; mkdir -p "$XDG_DATA_HOME/todo"
	printf 'a\nb\n' > "$BATS_TEST_TMPDIR/real.txt"
	ln -s "$BATS_TEST_TMPDIR/real.txt" "$XDG_DATA_HOME/todo/todo.txt"
	./todo done 1 >/dev/null
	[ -L "$XDG_DATA_HOME/todo/todo.txt" ]
	[ "$(cat "$BATS_TEST_TMPDIR/real.txt")" = b ]
}

@test "todo: a write that fails is an error, not 'added'" {
	export XDG_DATA_HOME="$BATS_TEST_TMPDIR"; mkdir -p "$XDG_DATA_HOME/todo"
	: > "$XDG_DATA_HOME/todo/todo.txt"; : > "$XDG_DATA_HOME/todo/done.txt"
	chmod 400 "$XDG_DATA_HOME/todo/todo.txt"
	[ -w "$XDG_DATA_HOME/todo/todo.txt" ] && skip "running as root"
	run ./todo "zzz"
	[ "$status" -ne 0 ]
	[[ "$output" != *added* ]]
}

@test "findfat: -n without a value is an error, not an endless loop" {
	run timeout 5 ./findfat -n
	[ "$status" -eq 2 ]
}

@test "findfat: options after the DIR count, a second DIR is an error" {
	d=$BATS_TEST_TMPDIR; mkdir -p "$d/t"
	head -c 3000 /dev/zero > "$d/t/a"; head -c 2000 /dev/zero > "$d/t/b"; head -c 1000 /dev/zero > "$d/t/c"
	run ./findfat "$d/t" -file -n 1
	[ "$status" -eq 0 ]
	[[ "$output" == *"/t/a"* && "$output" != *"/t/b"* && "$output" != *"directories:"* ]]
	run ./findfat "$d/t" "$d"
	[ "$status" -eq 2 ]
	run ./findfat -n 007 "$d/t"
	[ "$status" -eq 0 ]
}

@test "findfat: -- lets a directory called -x be the DIR" {
	d=$BATS_TEST_TMPDIR; mkdir -p "$d/w/-x"; head -c 3000 /dev/zero > "$d/w/-x/f"
	cd "$d/w"
	run "$BATS_TEST_DIRNAME/../findfat" -file -- -x
	[ "$status" -eq 0 ]
	[[ "$output" == *"-x/f"* ]]
}

# a PATH holding only what metadata_cleaner needs plus the fakes a test adds (no real mat2, exiftool, ffmpeg)
mc_path() {
	mkdir -p "$BATS_TEST_TMPDIR/bin"
	for t in bash env dirname basename mktemp cp mv rm file cat head; do
		ln -sf "$(command -v $t)" "$BATS_TEST_TMPDIR/bin/$t"
	done
}

@test "metadata_cleaner: a stripper that fails leaves no clean-NAME copy and exits 1" {
	mc_path
	printf '#!/bin/sh\nexit 1\n' > "$BATS_TEST_TMPDIR/bin/exiftool"; chmod +x "$BATS_TEST_TMPDIR/bin/exiftool"
	echo secret-gps > "$BATS_TEST_TMPDIR/in.jpg"
	PATH="$BATS_TEST_TMPDIR/bin" run ./metadata_cleaner "$BATS_TEST_TMPDIR/in.jpg"
	[ "$status" -eq 1 ]
	[[ "$output" != *"wrote"* ]]
	[ ! -e "$BATS_TEST_TMPDIR/clean-in.jpg" ]
	[ -z "$(ls -A "$BATS_TEST_TMPDIR" | grep -v -e '^bin$' -e '^in.jpg$')" ]
}

@test "metadata_cleaner: a failing ffmpeg leaves no half-written clean-NAME that blocks the next run" {
	mc_path
	printf '#!/bin/sh\nfor a; do l=$a; done\necho partial > "$l"\nexit 1\n' > "$BATS_TEST_TMPDIR/bin/ffmpeg"
	rm -f "$BATS_TEST_TMPDIR/bin/file"
	printf '#!/bin/sh\necho video/mp4\n' > "$BATS_TEST_TMPDIR/bin/file"
	chmod +x "$BATS_TEST_TMPDIR/bin/ffmpeg" "$BATS_TEST_TMPDIR/bin/file"
	: > "$BATS_TEST_TMPDIR/a.mp4"
	PATH="$BATS_TEST_TMPDIR/bin" run ./metadata_cleaner "$BATS_TEST_TMPDIR/a.mp4"
	[ "$status" -eq 1 ]
	[ ! -e "$BATS_TEST_TMPDIR/clean-a.mp4" ]
	printf '#!/bin/sh\nfor a; do l=$a; done\necho good > "$l"\n' > "$BATS_TEST_TMPDIR/bin/ffmpeg"
	PATH="$BATS_TEST_TMPDIR/bin" run ./metadata_cleaner "$BATS_TEST_TMPDIR/a.mp4"
	[ "$status" -eq 0 ]
	[ "$(cat "$BATS_TEST_TMPDIR/clean-a.mp4")" = good ]
}

@test "metadata_cleaner: a file called -x is handed to the stripper as ./-x" {
	d=$BATS_TEST_TMPDIR; mkdir -p "$d/w"; cd "$d/w"
	convert -size 4x4 xc:red ./-x.png
	run "$BATS_TEST_DIRNAME/../metadata_cleaner" -x.png
	[ "$status" -eq 0 ]
	[ -s ./clean--x.png ]
}

@test "metadata_cleaner: a folder it cannot write to is an error" {
	d=$BATS_TEST_TMPDIR; mkdir -p "$d/ro"; convert -size 4x4 xc:red "$d/ro/a.png"; chmod 500 "$d/ro"
	[ -w "$d/ro" ] && skip "running as root"
	run ./metadata_cleaner "$d/ro/a.png"
	chmod 700 "$d/ro"
	[ "$status" -eq 1 ]
	[[ "$output" != *wrote* ]]
}

# a PATH of coreutils plus one fake converter that fails, so the tool picks the fake
morph_path() {
	mkdir -p "$BATS_TEST_TMPDIR/bin"
	for t in bash env dirname basename mktemp mv rm tr cat sleep; do
		ln -sf "$(command -v $t)" "$BATS_TEST_TMPDIR/bin/$t"
	done
}

@test "morph: a failed conversion never deletes the input, even with -f and IN == OUT" {
	morph_path
	printf '#!/bin/sh\nexit 1\n' > "$BATS_TEST_TMPDIR/bin/pandoc"; chmod +x "$BATS_TEST_TMPDIR/bin/pandoc"
	echo precious > "$BATS_TEST_TMPDIR/in.md"
	PATH="$BATS_TEST_TMPDIR/bin" run ./morph -f "$BATS_TEST_TMPDIR/in.md" "$BATS_TEST_TMPDIR/in.md"
	[ "$status" -eq 1 ]
	[ "$(cat "$BATS_TEST_TMPDIR/in.md")" = precious ]
	echo old > "$BATS_TEST_TMPDIR/out.html"
	PATH="$BATS_TEST_TMPDIR/bin" run ./morph -f "$BATS_TEST_TMPDIR/in.md" "$BATS_TEST_TMPDIR/out.html"
	[ "$status" -eq 1 ]
	[ "$(cat "$BATS_TEST_TMPDIR/out.html")" = old ]
}

@test "morph: -f and -l are accepted after the file names too" {
	morph_path
	printf '#!/bin/sh\nfor a; do l=$a; done\necho new > "$l"\n' > "$BATS_TEST_TMPDIR/bin/pandoc"; chmod +x "$BATS_TEST_TMPDIR/bin/pandoc"
	echo a > "$BATS_TEST_TMPDIR/in.md"; echo old > "$BATS_TEST_TMPDIR/out.html"
	PATH="$BATS_TEST_TMPDIR/bin" run ./morph "$BATS_TEST_TMPDIR/in.md" "$BATS_TEST_TMPDIR/out.html" -f
	[ "$status" -eq 0 ]
	[ "$(cat "$BATS_TEST_TMPDIR/out.html")" = new ]
	PATH="$BATS_TEST_TMPDIR/bin" run ./morph "$BATS_TEST_TMPDIR/in.md" "$BATS_TEST_TMPDIR/out.html" -z
	[ "$status" -eq 2 ]
}

@test "morph: names with a leading - or an 'x:' prefix reach the backend as ./name" {
	morph_path
	printf '#!/bin/sh\necho "$@" > "$MORPH_ARGS"\nfor a; do l=$a; done\necho new > "$l"\n' > "$BATS_TEST_TMPDIR/bin/magick"; chmod +x "$BATS_TEST_TMPDIR/bin/magick"
	cd "$BATS_TEST_TMPDIR"; echo x > ./-in.png
	MORPH_ARGS="$BATS_TEST_TMPDIR/args" PATH="$BATS_TEST_TMPDIR/bin" run "$BATS_TEST_DIRNAME/../morph" -- -in.png 'x:y.webp'
	[ "$status" -eq 0 ]
	[ -s "$BATS_TEST_TMPDIR/x:y.webp" ]
	[[ "$(cat "$BATS_TEST_TMPDIR/args")" == "./-in.png "* ]]
	[[ "$(cat "$BATS_TEST_TMPDIR/args")" != *" x:"* ]]
}

@test "morph: SIGTERM midway leaves no partial output and no temp folder" {
	morph_path
	printf '#!/bin/sh\necho half > "$3"\nsleep 1\n' > "$BATS_TEST_TMPDIR/bin/pandoc"; chmod +x "$BATS_TEST_TMPDIR/bin/pandoc"
	echo a > "$BATS_TEST_TMPDIR/in.md"
	PATH="$BATS_TEST_TMPDIR/bin" "$BATS_TEST_DIRNAME/../morph" "$BATS_TEST_TMPDIR/in.md" "$BATS_TEST_TMPDIR/o.html" &
	pid=$!
	sleep 0.3; kill -TERM "$pid"
	wait "$pid" || true
	[ ! -e "$BATS_TEST_TMPDIR/o.html" ]
	[ -z "$(ls -A "$BATS_TEST_TMPDIR" | grep -v -e '^bin$' -e '^in.md$')" ]
}
