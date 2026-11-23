#!/bin/sh
# (c) 2026 CrystalGipsy, for LyrionPlay. MIT, as the app it tests.
#
# Planted bugs for the planted-bug runners' scratch dir guard (scripts/tests/scratch_guard.sh,
# /code-review 2026-11-23 (2) finding 1): each mutant is put into a COPY of the guard, beside copies of
# both runners, in a new temporary folder (removed at the end; the working tree is never touched);
# scripts/tests/test_scratch_guard.sh is run on that folder, and the mutant must make it FAIL. The
# unchanged copy must PASS first. The guard has two layers, and most paths need both to be broken, so
# each mutant turns one part off and the test must still see the hole it leaves.
# Prints one line per mutant and the tests that caught it; exits 0 only if every mutant was caught.
#   sh scripts/tests/mutants_scratch_guard.sh
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
WORK=$(mktemp -d) || exit 1
trap 'rm -rf "$WORK"' EXIT
mkdir "$WORK/src" "$WORK/orig" || exit 1
for f in scratch_guard.sh mutants_default_name.sh mutants_now_playing.sh; do
	cp "$ROOT/scripts/tests/$f" "$WORK/src/" || exit 1
done
cp "$WORK/src/scratch_guard.sh" "$WORK/orig/"
TEST=$ROOT/scripts/tests/test_scratch_guard.sh

out=$(sh "$TEST" "$WORK/src" 2>&1)
if ! printf '%s\n' "$out" | grep -q '^result: PASS$'; then
	echo "control: the unchanged guard does not pass the test"; printf '%s\n' "$out" | grep -A3 '^FAILED'; exit 1
fi
echo "control:  the unchanged guard passes"

# mutant <name> <old text> <new text> [<old text> <new text>]...: each an exact replacement, applied once
caught=0 total=0
mutant() {
	total=$((total + 1))
	name=$1
	shift
	cp "$WORK/orig/scratch_guard.sh" "$WORK/src/"
	if ! python3 -I -c '
import sys
p, pairs = sys.argv[1], sys.argv[2:]
s = open(p, encoding="utf-8").read()
for a, b in zip(pairs[::2], pairs[1::2]):
    assert s.count(a) == 1, "anchor: " + a
    s = s.replace(a, b)
open(p, "w", encoding="utf-8").write(s)' "$WORK/src/scratch_guard.sh" "$@"; then
		echo "MUTANT NOT APPLIED: $name"; return
	fi
	out=$(sh "$TEST" "$WORK/src" 2>&1)
	if printf '%s\n' "$out" | grep -q '^result: PASS$'; then
		echo "SURVIVED: $name"
	elif printf '%s\n' "$out" | grep -q '^FAILED'; then
		caught=$((caught + 1))
		echo "caught:   $name"
		printf '%s\n' "$out" | grep '^FAILED' | head -3 | sed 's/^FAILED /            /'
	else
		echo "NO RESULT: $name"; printf '%s\n' "$out" | tail -3
	fi
}

mutant "guard 2 off: a folder a runner did not make is deleted" \
	'if [ -L "$WORK/$_sg_f" ] || {' 'if false && {'
mutant "guard 1 off: the repo is never found, before or after the folders are made" \
	'	_sg_d=$1
	while :; do' '	return 1
	while :; do'
mutant "no check after the folders are made" \
	'if _sg_in_repo "$_sg_real" "$_sg_repo"; then' 'if false; then'
mutant "a refusal leaves the folders it made" \
	'rmdir "$_sg_d" 2>/dev/null' ':'
mutant "the repo compared as text, not as folders (needs a case-insensitive volume)" \
	'[ "$_sg_d" -ef "$2" ]' '[ "$_sg_d" = "$2" ]'
mutant "a .. allowed in the folders still to be made, made with mkdir -p" \
	'. | ..) _sg_refuse' '__none__) _sg_refuse' \
	'mkdir "$WORK" ||' 'mkdir -p "$WORK" ||'

echo "mutants: $caught of $total caught"
[ "$caught" -eq "$total" ]
