#!/bin/sh
# (c) 2026 CrystalGipsy, for LyrionPlay. MIT, as the app it tests.
#
# Planted bugs for Now Playing (/code-review 2026-11-22 (4) findings 1, 3, 4, 6 and 7): each mutant is
# put into a COPY of the Swift package (the working tree is never touched), the Now Playing tests are
# run on it, and the mutant must make them FAIL. The first two put back the code before the round
# (anti-runs); the rest break the new rules. Prints one line per mutant, the test lines that caught
# it, and exits 0 only if every mutant was caught.
#   sh scripts/tests/mutants_now_playing.sh [scratch dir]
# The copy goes in `app` and `orig` folders made afresh in the scratch dir. With no scratch dir a new
# temporary folder is used and removed at the end, the copy and its Swift build with it; a scratch
# dir given is kept (its copy is made afresh each run). The guard is scripts/tests/scratch_guard.sh, shared with
# mutants_default_name.sh and tested in the regression suite: a scratch dir in the repo is refused,
# and only folders a runner made are deleted (/code-review 2026-11-23 finding 7, 2026-11-23 (2)
# finding 1).
set -u
ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
. "$ROOT/scripts/tests/scratch_guard.sh"
if [ $# -ge 1 ]; then scratch_dir "$ROOT" "$1"; else scratch_dir "$ROOT"; fi
remake app orig
cp -R "$ROOT/app/Package.swift" "$ROOT/app/Sources" "$ROOT/app/Tests" "$WORK/app/"
CORE="$WORK/app/Sources/PlayerCore"
cp "$CORE/NowPlaying.swift" "$CORE/LMSFeed.swift" "$WORK/orig/"
MACROS=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
XFLAGS=""   # the path has no spaces: used unquoted, as words
[ -f "$MACROS" ] && XFLAGS="-Xswiftc -load-plugin-library -Xswiftc $MACROS"
FILTER='NowPlaying'

restore() { cp "$WORK/orig/NowPlaying.swift" "$WORK/orig/LMSFeed.swift" "$CORE/"; }

# mutant <name> <file in PlayerCore> <old text> <new text>: one exact replacement, which must apply once
caught=0 total=0
mutant() {
	total=$((total + 1))
	restore
	if ! python3 -I -c 'import sys; p, a, b = sys.argv[1:]; s = open(p, encoding="utf-8").read(); assert s.count(a) == 1, "anchor"; open(p, "w", encoding="utf-8").write(s.replace(a, b))' "$CORE/$2" "$3" "$4"; then
		echo "MUTANT NOT APPLIED: $1"; return
	fi
	out=$(swift test --package-path "$WORK/app" --filter "$FILTER" $XFLAGS 2>&1)
	if printf '%s\n' "$out" | grep -qE 'Test run with [0-9]+ tests? in [0-9]+ suites? passed'; then
		echo "SURVIVED: $1"
	elif printf '%s\n' "$out" | grep -q 'recorded an issue'; then
		caught=$((caught + 1))
		echo "caught:   $1"
		printf '%s\n' "$out" | grep -oE 'NowPlayingTests\.swift:[0-9]+' | sort -u -t: -k2 -n | sed 's/^/            /'
	else
		echo "NO RESULT (build failed?): $1"; printf '%s\n' "$out" | grep -m3 'error:'
	fi
}

mutant "anti-run, finding 3: a cancelled feed hands on its last poll" LMSFeed.swift \
	'guard !Task.isCancelled else { return }' ''
mutant "anti-run, finding 6: a station sent as its title is the album too" NowPlaying.swift \
	'(status.title == nil || status.title == status.station ? nil : status.station)' \
	'(status.title == nil ? nil : status.station)'
mutant "finding 1: no server reported stops the running one" NowPlaying.swift \
	'return reported ?? running' 'return reported'
mutant "finding 7: a feed with no Player that could fill the slot" NowPlaying.swift \
	'guard !candidates.isEmpty else { return nil }' ''
mutant "finding 7: a chosen Player switched off does not stop the feed" NowPlaying.swift \
	'candidates = candidates.filter { $0.key == key }' '_ = key'
mutant "finding 4: a disconnect sends nothing" LMSFeed.swift \
	'_ = try? await send([["channel": "/meta/disconnect", "clientId": clientID]], timeout: Self.disconnectWait)' \
	'_ = clientID'
mutant "finding 4: a disconnect keeps the client ID, so it is sent again" LMSFeed.swift \
	'guard let clientID else { return }' 'guard let clientID else { return }; defer { self.clientID = clientID }'

restore
echo "mutants: $caught of $total caught"
[ "$caught" -eq "$total" ]
