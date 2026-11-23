#!/bin/sh
# (c) 2026 CrystalGipsy, for LyrionPlay. GNU General Public License v3 or later, as the engine it tests.
#
# Planted bugs for pcm.c's header walk (/code-review 2026-11-22 (3) finding 5): each mutant is put into
# a COPY of pcm.c in a new temporary folder (removed at the end; the working tree is never touched), the
# pcm header suite is built against it (`-DPCM_SOURCE`, the suite's anti-run hook, with the Makefile's
# own compile line) and run, and the mutant must make it FAIL. An unchanged copy must PASS first.
# Prints one line per mutant and the tests that caught it; exits 0 only if every mutant was caught. A
# mutant that makes the walk endless costs the suite's 10 s alarm for each test that catches it.
#   sh scripts/tests/mutants_pcm_header.sh
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT
cd "$ROOT/engine" || exit 1

# the Makefile's compile line for the suite, built against $WORK/pcm.c into $WORK
BUILD=$(make -n -B -f Makefile.coreaudio tests/test_pcm_header | tr '\n\t' '  ' | sed 's/\\//g')
case "$BUILD" in
	*"-o tests/test_pcm_header "*) ;;
	*) echo "the Makefile's compile line was not understood: $BUILD"; exit 1 ;;
esac
BUILD=$(printf '%s' "$BUILD" | sed "s|-o tests/test_pcm_header |-DPCM_SOURCE='\"$WORK/pcm.c\"' -o $WORK/test_pcm_header |")

# run <name>: build the suite against $WORK/pcm.c and run it; sets $out, returns 0 on PASS, 1 on a
# failure, 2 if it did not build
run() {
	if ! sh -c "$BUILD" > "$WORK/build.log" 2>&1; then
		echo "NO RESULT (build failed): $1"; grep -m3 'error:' "$WORK/build.log"; return 2
	fi
	out=$("$WORK/test_pcm_header" 2>&1)
	printf '%s\n' "$out" | grep -q '^result: PASS$'
}

cp pcm.c "$WORK/pcm.c"
if ! run "control"; then
	echo "control: the unchanged pcm.c does not pass the suite"; printf '%s\n' "$out" | grep '✘'; exit 1
fi

# mutant <name> <old text> <new text>: one exact replacement, which must apply once
caught=0 total=0
mutant() {
	total=$((total + 1))
	cp pcm.c "$WORK/pcm.c"
	if ! python3 -I -c 'import sys; p, a, b = sys.argv[1:]; s = open(p, encoding="latin-1").read(); assert s.count(a) == 1, "anchor"; open(p, "w", encoding="latin-1").write(s.replace(a, b))' "$WORK/pcm.c" "$2" "$3"; then
		echo "MUTANT NOT APPLIED: $1"; return
	fi
	run "$1"
	case $? in
		0) echo "SURVIVED: $1" ;;
		1) caught=$((caught + 1)); echo "caught:   $1"; printf '%s\n' "$out" | grep '✘' | sed 's/^/            /' ;;
	esac
}

mutant "the step counted in 32 bits (upstream's arithmetic)" \
	'u64_t skip = (u64_t)len + 8 + (len & 1);' 'unsigned skip = len + 8 + (len & 1);'
mutant "the step widened only after len + 8 has wrapped" \
	'u64_t skip = (u64_t)len + 8 + (len & 1);' 'u64_t skip = (u64_t)(len + 8) + (len & 1);'
mutant "no pad byte after an odd-sized chunk (/code-review 2026-11-22 finding 2)" \
	'u64_t skip = (u64_t)len + 8 + (len & 1);' 'u64_t skip = (u64_t)len + 8;'
mutant "the encoding read from a COMM too short to hold it (no len >= 22)" \
	'if (aifc && len >= 22 && bytes >= 30 && ' 'if (aifc && bytes >= 30 && '
mutant "the encoding read past the bytes that have arrived (no bytes >= 30)" \
	'if (aifc && len >= 22 && bytes >= 30 && ' 'if (aifc && len >= 22 && '

echo "mutants: $caught of $total caught"
[ "$caught" -eq "$total" ]
