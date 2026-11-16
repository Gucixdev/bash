#!/usr/bin/env bats
# fixmedia: media is generated with ffmpeg lavfi (a few seconds, tiny), VLC checks are off (--no-vlc) except where stated.

setup() {
	command -v ffmpeg > /dev/null || skip "ffmpeg missing"
	cd "$BATS_TEST_DIRNAME/.."
	T=$BATS_TEST_TMPDIR
	FM=$PWD/fixmedia
}

mk() { # OUT AUDIO-ARGS... : 2 s 160x120 test video
	local out=$1; shift
	ffmpeg -nostdin -v error -y -f lavfi -i testsrc=size=160x120:rate=25:duration=2 -f lavfi -i "sine=frequency=440:duration=2" "$@" "$out"
}

@test "fixmedia: a healthy mp4 is left alone" {
	mk "$T/a.mp4" -c:v libx264 -pix_fmt yuv420p -c:a aac
	run "$FM" --no-vlc "$T/a.mp4"
	[ "$status" -eq 0 ]
	[[ $output == *"ok "* ]]
	[ ! -e "$T/fixed-a.mp4" ]
}

@test "fixmedia: usage errors exit 2" {
	run "$FM"
	[ "$status" -eq 2 ]
	run "$FM" --sync abc "$T/x"
	[ "$status" -eq 2 ]
	run "$FM" --bogus x
	[ "$status" -eq 2 ]
}

@test "fixmedia: a missing file is reported and exits 1" {
	run "$FM" --no-vlc "$T/nope.mp4"
	[ "$status" -eq 1 ]
}

@test "fixmedia: AC3 5.1 sound becomes stereo AAC, video copied" {
	mk "$T/b.mkv" -c:v libx264 -pix_fmt yuv420p -af "pan=5.1|FL=c0|FR=c0|FC=c0|LFE=c0|BL=c0|BR=c0" -c:a ac3
	run "$FM" --no-vlc "$T/b.mkv"
	[ "$status" -eq 0 ]
	[[ $output == *"audiocodec"* ]]
	[ -s "$T/fixed-b.mkv" ]
	[ "$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name,channels -of csv=p=0 "$T/fixed-b.mkv")" = "aac,2" ]
	[ "$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$T/fixed-b.mkv")" = "h264" ]
}

@test "fixmedia: very quiet sound is raised" {
	mk "$T/q.mp4" -c:v libx264 -pix_fmt yuv420p -af volume=-45dB -c:a aac
	run "$FM" --no-vlc "$T/q.mp4"
	[ "$status" -eq 0 ]
	[[ $output == *"quiet"* ]]
	max=$(ffmpeg -nostdin -v info -i "$T/fixed-q.mp4" -vn -af volumedetect -f null - 2>&1 | sed -n 's/.*max_volume: \(-\{0,1\}[0-9.]*\) dB.*/\1/p')
	awk -v m="$max" 'BEGIN { exit !(m > -6) }'
}

@test "fixmedia: 10-bit video is re-encoded to 8-bit 4:2:0" {
	mk "$T/t.mkv" -c:v libx264 -pix_fmt yuv420p10le -c:a aac
	run "$FM" --no-vlc "$T/t.mkv"
	[ "$status" -eq 0 ]
	[[ $output == *"pixfmt"* ]]
	[ "$(ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt -of csv=p=0 "$T/fixed-t.mkv")" = "yuv420p" ]
}

@test "fixmedia: a file with no sound is reported" {
	ffmpeg -nostdin -v error -y -f lavfi -i testsrc=size=160x120:rate=25:duration=1 -c:v libx264 -pix_fmt yuv420p "$T/n.mp4"
	run "$FM" -c --no-vlc "$T/n.mp4"
	[ "$status" -eq 1 ]
	[[ $output == *"noaudio"* ]]
}

@test "fixmedia: -c changes nothing and exits 1 on a problem" {
	mk "$T/c.mkv" -c:v libx264 -pix_fmt yuv420p -c:a ac3
	run "$FM" -c --no-vlc "$T/c.mkv"
	[ "$status" -eq 1 ]
	[ ! -e "$T/fixed-c.mkv" ]
}

@test "fixmedia: a cut-off file is rebuilt into one that decodes" {
	mk "$T/cut.mkv" -c:v libx264 -pix_fmt yuv420p -c:a aac
	size=$(stat -c %s "$T/cut.mkv")
	head -c $((size * 3 / 4)) "$T/cut.mkv" > "$T/part.mkv"
	run "$FM" --no-vlc "$T/part.mkv"
	[ "$status" -eq 0 ] || { echo "$output"; false; }
	[ -s "$T/fixed-part.mkv" ]
	[ -z "$(ffmpeg -nostdin -v error -err_detect explode -i "$T/fixed-part.mkv" -f null - 2>&1)" ]
}

@test "fixmedia: an existing fixed- file is never overwritten" {
	mk "$T/d.mkv" -c:v libx264 -pix_fmt yuv420p -c:a ac3
	echo keep > "$T/fixed-d.mkv"
	run "$FM" --no-vlc "$T/d.mkv"
	[ "$status" -eq 1 ]
	[ "$(cat "$T/fixed-d.mkv")" = keep ]
}

@test "fixmedia: --sync delays the sound" {
	mk "$T/s.mp4" -c:v libx264 -pix_fmt yuv420p -c:a aac
	run "$FM" --no-vlc --sync 1 "$T/s.mp4"
	[ "$status" -eq 0 ] || { echo "$output"; false; }
	[ -s "$T/fixed-s.mp4" ]
	st=$(ffprobe -v error -select_streams a:0 -show_entries stream=start_time -of csv=p=0 "$T/fixed-s.mp4")
	awk -v s="$st" 'BEGIN { exit !(s >= 0.9) }'
}

@test "fixmedia: a CP1250 subtitle next to the video becomes UTF-8" {
	mk "$T/v.mp4" -c:v libx264 -pix_fmt yuv420p -c:a aac
	printf '1\n00:00:00,000 --> 00:00:01,500\nzażółć gęślą jaźń\n' | iconv -f UTF-8 -t CP1250 > "$T/v.srt"
	FIXMEDIA_SUBCHARSET=CP1250 run "$FM" --no-vlc "$T/v.mp4"
	[ "$status" -eq 0 ]
	[[ $output == *"subtitles"* ]]
	grep -q 'zażółć gęślą jaźń' "$T/fixed-v.srt"
	[ "$(cat "$T/v.srt" | iconv -f CP1250 -t UTF-8 | grep -c zażółć)" -eq 1 ]
}

@test "fixmedia: a subtitle file given directly is converted, BOM and CRLF removed" {
	printf '\xef\xbb\xbf1\r\n00:00:00,000 --> 00:00:01,000\r\nhello\r\n' > "$T/b.srt"
	run "$FM" "$T/b.srt"
	[ "$status" -eq 0 ]
	[ -s "$T/fixed-b.srt" ]
	[ "$(head -c 3 "$T/fixed-b.srt" | od -An -tx1 | tr -d ' \n')" != efbbbf ]
	! grep -q $'\r' "$T/fixed-b.srt"
}

@test "fixmedia: --shift moves subtitle times" {
	printf '1\n00:00:01,000 --> 00:00:02,000\nhi\n' > "$T/h.srt"
	run "$FM" --shift 2 "$T/h.srt"
	[ "$status" -eq 0 ] || { echo "$output"; false; }
	grep -q '00:00:03,000 --> 00:00:04,000' "$T/fixed-h.srt"
}

@test "fixmedia: a lone subtitle with the wrong name is copied under the video's name" {
	mk "$T/Film.mp4" -c:v libx264 -pix_fmt yuv420p -c:a aac
	printf '1\n00:00:00,000 --> 00:00:01,000\nhi\n' > "$T/Totally.Other.Name.srt"
	run "$FM" --no-vlc "$T/Film.mp4"
	[ "$status" -eq 0 ]
	[[ $output == *"subname"* ]]
	[ -s "$T/fixed-Film.srt" ]
}

@test "fixmedia: --embed muxes the companion subtitle into the video" {
	mk "$T/e.mkv" -c:v libx264 -pix_fmt yuv420p -c:a aac
	printf '1\n00:00:00,000 --> 00:00:01,000\nhi\n' > "$T/e.srt"
	run "$FM" --no-vlc --embed "$T/e.mkv"
	[ "$status" -eq 0 ] || { echo "$output"; false; }
	[ "$(ffprobe -v error -select_streams s -show_entries stream=codec_name -of csv=p=0 "$T/fixed-e.mkv")" = subrip ]
}

@test "fixmedia: a broken picture is re-saved, a good one left alone" {
	command -v magick > /dev/null || command -v convert > /dev/null || skip "ImageMagick missing"
	ffmpeg -nostdin -v error -y -f lavfi -i testsrc=size=64x64:duration=1 -frames:v 1 "$T/p.png"
	run "$FM" "$T/p.png"
	[ "$status" -eq 0 ]
	[[ $output == *"ok "* ]]
	head -c 200 "$T/p.png" > "$T/broken.png"
	run "$FM" "$T/broken.png"
	[[ $output == *"decode"* ]]
}

@test "fixmedia: syntax and --help" {
	bash -n fixmedia
	run "$FM" --help
	[ "$status" -eq 0 ]
	[[ $output == *"usage: fixmedia"* ]]
}

mk10() { mk "$1" -c:v libx264 -pix_fmt yuv420p10le -c:a aac; }

@test "fixmedia: -c after the file names still means check only" {
	mk10 "$T/t.mkv"
	run "$FM" --no-vlc "$T/t.mkv" -c
	[ "$status" -eq 1 ]
	[[ $output == *pixfmt* ]]
	[ ! -e "$T/fixed-t.mkv" ]
}

@test "fixmedia: a number of seconds must be a number" {
	for v in 1abc 5x -- 1.2.3; do
		run "$FM" --no-vlc --sync "$v" "$T/x.mkv"
		[ "$status" -eq 2 ]
		run "$FM" --no-vlc --shift "$v" "$T/x.mkv"
		[ "$status" -eq 2 ]
	done
	run "$FM" --no-vlc "$T/x.mkv" --sync
	[ "$status" -eq 2 ]
}

@test "fixmedia: a file whose name starts with - is diagnosed, not reported ok" {
	cd "$T"
	mk10 ./-d.mkv
	run "$FM" --no-vlc -c -- -d.mkv
	[ "$status" -eq 1 ]
	[[ $output == *pixfmt* ]]
}

@test "fixmedia: a dangling fixed-NAME link is not written through" {
	mk10 "$T/t.mkv"
	ln -s "$T/target" "$T/fixed-t.mkv"
	run "$FM" --no-vlc "$T/t.mkv"
	[ "$status" -eq 1 ]
	[ ! -e "$T/target" ]
}

@test "fixmedia: SIGTERM midway leaves no half-written fixed-NAME" {
	mk10 "$T/t.mkv"
	mkdir "$T/fk"
	real=$(command -v ffmpeg)
	cat > "$T/fk/ffmpeg" <<SH
#!/bin/sh
for a; do l=\$a; done
case \$l in */fixed-*) echo half > "\$l"; sleep 2; exit 1 ;; esac
exec $real "\$@"
SH
	chmod +x "$T/fk/ffmpeg"
	PATH="$T/fk:$PATH" "$FM" --no-vlc "$T/t.mkv" > /dev/null 2>&1 &
	pid=$!
	sleep 1; kill -TERM "$pid"
	wait "$pid" || true
	[ ! -e "$T/fixed-t.mkv" ]
}
