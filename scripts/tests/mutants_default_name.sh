#!/bin/sh
# (c) 2026 CrystalGipsy, for LyrionPlay. MIT, as the app it tests.
#
# Planted bugs for `PlayerSettings.defaultName` (/code-review 2026-11-22 (2) findings 1 and 6): each
# mutant is put into a COPY of the Swift package (the working tree is never touched), the name tests
# are run on it, and the mutant must make them FAIL. Prints one line per mutant, the test lines that
# caught it, and exits 0 only if every mutant was caught.
#   sh scripts/tests/mutants_default_name.sh [scratch dir]
# The copy goes in `app` and `orig` folders made afresh in the scratch dir. With no scratch dir a new
# temporary folder is used and removed at the end, the copy and its Swift build (~600 MB) with it; a
# scratch dir given is kept (its copy is made afresh each run). The guard is scripts/tests/scratch_guard.sh, shared
# with mutants_now_playing.sh and tested in the regression suite: a scratch dir in the repo is
# refused, and only folders a runner made are deleted (/code-review 2026-11-22 (3) findings 3 and 4,
# 2026-11-23 finding 7, 2026-11-23 (2) finding 1).
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
. "$ROOT/scripts/tests/scratch_guard.sh"
if [ $# -ge 1 ]; then scratch_dir "$ROOT" "$1"; else scratch_dir "$ROOT"; fi
remake app orig
cp -R "$ROOT/app/Package.swift" "$ROOT/app/Sources" "$ROOT/app/Tests" "$WORK/app/"
FILE="$WORK/app/Sources/PlayerCore/Settings.swift"
cp "$FILE" "$WORK/orig/Settings.swift"
MACROS=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
XFLAGS=""   # the path has no spaces: used unquoted, as words
[ -f "$MACROS" ] && XFLAGS="-Xswiftc -load-plugin-library -Xswiftc $MACROS"
FILTER='aDefaultNameLMSCanSendBack|theOfferedNameIsOneLMSCanSendBack|defaults'

# mutant <name> <old text> <new text>: one exact replacement, which must apply once
caught=0 total=0
mutant() {
	total=$((total + 1))
	cp "$WORK/orig/Settings.swift" "$FILE"
	if ! python3 -I -c 'import sys; p, a, b = sys.argv[1:]; s = open(p, encoding="utf-8").read(); assert s.count(a) == 1, "anchor"; open(p, "w", encoding="utf-8").write(s.replace(a, b))' "$FILE" "$2" "$3"; then
		echo "MUTANT NOT APPLIED: $1"; return
	fi
	out=$(swift test --package-path "$WORK/app" --filter "$FILTER" $XFLAGS 2>&1)
	if printf '%s\n' "$out" | grep -qE 'Test run with [0-9]+ tests? in [0-9]+ suites? passed'; then
		echo "SURVIVED: $1"
	elif printf '%s\n' "$out" | grep -q 'recorded an issue'; then
		caught=$((caught + 1))
		echo "caught:   $1"
		printf '%s\n' "$out" | grep -oE 'PlayerCoreTests\.swift:[0-9]+' | sort -u -t: -k2 -n | sed 's/^/            /'
	else
		echo "NO RESULT (build failed?): $1"; printf '%s\n' "$out" | grep -m3 'error:'
	fi
}

mutant "no NFC: a separate accent stays a mark" \
	'name.precomposedStringWithCanonicalMapping' 'name'
mutant "the old rule: any letter outside the Latin Extended ranges sets a run apart" \
	'let apart = run.range(of: "[\\p{L}--\\p{Script=Latin}]", options: .regularExpression) != nil' \
	'let apart = run.unicodeScalars.contains { $0.properties.isAlphabetic && !(0x100...0x24F ~= $0.value || 0x1E00...0x1EFF ~= $0.value) }'
mutant "no ʼ (U+02BC) mapping" \
	'["\u{2019}", "\u{2018}", "\u{02BC}"]' '["\u{2019}", "\u{2018}"]'
mutant "every default name lowercased (seen only by checks that do not go through defaultName)" \
	'return fitted.isEmpty ? "Mac" : fitted' 'return fitted.isEmpty ? "Mac" : fitted.lowercased()'

cp "$WORK/orig/Settings.swift" "$FILE"
echo "mutants: $caught of $total caught"
[ "$caught" -eq "$total" ]
