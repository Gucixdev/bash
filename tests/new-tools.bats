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
	run ./nmap -- --version
	[ "$status" -eq 0 ]
	[[ "$output" == *"Nmap version"* ]]
}

@test "nmap: unknown preset is a clean error, not a crash" {
	run ./nmap nope some-host
	[ "$status" -eq 2 ]
}

@test "gitgrab: usage error with no args" {
	run ./gitgrab
	[ "$status" -eq 2 ]
}

@test "gitgrab: repo without a path is a clean error" {
	run ./gitgrab owner/repo
	[ "$status" -eq 2 ]
	[[ "$output" == *"PATH"* ]]
}

@test "gitgrab: refuses to overwrite an existing file" {
	tmp=$(mktemp -d)
	echo keep > "$tmp/x"
	run ./gitgrab owner/repo x -o "$tmp/x"
	[ "$status" -eq 1 ]
	[[ "$output" == *"exists"* ]]
	[ "$(cat "$tmp/x")" = keep ]
	rm -rf "$tmp"
}

@test "logcollector: summary-only run writes no archive" {
	tmp=$(mktemp -d)
	run ./logcollector -n -s "1 hour ago" -o "$tmp"
	[ "$status" -eq 0 ]
	[[ "$output" == *"logcollector summary"* ]]
	[ -z "$(ls -A "$tmp")" ]
	rm -rf "$tmp"
}

@test "logcollector: redacts tokens, passwords and private keys" {
	tmp=$(mktemp -d)
	eval "$(sed -n '/^redact() {/,/^}/p' ./logcollector)"
	redact_ip=0
	out=$(printf '%s\n' \
		'x ghp_abcdefghijklmnopqrstuvwxyz0123456789 y' \
		'db password=hunter2 ok' \
		'-----BEGIN OPENSSH PRIVATE KEY-----' 'AAAAsecret' '-----END OPENSSH PRIVATE KEY-----' \
		'plain line' | redact)
	[[ "$out" != *ghp_abc* ]]
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

@test "gitgrab: a blob URL is turned into the raw URL, token goes in a header not the URL" {
	tmp=$(mktemp -d)
	printf '#!/bin/sh\nprintf "%%s\\n" "$@"\n' > "$tmp/curl"
	chmod +x "$tmp/curl"
	PATH="$tmp:$PATH" GH_TOKEN=sekret run ./gitgrab https://github.com/o/r/blob/main/src/x.c -o -
	[ "$status" -eq 0 ]
	[[ "$output" == *"https://raw.githubusercontent.com/o/r/main/src/x.c"* ]]
	[[ "$output" == *"Authorization: Bearer sekret"* ]]
	[[ "$output" != *"raw.githubusercontent.com/o/r/main/src/x.c?"*sekret* ]]
	rm -rf "$tmp"
}

@test "gitgrab: falls back to the token gh is logged in with" {
	tmp=$(mktemp -d)
	printf '#!/bin/sh\nprintf "%%s\\n" "$@"\n' > "$tmp/curl"
	printf '#!/bin/sh\n[ "$1 $2" = "auth token" ] && echo fromgh\n' > "$tmp/gh"
	chmod +x "$tmp/curl" "$tmp/gh"
	PATH="$tmp:$PATH" run env -u GH_TOKEN ./gitgrab o/r f -o -
	[ "$status" -eq 0 ]
	[[ "$output" == *"Authorization: Bearer fromgh"* ]]
	rm -rf "$tmp"
}

@test "gitgrab: OWNER/REPO PATH [REF] defaults to HEAD and honours the ref" {
	tmp=$(mktemp -d)
	printf '#!/bin/sh\nfor a; do u=$a; done\nprintf "%%s\\n" "$u"\n' > "$tmp/curl"
	chmod +x "$tmp/curl"
	PATH="$tmp:$PATH" run ./gitgrab o/r dir/f.txt -o -
	[ "$output" = "https://raw.githubusercontent.com/o/r/HEAD/dir/f.txt" ]
	PATH="$tmp:$PATH" run ./gitgrab o/r dir/f.txt v2 -o -
	[ "$output" = "https://raw.githubusercontent.com/o/r/v2/dir/f.txt" ]
	rm -rf "$tmp"
}

@test "gitgrab: a failed fetch leaves no file behind" {
	tmp=$(mktemp -d)
	printf '#!/bin/sh\nexit 22\n' > "$tmp/curl"
	chmod +x "$tmp/curl"
	cd "$tmp"
	PATH="$tmp:$PATH" run "$BATS_TEST_DIRNAME/../gitgrab" o/r nothing.txt
	[ "$status" -eq 1 ]
	[ ! -e "$tmp/nothing.txt" ]
	[ -z "$(ls -A "$tmp" | grep gitgrab)" ]
	cd "$BATS_TEST_DIRNAME/.."
	rm -rf "$tmp"
}

@test "logcollector: writes an archive that contains the summary" {
	tmp=$(mktemp -d)
	run ./logcollector -s "10 minutes ago" -o "$tmp"
	[ "$status" -eq 0 ]
	arch=$(ls "$tmp"/logcollector-*.tar.* | head -1)
	[ -f "$arch" ]
	case $arch in
		*.zst) zstd -dc "$arch" | tar -t | grep -q 'SUMMARY.txt' ;;
		*) tar -tzf "$arch" | grep -q 'SUMMARY.txt' ;;
	esac
	rm -rf "$tmp"
}

@test "logcollector: -I masks IPv4 and MAC addresses, without it they stay" {
	eval "$(sed -n '/^redact() {/,/^}/p' ./logcollector)"
	redact_ip=0
	out=$(echo 'link 192.168.1.20 aa:bb:cc:dd:ee:ff' | redact)
	[[ "$out" == *192.168.1.20* ]]
	redact_ip=1
	out=$(echo 'link 192.168.1.20 aa:bb:cc:dd:ee:ff' | redact)
	[[ "$out" != *192.168.1.20* ]]
	[[ "$out" != *aa:bb:cc* ]]
}

@test "logcollector: Authorization headers and URL credentials are redacted" {
	eval "$(sed -n '/^redact() {/,/^}/p' ./logcollector)"
	redact_ip=0
	out=$(printf '%s\n' 'curl -H "Authorization: Bearer abcdef1234567890" https://bob:s3cret@example.com/x' | redact)
	[[ "$out" != *abcdef1234567890* ]]
	[[ "$out" != *s3cret* ]]
	[[ "$out" == *example.com* ]]
}

@test "nmap: each preset maps to the right real flags" {
	tmp=$(mktemp -d)
	printf '#!/bin/sh\necho "$@"\n' > "$tmp/nmap"
	chmod +x "$tmp/nmap"
	PATH="$tmp:$PATH" run ./nmap quick host
	[ "$output" = "-T4 -F host" ]
	PATH="$tmp:$PATH" run ./nmap full host
	[ "$output" = "-p- host" ]
	PATH="$tmp:$PATH" run ./nmap ping 10.0.0.0/24
	[ "$output" = "-sn 10.0.0.0/24" ]
	PATH="$tmp:$PATH" run ./nmap service host
	[ "$output" = "-sV host" ]
	rm -rf "$tmp"
}

@test "nmap: does not call itself when it is the first nmap on PATH" {
	tmp=$(mktemp -d)
	mkdir "$tmp/bin" "$tmp/real"
	ln -s "$PWD/nmap" "$tmp/bin/nmap"
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
	[[ "$output" == broken* ]]
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
