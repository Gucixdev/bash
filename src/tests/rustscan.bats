#!/usr/bin/env bats
# rustscan against a small Rust fixture with one known hit per rule.

setup() {
	cd "$BATS_TEST_DIRNAME/.." || return
	T=$BATS_TEST_TMPDIR
	mkdir -p "$T/r/src" "$T/r/tests" "$T/r/target"
	printf '[package]\nname="r"\n' > "$T/r/Cargo.toml"
	cat > "$T/r/src/lib.rs" <<'RS'
static mut COUNTER: u32 = 0;
pub fn f(x: Option<u8>, a: usize) -> u32 {
    let v = x.unwrap();
    // SAFETY: documented, so U6 stays quiet for this one
    let p = unsafe { COUNTER };
    let q = unsafe { COUNTER };
    let ptr = (a as usize) as *const u8;
    if v == 0 { panic!("zero"); }
    (v as u32) + p + q + ptr as u32
}
macro_rules! m { () => { unsafe { 1 } }; }
extern "C" { fn c(); }
RS
	printf 'fn t() { Some(1).unwrap(); unsafe { } }\n' > "$T/r/tests/it.rs"
	printf 'fn t() { Some(1).unwrap(); unsafe { } }\n' > "$T/r/target/x.rs"
}

@test "rustscan: counts each construct once, skips tests/ and target/" {
	run ./rustscan -o "$BATS_TEST_TMPDIR/o" "$T/r"
	[ "$status" -eq 0 ]
	[[ $output == *"r "*"hits"* ]]
	[[ $output == *U1=3* ]]   # two in lib.rs + the one inside macro_rules
	[[ $output == *U3=1* ]]
	[[ $output == *E1=1* ]]
	[[ $output == *E2=1* ]]
	[[ $output == *U6=2* ]]   # the macro one and the second block; the SAFETY one is quiet
	[[ $output == *M1=1* ]]
	[[ $output == *M3=1* ]]
	[[ $output == *F1=1* ]]
	[[ $output == *X3=1* ]]
	! grep -q 'tests/it.rs\|target/x.rs' "$T/o/r.tsv"
}

@test "rustscan: report rows carry rule, guideline id, file:line and the line" {
	./rustscan -o "$T/o" "$T/r" > /dev/null
	grep -qP "^M1\tgui_h0uG1C9ZjryA\t.*lib.rs:11\tmacro_rules" "$T/o/r.tsv"
}

@test "rustscan: a folder of repos is scanned one level down; a folder without any says so" {
	run ./rustscan -o "$T/o" "$T"
	[[ $output == *"r "*hits* ]]
	mkdir "$T/empty"
	run ./rustscan -o "$T/o" "$T/empty"
	[[ $output == *"no Cargo.toml"* ]]
}

@test "rustscan: -h prints the header, bad option exits 2" {
	run ./rustscan -h
	[[ $output == *"safety-critical scan"* ]]
	run ./rustscan -z
	[ "$status" -eq 2 ]
}
