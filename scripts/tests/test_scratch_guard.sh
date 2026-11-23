#!/bin/sh
# (c) 2026 CrystalGipsy, for LyrionPlay. MIT, as the app it tests.
#
# Regression tests for the planted-bug runners' scratch dir guard (scripts/tests/scratch_guard.sh,
# /code-review 2026-11-22 (3) findings 3-4, 2026-11-23 finding 7, 2026-11-23 (2) finding 1: three
# rounds in a row found a path that got past it, the last one deleting the repo's app/). Both runners
# are copied into a fake repo in a new temporary folder and run on hostile scratch dirs:
#   - a refused dir must exit 2 and leave every file, folder and link in the temporary folder as it
#     was, the fake repo's app/ above all;
#   - an accepted dir must be made (if new) with a marked app/ and orig/, the repo untouched, and
#     nothing changed outside that dir.
# Nothing outside the temporary folder is used. The fake repo has no Package.swift, so an accepted
# run applies no mutant and starts no Swift build.
#
#   sh scripts/tests/test_scratch_guard.sh [runners dir]   (default: the repo's scripts/tests)
#
# The runners dir is for anti-runs: a folder holding older mutants_default_name.sh and/or
# mutants_now_playing.sh (and scratch_guard.sh if they source it); a runner missing there is skipped.
# Prints one line per test and a summary line; exits 0 only if every test passed.
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
SRC=$(cd "${1:-$ROOT/scripts/tests}" && pwd -P) || exit 1
T=$(mktemp -d) || exit 1
T=$(cd "$T" && pwd -P) || exit 1
trap 'cd /; rm -rf "$T"' EXIT
G=$T/GitHub
REPO=$G/Repo
PARENT_REPO=$G/Parent/app   # a repo that is itself named app: its parent's app/ IS the repo
RUNNERS=''
for r in mutants_default_name.sh mutants_now_playing.sh; do
	[ -f "$SRC/$r" ] && RUNNERS="$RUNNERS $r"
done
[ -n "$RUNNERS" ] || { echo "no runner in $SRC"; exit 1; }
passed=0 failed=0
ok() { passed=$((passed + 1)); echo "ok     $1"; }
bad() { failed=$((failed + 1)); echo "FAILED $1"; shift; for line in "$@"; do [ -n "$line" ] && printf '%s\n' "$line" | sed 's/^/    /'; done; }

# a fresh fake world for each test
fixture() {
	cd / || exit 1
	rm -rf "$G"
	mkdir -p "$REPO/app/Sources" "$REPO/scripts/tests" "$G/Other" "$G/Foreign/app" "$G/ForeignOrig/orig" \
		"$G/Reused/app" "$G/Reused/orig" "$G/Linked" "$PARENT_REPO/scripts/tests" || exit 1
	echo keep > "$REPO/app/KEEP"
	echo keep > "$PARENT_REPO/KEEP"
	echo own > "$G/Foreign/app/OWN"
	echo own > "$G/ForeignOrig/orig/OWN"
	: > "$G/Reused/app/.made-by-mutants"
	: > "$G/Reused/orig/.made-by-mutants"
	echo old > "$G/Reused/app/OLD"
	ln -s "$REPO/app" "$G/Linked/app"
	ln -s "$REPO" "$G/link-to-repo"
	ln -s "$REPO/app/made-later" "$G/dangling"
	: > "$G/afile"
	for f in $RUNNERS scratch_guard.sh; do
		if [ -f "$SRC/$f" ]; then cp "$SRC/$f" "$REPO/scripts/tests/" && cp "$SRC/$f" "$PARENT_REPO/scripts/tests/" || exit 1; fi
	done
}
snap() { (cd "$T" && find . | LC_ALL=C sort); }
intact() { [ "$(cat "$REPO/app/KEEP" 2>/dev/null)" = keep ] && [ "$(cat "$PARENT_REPO/KEEP" 2>/dev/null)" = keep ]; }
# the lines in one snapshot only
differ() { printf '%s\n%s\n' "$1" "$2" | LC_ALL=C sort | uniq -u; }

# refuse <runner> <run from> <scratch dir> <what> [repo]
refuse() {
	fixture
	before=$(snap)
	out=$(cd "$2" && sh "${5:-$REPO}/scripts/tests/$1" "$3" 2>&1)
	rc=$?
	after=$(snap)
	if [ $rc -eq 2 ] && [ "$before" = "$after" ] && intact; then
		ok "$1 refuses $4"
	else
		bad "$1 refuses $4" "exit $rc (want 2); the repo's files $(intact && echo intact || echo GONE)" \
			"$(differ "$before" "$after" | head -6 | sed 's/^/changed: /')" "$(printf '%s\n' "$out" | head -4)"
	fi
}

# accept <runner> <run from> <scratch dir> <the folder it must use> <what>
accept() {
	fixture
	before=$(snap)
	out=$(cd "$2" && sh "$REPO/scripts/tests/$1" "$3" 2>&1)
	rc=$?
	after=$(snap)
	rel=.${4#"$T"}
	# changed outside the dir it must use, or above it on the way there (the leading "(" of each
	# pattern: bash 3.2, macOS's /bin/sh, reads a bare ")" in $( ) as its end)
	stray=$(differ "$before" "$after" | while IFS= read -r l; do
		case $rel in ("$l" | "$l"/*) continue ;; esac
		case $l in ("$rel"/*) continue ;; esac
		echo "$l"
	done)
	if [ $rc -ne 2 ] && intact && [ -f "$4/app/.made-by-mutants" ] && [ -f "$4/orig/.made-by-mutants" ] &&
		[ ! -e "$4/app/OLD" ] && [ -z "$stray" ]; then
		ok "$1 uses $5"
	else
		bad "$1 uses $5" "exit $rc; the repo's files $(intact && echo intact || echo GONE); marked app/: $([ -f "$4/app/.made-by-mutants" ] && echo yes || echo no)" \
			"$(printf '%s\n' "$stray" | head -6 | sed 's/^/changed outside: /')" "$(printf '%s\n' "$out" | grep -v 'MUTANT NOT APPLIED' | head -4)"
	fi
}

fixture
for r in $RUNNERS; do
	refuse "$r" "$G" "$REPO" "the repo"
	if [ -d "$G/REPO" ]; then
		refuse "$r" "$G" "$G/REPO" "the repo typed in capitals"
		# no app/ there to stop it: only comparing folders (-ef), not text, refuses this one
		refuse "$r" "$G" "$G/REPO/new/deeper" "new folders in the repo typed in capitals"
	else echo "skip   $r: the repo typed in capitals (this volume is case-sensitive)"; fi
	refuse "$r" "$G" "$REPO/app" "a folder in the repo"
	refuse "$r" "$G" "$REPO/app/new/deeper" "new folders in the repo"
	refuse "$r" "$G" "$G/missing/../Repo" "the repo by a .. after a folder not made yet (/code-review 2026-11-23 (2) finding 1)"
	refuse "$r" "$G" "$G/missing/deeper/../../Repo" "the repo by two .. after folders not made yet"
	refuse "$r" "$G" "missing/../Repo" "the repo by a relative .. after a folder not made yet"
	refuse "$r" "$G" "$G/missing/.." "a .. after a folder not made yet, even where it lands outside the repo"
	refuse "$r" "$G" "$G/Other/../Repo" "the repo by a .. after a folder that exists"
	refuse "$r" "$G" "$G/link-to-repo" "a link to the repo"
	refuse "$r" "$G" "$G/link-to-repo/new" "a new folder under a link to the repo"
	refuse "$r" "$G" "$G/dangling" "a link to a folder not yet made in the repo"
	refuse "$r" "$G" "$G/dangling/new" "a new folder under a link to a folder not yet made in the repo"
	refuse "$r" "$G" "$G/afile/new" "a path through a file"
	refuse "$r" "$G" "" "an empty scratch dir"
	refuse "$r" "$REPO" "new" "a relative new folder, run from inside the repo"
	refuse "$r" "$REPO" "." "the current folder, run from the repo"
	refuse "$r" "$G" "$G/Foreign" "a scratch dir whose app/ a runner did not make"
	refuse "$r" "$G" "$G/ForeignOrig" "a scratch dir whose orig/ a runner did not make"
	refuse "$r" "$G" "$G/Linked" "a scratch dir whose app/ is a link into the repo"
	refuse "$r" "$G" "$G/Parent" "the folder holding a repo named app" "$PARENT_REPO"
	refuse "$r" "$G" "$G/new
line" "a scratch dir with a line break in it"

	accept "$r" "$G" "$G/Other" "$G/Other" "an empty folder outside the repo"
	accept "$r" "$G" "$G/Other/" "$G/Other" "a folder outside the repo, with a trailing /"
	accept "$r" "$G" "$G/new1/new2" "$G/new1/new2" "new folders outside the repo"
	accept "$r" "$G" "$G/Reused" "$G/Reused" "a scratch dir a runner used before, its old copy replaced"
	accept "$r" "$REPO" "../Other2/new" "$G/Other2/new" "a relative path out of the repo"
	accept "$r" "$G" "$REPO/../Other" "$G/Other" "a .. out of the repo after folders that exist"
	accept "$r" "$G" "$G/with space/new" "$G/with space/new" "a path with a space"
	accept "$r" "$G" "-x" "$G/-x" "a relative name starting with -"

	# no scratch dir: a temporary folder of its own, nothing here touched
	fixture
	before=$(snap)
	out=$(cd "$G" && sh "$REPO/scripts/tests/$r" 2>&1)
	rc=$?
	if [ $rc -ne 2 ] && intact && [ "$before" = "$(snap)" ]; then ok "$r with no scratch dir touches nothing here"
	else bad "$r with no scratch dir touches nothing here" "exit $rc" "$(printf '%s\n' "$out" | head -4)"; fi
done

# the guard itself, for what a path alone cannot make happen
if [ -f "$SRC/scratch_guard.sh" ]; then
	# a folder swapped for a link to the repo between its mkdir and the check after it: scratch_dir
	# alone, without remake, whose mark check (guard 2) would stop the runner here anyway
	fixture
	out=$(cd "$G" && (
		. "$SRC/scratch_guard.sh"
		mkdir() { command mkdir "$@" || return; if [ "$1" = "$G/new" ]; then rmdir "$1" && ln -s "$REPO" "$1"; fi; }
		scratch_dir "$REPO" "$G/new"
		echo "accepted: WORK=$WORK"
	) 2>&1)
	rc=$?
	if [ $rc -eq 2 ] && intact; then
		ok "scratch_dir refuses a new folder swapped for a link to the repo after it is made"
	else bad "scratch_dir refuses a new folder swapped for a link to the repo after it is made" "exit $rc" "$out"; fi

	# a refusal after the folders were made removes them, and only them
	fixture
	before=$(snap)
	out=$(cd "$G" && (
		. "$SRC/scratch_guard.sh"
		cd() { [ "$1" = "$G/a/b" ] && return 1; command cd "$@"; }
		scratch_dir "$REPO" "$G/a/b"
	) 2>&1)
	rc=$?
	if [ $rc -eq 2 ] && [ "$before" = "$(snap)" ]; then ok "a refusal after making folders removes them, and only them"
	else bad "a refusal after making folders removes them, and only them" "exit $rc" "$out"; fi
else
	echo "skip   the guard's own tests: no scratch_guard.sh in $SRC"
fi

echo "scratch guard: $((passed + failed)) tests, $passed passed, $failed failed"
[ $failed -eq 0 ] && echo "result: PASS" || echo "result: FAIL"
[ $failed -eq 0 ]
