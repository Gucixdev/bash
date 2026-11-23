#!/usr/bin/env bats
# gamedev/sprites (split, grid, sheet). split is tested with a fake gimp-console (the bash side: files, trim, map, errors)
# and, when GIMP 3 is installed, once for real.

setup() {
	command -v magick > /dev/null || skip "no ImageMagick"
	T=$BATS_TEST_TMPDIR
	R=$BATS_TEST_DIRNAME/..
	magick -size 16x16 xc:red "$T/a.png"
	magick -size 8x20 xc:green "$T/b.png"
	magick -size 12x12 xc:blue "$T/c.png"
}

@test "sprites grid: -h prints the header" {
	run "$R/gamedev/sprites" -h
	[ "$status" -eq 0 ]
	[[ ${lines[0]} == "sprites - "* ]]
}

@test "sprites grid: no sprites is a usage error" {
	run "$R/gamedev/sprites" grid
	[ "$status" -eq 2 ]
}

@test "sprites grid: a missing file fails and writes no sheet" {
	run "$R/gamedev/sprites" grid -o "$T/g.png" "$T/a.png" "$T/nope.png"
	[ "$status" -eq 1 ]
	[ ! -e "$T/g.png" ]
}

@test "sprites grid: bad numbers are usage errors" {
	run "$R/gamedev/sprites" grid -c x "$T/a.png"
	[ "$status" -eq 2 ]
	run "$R/gamedev/sprites" grid -p -1 "$T/a.png"
	[ "$status" -eq 2 ]
}

@test "sprites grid: cells, padding, positions and the map" {
	run "$R/gamedev/sprites" grid -c 2 -p 1 -o "$T/g.png" "$T/a.png" "$T/b.png" "$T/c.png"
	[ "$status" -eq 0 ]
	[ "$(magick identify -format '%wx%h' "$T/g.png")" = "35x43" ]
	[ "$(cat "$T/g.tsv")" = "$(printf '0\t%s\t0\t0\t1\t1\t16\t16\n1\t%s\t1\t0\t18\t1\t8\t20\n2\t%s\t0\t1\t1\t22\t12\t12' "$T/a.png" "$T/b.png" "$T/c.png")" ]
	[ "$(magick "$T/g.png" -format '%[pixel:p{1,1}]' info:)" = "srgba(255,0,0,1)" ]
	[ "$(magick "$T/g.png" -format '%[pixel:p{18,1}]' info:)" = "srgba(0,128,0,1)" ]
	[ "$(magick "$T/g.png" -format '%[pixel:p{1,22}]' info:)" = "srgba(0,0,255,1)" ]
	[ "$(magick "$T/g.png" -format '%[pixel:p{18,22}]' info:)" = "srgba(0,0,0,0)" ]
}

@test "sprites grid: default columns are as square as possible" {
	run "$R/gamedev/sprites" grid -o "$T/g.png" "$T/a.png" "$T/a.png" "$T/a.png" "$T/a.png" "$T/a.png"
	[ "$status" -eq 0 ]
	[ "$(magick identify -format '%wx%h' "$T/g.png")" = "48x32" ]
}

@test "sprites grid: more columns than sprites is cut to the sprite count" {
	run "$R/gamedev/sprites" grid -c 9 -o "$T/g.png" "$T/a.png" "$T/a.png"
	[ "$status" -eq 0 ]
	[ "$(magick identify -format '%wx%h' "$T/g.png")" = "32x16" ]
}

@test "sprites grid: a name with spaces works" {
	cp "$T/a.png" "$T/my sprite.png"
	run "$R/gamedev/sprites" grid -o "$T/g.png" "$T/my sprite.png"
	[ "$status" -eq 0 ]
	[ "$(magick identify -format '%wx%h' "$T/g.png")" = "16x16" ]
}

@test "sprites grid: a name starting with a dash is a file, not an option" {
	cp "$T/a.png" "$T/-dash.png"
	cd "$T"
	run "$R/gamedev/sprites" grid -o g.png -- -dash.png
	[ "$status" -eq 0 ]
	[ "$(magick identify -format '%wx%h' g.png)" = "16x16" ]
}

# ---- layer2sprite --------------------------------------------------------------------------------------------------

fake_gimp() {   # a gimp-console that "exports" two layers: head 16x16 with a 4px transparent border, body 10x10
	mkdir -p "$T/bin"
	cat > "$T/bin/gimp-console" << 'EOF'
#!/bin/sh
job=$(printf '%s\n' "$*" | sed -n "s/.*open('\([^']*\)').*/\1/p")
out=$(sed -n "s/^OUT = '\(.*\)'$/\1/p" "$job")
[ -n "$FAKE_GIMP_FAIL" ] && { echo "boom" >&2; exit 1; }
magick -size 16x16 xc:none -fill red -draw 'rectangle 4,4 11,11' "$out/00-head.png"
magick -size 10x10 xc:blue "$out/01-body.png"
printf '00-head.png\thead\t4\t4\t16\t16\n01-body.png\tbody\t20\t18\t10\t10\n' > "$out/layers.raw"
EOF
	chmod +x "$T/bin/gimp-console"
}

@test "sprites split: -h prints the header" {
	run "$R/gamedev/sprites" -h
	[ "$status" -eq 0 ]
	[[ ${lines[0]} == "sprites - "* ]]
}

@test "sprites split: usage and missing file" {
	run "$R/gamedev/sprites" split
	[ "$status" -eq 2 ]
	run "$R/gamedev/sprites" split "$T/none.xcf"
	[ "$status" -eq 1 ]
}

@test "sprites split: sprites and the map (fake gimp)" {
	fake_gimp
	: > "$T/x.xcf"
	PATH=$T/bin:$PATH run "$R/gamedev/sprites" split -o "$T/out" "$T/x.xcf"
	[ "$status" -eq 0 ]
	[ -f "$T/out/00-head.png" ] && [ -f "$T/out/01-body.png" ]
	[ "$(cat "$T/out/layers.tsv")" = "$(printf '0\t00-head.png\thead\t4\t4\t16\t16\n1\t01-body.png\tbody\t20\t18\t10\t10')" ]
}

@test "sprites split: -t trims the border and moves the position by the trimmed amount" {
	fake_gimp
	: > "$T/x.xcf"
	PATH=$T/bin:$PATH run "$R/gamedev/sprites" split -t -o "$T/out" "$T/x.xcf"
	[ "$status" -eq 0 ]
	[ "$(magick identify -format '%wx%h' "$T/out/00-head.png")" = "8x8" ]
	[ "$(sed -n 1p "$T/out/layers.tsv")" = "$(printf '0\t00-head.png\thead\t8\t8\t8\t8')" ]
	[ "$(magick identify -format '%wx%h' "$T/out/01-body.png")" = "10x10" ]
}

@test "sprites split: default folder is named like the file" {
	fake_gimp
	: > "$T/hero.xcf"
	PATH=$T/bin:$PATH run "$R/gamedev/sprites" split "$T/hero.xcf"
	[ "$status" -eq 0 ]
	[ -f "$T/hero/layers.tsv" ]
}

@test "sprites split: a failing GIMP is an error" {
	fake_gimp
	: > "$T/x.xcf"
	FAKE_GIMP_FAIL=1 PATH=$T/bin:$PATH run "$R/gamedev/sprites" split -o "$T/out" "$T/x.xcf"
	[ "$status" -eq 1 ]
	[[ $output == *"could not export"* ]]
}

@test "split then grid: the pipeline (fake gimp)" {
	fake_gimp
	: > "$T/x.xcf"
	PATH=$T/bin:$PATH "$R/gamedev/sprites" split -t -o "$T/out" "$T/x.xcf"
	run "$R/gamedev/sprites" grid -o "$T/sheet.png" "$T"/out/*.png
	[ "$status" -eq 0 ]
	[ "$(magick identify -format '%wx%h' "$T/sheet.png")" = "20x10" ]
}

@test "sprites sheet: split and grid in one step, sprites stay next to the sheet (fake gimp)" {
	fake_gimp
	: > "$T/hero.xcf"
	PATH=$T/bin:$PATH run "$R/gamedev/sprites" sheet -t -p 1 "$T/hero.xcf"
	[ "$status" -eq 0 ]
	[ -f "$T/hero/layers.tsv" ] && [ -f "$T/hero.sheet.png" ] && [ -f "$T/hero.sheet.tsv" ]
	[ "$(magick identify -format '%wx%h' "$T/hero.sheet.png")" = "23x12" ]
	[ "$(wc -l < "$T/hero.sheet.tsv")" -eq 2 ]
}

@test "sprites: an unknown command and bad numbers are usage errors" {
	run "$R/gamedev/sprites" frob
	[ "$status" -eq 2 ]
	run "$R/gamedev/sprites" sheet -c x "$T/a.png"
	[ "$status" -eq 2 ]
	run "$R/gamedev/sprites" sheet "$T/none.xcf"
	[ "$status" -eq 1 ]
}

@test "sprites split: real GIMP 3 splits a two-layer file" {
	command -v gimp-console > /dev/null || { command -v flatpak > /dev/null && flatpak info org.gimp.GIMP > /dev/null 2>&1; } || skip "no GIMP 3"
	cat > "$T/mk.py" << EOF
import gi
gi.require_version('Gimp','3.0')
from gi.repository import Gimp, Gio
img = Gimp.Image.new(64, 48, Gimp.ImageBaseType.RGB)
for name, x, y in (("head", 4, 4), ("body", 20, 18)):
    l = Gimp.Layer.new(img, name, 16, 16, Gimp.ImageType.RGBA_IMAGE, 100, Gimp.LayerMode.NORMAL)
    img.insert_layer(l, None, 0)
    l.set_offsets(x, y)
    l.fill(Gimp.FillType.WHITE)
Gimp.file_save(Gimp.RunMode.NONINTERACTIVE, img, Gio.File.new_for_path("$T/two.xcf"), None)
EOF
	if command -v gimp-console > /dev/null; then g=(gimp-console); else g=(flatpak run --filesystem="$T" --command=gimp-console org.gimp.GIMP); fi
	"${g[@]}" -i --batch-interpreter=python-fu-eval -b "exec(open('$T/mk.py').read())" --quit > /dev/null 2>&1
	[ -f "$T/two.xcf" ]
	run "$R/gamedev/sprites" split -o "$T/out" "$T/two.xcf"
	[ "$status" -eq 0 ]
	[ "$(cat "$T/out/layers.tsv")" = "$(printf '0\t00-head.png\thead\t4\t4\t16\t16\n1\t01-body.png\tbody\t20\t18\t16\t16')" ]
}
