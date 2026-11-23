#!/usr/bin/env bats
# textswap: no real tesseract needed (a fake one on PATH prints a fixed TSV, or --boxes is used); Pillow makes the images.

setup() {
	command -v python3 > /dev/null && python3 -c 'import PIL' 2> /dev/null || skip "python3 with Pillow missing"
	cd "$BATS_TEST_DIRNAME/.." || exit 1
	T=$BATS_TEST_TMPDIR
	TS=$PWD/textswap
	if [ -z "$(fc-list :lang=zh 2> /dev/null)" ]; then skip "no CJK font installed"; fi
	python3 - "$T" << 'PY'
import sys
from PIL import Image, ImageDraw
t = sys.argv[1]
im = Image.new("RGB", (200, 100), (240, 235, 200))
d = ImageDraw.Draw(im)
for i, (x, y, w, h) in enumerate([(10, 10, 60, 20), (80, 12, 50, 18), (20, 50, 70, 20), (120, 60, 60, 25)]):
    d.rectangle((x, y, x + w - 1, y + h - 1), fill=(240, 235, 200))
    d.text((x + 2, y + 2), "word%d" % i, fill=(20, 20, 80))
d.line((0, 99, 199, 99), fill=(200, 0, 0))
im.save(t + "/in.png")
PY
	printf '10\t10\t60\t20\tword0\n80\t12\t50\t18\tword1\n20\t50\t70\t20\tword2\n120\t60\t60\t25\tword3\n' > "$T/boxes.tsv"
	# a fake tesseract: same words, in tesseract's TSV format
	mkdir -p "$T/bin"
	cat > "$T/bin/tesseract" << 'SH'
#!/bin/sh
[ "$2" = "-" ] && [ "$3" = "tsv" ] || { echo "fake tesseract: unexpected args $*" >&2; exit 9; }
printf 'level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext\n'
printf '1\t1\t0\t0\t0\t0\t0\t0\t200\t100\t-1\t\n'
printf '5\t1\t1\t1\t1\t1\t10\t10\t60\t20\t95.5\tword0\n'
printf '5\t1\t1\t1\t1\t2\t80\t12\t50\t18\t96\tword1\n'
printf '5\t1\t1\t1\t2\t1\t20\t50\t70\t20\t91\tword2\n'
printf '5\t1\t1\t1\t2\t2\t120\t60\t60\t25\t90\tword3\n'
printf '5\t1\t1\t1\t2\t3\t5\t5\t10\t10\t3\tlowconf\n'
printf '5\t1\t1\t1\t2\t4\t5\t5\t10\t10\t90\t \n'
SH
	chmod +x "$T/bin/tesseract"
	export PATH="$T/bin:$PATH"
}

# changed A B BOXES PAD : prints the indexes of boxes that differ, then "outside=same" or "outside=CHANGED"
changed() {
	python3 - "$1" "$2" "$3" "$4" << 'PY'
import sys
from PIL import Image, ImageChops
a, b = Image.open(sys.argv[1]).convert("RGB"), Image.open(sys.argv[2]).convert("RGB")
pad = int(sys.argv[4])
boxes = [tuple(map(int, l.split("\t")[:4])) for l in open(sys.argv[3]) if l.strip()]
assert a.size == b.size
diff = ImageChops.difference(a, b)
hit = []
inside = Image.new("L", a.size, 0)
for i, (x, y, w, h) in enumerate(boxes):
    r = (max(0, x - pad), max(0, y - pad), min(a.size[0], x + w + pad), min(a.size[1], y + h + pad))
    inside.paste(255, r)
    if diff.crop(r).getbbox():
        hit.append(i)
outside = ImageChops.multiply(diff.convert("L").point(lambda v: 255 if v else 0), ImageChops.invert(inside))
print(",".join(map(str, hit)), "outside=" + ("CHANGED" if outside.getbbox() else "same"))
PY
}

@test "textswap: --help prints the header and exits 0" {
	run "$TS" --help
	[ "$status" -eq 0 ]
	[[ $output == *"privacy filter"* ]]
	[[ $output == *"Exit status"* ]]
}

@test "textswap: usage errors exit 2" {
	run "$TS"
	[ "$status" -eq 2 ]
	run "$TS" --bogus "$T/in.png"
	[ "$status" -eq 2 ]
	run "$TS" --ratio 1.5 "$T/in.png"
	[ "$status" -eq 2 ]
	run "$TS" "$T/in.png" "$T/in.png" -o "$T/x.png"
	[ "$status" -eq 2 ]
}

@test "textswap: ratio 1 changes every box, only inside the boxes (--pad 0)" {
	run "$TS" "$T/in.png" -o "$T/o.png" --ratio 1 --pad 0
	[ "$status" -eq 0 ]
	[ -f "$T/o.png" ]
	run changed "$T/in.png" "$T/o.png" "$T/boxes.tsv" 0
	[ "$output" = "0,1,2,3 outside=same" ]
}

@test "textswap: the default pad of 1 stays within the boxes grown by 1" {
	"$TS" "$T/in.png" -o "$T/o.png" --ratio 1
	run changed "$T/in.png" "$T/o.png" "$T/boxes.tsv" 1
	[ "$output" = "0,1,2,3 outside=same" ]
}

@test "textswap: ratio 0 changes nothing, ratio 0.5 swaps exactly half" {
	"$TS" "$T/in.png" -o "$T/o0.png" --ratio 0
	run changed "$T/in.png" "$T/o0.png" "$T/boxes.tsv" 1
	[ "$output" = " outside=same" ]
	"$TS" "$T/in.png" -o "$T/o5.png" --ratio 0.5 --pad 0
	run changed "$T/in.png" "$T/o5.png" "$T/boxes.tsv" 0
	[[ $output == *" outside=same" ]]
	n=$(printf '%s' "${output% outside*}" | tr ',' '\n' | grep -c .)
	[ "$n" -eq 2 ]
}

@test "textswap: low-confidence and blank OCR words are ignored" {
	run "$TS" "$T/in.png" -o "$T/o.png" --ratio 1
	[[ $output == *"swapped 4 of 4"* ]]
	run "$TS" "$T/in.png" -o "$T/o2.png" --ratio 1 --min-conf 0
	[[ $output == *"swapped 5 of 5"* ]]
}

@test "textswap: same seed same bytes, another seed differs" {
	"$TS" "$T/in.png" -o "$T/a.png" --seed 7 --ratio 1
	"$TS" "$T/in.png" -o "$T/b.png" --seed 7 --ratio 1
	"$TS" "$T/in.png" -o "$T/c.png" --seed 8 --ratio 1
	cmp "$T/a.png" "$T/b.png"
	! cmp -s "$T/a.png" "$T/c.png"
}

@test "textswap: --boxes works without OCR, and wins over tesseract" {
	TEXTSWAP_TESSERACT=no-such-ocr run "$TS" "$T/in.png" -o "$T/o.png" --boxes "$T/boxes.tsv" --ratio 1 --pad 0
	[ "$status" -eq 0 ]
	run changed "$T/in.png" "$T/o.png" "$T/boxes.tsv" 0
	[ "$output" = "0,1,2,3 outside=same" ]
}

@test "textswap: default output name, never overwrites the input or an existing output" {
	cp "$T/in.png" "$T/pic.png"
	sum=$(cksum < "$T/pic.png")
	run "$TS" "$T/pic.png"
	[ "$status" -eq 0 ]
	[ -f "$T/pic.swapped.png" ]
	[ "$(cksum < "$T/pic.png")" = "$sum" ]
	run "$TS" "$T/pic.png"
	[ "$status" -eq 1 ]
	[[ $output == *"exists"* ]]
	run "$TS" "$T/pic.png" -o "$T/pic.png" -f
	[ "$status" -eq 1 ]
	[[ $output == *"refusing to overwrite the input"* ]]
	[ "$(cksum < "$T/pic.png")" = "$sum" ]
	run "$TS" "$T/pic.png" -f
	[ "$status" -eq 0 ]
}

@test "textswap: jpeg output works" {
	"$TS" "$T/in.png" -o "$T/o.jpg" --ratio 1
	run python3 -c "from PIL import Image; print(Image.open('$T/o.jpg').format)"
	[ "$output" = "JPEG" ]
}

@test "textswap: a word keeps its characters when OCR jitters by a pixel (--quant grid)" {
	printf '20\t20\t60\t20\tx\n' > "$T/j1.tsv"
	printf '21\t20\t60\t20\tx\n' > "$T/j2.tsv"
	a=$("$TS" "$T/in.png" -o "$T/j1.png" --boxes "$T/j1.tsv" --ratio 1 --quant 12 -v 2>&1 | grep -o -- '-> .*')
	b=$("$TS" "$T/in.png" -o "$T/j2.png" --boxes "$T/j2.tsv" --ratio 1 --quant 12 -v 2>&1 | grep -o -- '-> .*')
	[ -n "$a" ]
	[ "$a" = "$b" ]
}

@test "textswap: no OCR and no --boxes exits 3 and says how to get tesseract" {
	TEXTSWAP_TESSERACT=no-such-ocr run "$TS" "$T/in.png" -o "$T/o.png"
	[ "$status" -eq 3 ]
	[[ $output == *"pacman -S tesseract"* ]]
	[[ $output == *"--boxes"* ]]
	[ ! -e "$T/o.png" ]
}

@test "textswap: no CJK font exits 3 and names packages; --font with a missing path exits 3" {
	mkdir -p "$T/nofc"
	printf '#!/bin/sh\nexit 0\n' > "$T/nofc/fc-list"
	chmod +x "$T/nofc/fc-list"
	PATH="$T/nofc:$PATH" TEXTSWAP_FONTDIRS="$T/empty" run "$TS" "$T/in.png" -o "$T/o.png"
	[ "$status" -eq 3 ]
	[[ $output == *"noto-fonts-cjk"* ]]
	run "$TS" "$T/in.png" -o "$T/o.png" --font "$T/none.ttf"
	[ "$status" -eq 3 ]
}

@test "textswap: a font without CJK glyphs exits 3" {
	f=$(fc-list :family=DejaVuSans -f '%{file}\n' 2> /dev/null | head -n 1)
	[ -n "$f" ] || skip "no DejaVu font to use as a non-CJK font"
	run "$TS" "$T/in.png" -o "$T/o.png" --font "$f" --ratio 1
	[ "$status" -eq 3 ]
	[[ $output == *"no usable CJK glyphs"* ]]
}

@test "textswap: a failing OCR run is an error, not a silent copy" {
	printf '#!/bin/sh\necho boom >&2\nexit 1\n' > "$T/bin/tesseract"
	run "$TS" "$T/in.png" -o "$T/o.png"
	[ "$status" -eq 1 ]
	[[ $output == *"OCR failed"* ]]
}

@test "textswap: a video runs end to end at --fps, with audio kept" {
	command -v ffmpeg > /dev/null && command -v ffprobe > /dev/null || skip "ffmpeg missing"
	ffmpeg -nostdin -v error -y -f lavfi -i testsrc=size=200x100:rate=10:duration=1 -f lavfi -i sine=frequency=440:duration=1 \
		-c:v libx264 -crf 5 -pix_fmt yuv420p -c:a aac "$T/clip.mp4"
	run "$TS" "$T/clip.mp4" -o "$T/clip.out.mp4"
	[ "$status" -eq 0 ]
	[[ $output == *"source runs at 10.00 fps; the output is at 2 fps"* ]]
	[ -f "$T/clip.out.mp4" ]
	run ffprobe -v error -show_entries stream=codec_type,r_frame_rate -of csv=p=0 "$T/clip.out.mp4"
	[[ $output == *"video,2/1"* ]]
	[[ $output == *"audio"* ]]
	ffmpeg -nostdin -v error -y -i "$T/clip.mp4" -frames:v 1 "$T/f_in.png"
	ffmpeg -nostdin -v error -y -i "$T/clip.out.mp4" -frames:v 1 "$T/f_out.png"
	python3 - "$T/f_in.png" "$T/f_out.png" << 'PY'
import sys
from PIL import Image, ImageChops, ImageStat
a, b = Image.open(sys.argv[1]).convert("L"), Image.open(sys.argv[2]).convert("L")
d = ImageChops.difference(a, b)
inb = ImageStat.Stat(d.crop((10, 10, 70, 30))).mean[0]
out = ImageStat.Stat(d.crop((100, 40, 200, 100))).mean[0]
assert inb > 2 * out + 5, (inb, out)
PY
}

@test "textswap: a video longer than 120 s is refused unless --long" {
	command -v ffmpeg > /dev/null && command -v ffprobe > /dev/null || skip "ffmpeg missing"
	ffmpeg -nostdin -v error -y -f lavfi -i testsrc=size=16x16:rate=1:duration=121 -c:v libx264 -g 121 -pix_fmt yuv420p "$T/long.mp4"
	run "$TS" "$T/long.mp4" -o "$T/long.out.mp4"
	[ "$status" -eq 1 ]
	[[ $output == *"--long"* ]]
	[ ! -e "$T/long.out.mp4" ]
}

@test "textswap: --seed may start with a dash" {
	run "$TS" "$T/in.png" -o "$T/o.png" --boxes "$T/boxes.tsv" --seed -x
	[ "$status" -eq 0 ]
	[ -f "$T/o.png" ]
}

@test "textswap: an input without extension in a folder with a dot gets its default name next to it" {
	mkdir "$T/my.dir"
	cp "$T/in.png" "$T/my.dir/shot"
	run "$TS" "$T/my.dir/shot" --boxes "$T/boxes.tsv"
	[ "$status" -eq 0 ]
	[ -f "$T/my.dir/shot.swapped.png" ]
}

@test "textswap: a webm without a duration (screen recorder, pipe) is read, and still limited to 120 s" {
	command -v ffmpeg > /dev/null && command -v ffprobe > /dev/null || skip "ffmpeg missing"
	ffmpeg -nostdin -v error -y -f lavfi -i testsrc=size=64x64:rate=5:duration=2 -c:v libvpx -f webm pipe:1 > "$T/nodur.webm"
	[ "$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$T/nodur.webm")" = "N/A" ]
	run "$TS" "$T/nodur.webm" -o "$T/nodur.out.webm" --boxes "$T/boxes.tsv"
	[ "$status" -eq 0 ]
	[ -s "$T/nodur.out.webm" ]
	ffmpeg -nostdin -v error -y -f lavfi -i testsrc=size=16x16:rate=1:duration=121 -c:v libvpx -g 121 -f webm pipe:1 > "$T/nodurlong.webm"
	run "$TS" "$T/nodurlong.webm" -o "$T/nodurlong.out.webm" --boxes "$T/boxes.tsv"
	[ "$status" -eq 1 ]
	[[ $output == *"--long"* ]]
}
