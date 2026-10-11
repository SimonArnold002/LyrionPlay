#!/bin/sh
# The regression suite: every test this repo has, none of which touches an audio device, the
# installed app, the keychain or the LMS server.
#   engine conversion   every 24-bit sample through the Float32 the HAL gets (exhaustive)
#   engine output       output_coreaudio.c against a fake HAL, linked with upstream's own output.c,
#                       buffer.c, output_pack.c and dop.c (hog, rates, retries, volume both ways),
#                       and the scenario matrix: ~25,700 plays through LMS's strm commands, every
#                       frame the device gets checked (silence format, rate, order, delay, switches)
#   swift               PlayerCore: probe parsing, arguments, settings, menu lock, volume curve and
#                       pushes, following the macOS output, App Transport Security, the server
#                       choice and agent.log's LMS lines
#   install.sh          the installer in a sandbox with shimmed system tools
# Each suite is judged by its summary line AND its exit code; a suite that dies before its summary
# fails. Exits 0 only if every suite passed. scripts/build.sh runs it, and stops on a failure.
set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LOGS=$(mktemp -d)
trap 'rm -rf "$LOGS"' EXIT
results=""
bad=0

# $1 name, $2 the summary line's pattern for a pass, then the command
suite() {
	name=$1 pattern=$2
	shift 2
	echo "== $name"
	"$@" > "$LOGS/$name.log" 2>&1
	status=$?
	grep -E 'FAILED|✘|error:|result:|Test run with|tests, [0-9]+ passed|^conversion:' "$LOGS/$name.log" | grep -v 'search path' | sed 's/^/   /'
	if [ $status -eq 0 ] && grep -qE "$pattern" "$LOGS/$name.log"; then
		results="$results
PASS  $name"
	else
		bad=1
		summary=$(grep -E 'tests, [0-9]+ passed|Test run with|^conversion:' "$LOGS/$name.log" | tail -1)
		results="$results
FAIL  $name (exit $status, ${summary:-no summary line: it died first})"
		tail -20 "$LOGS/$name.log" | sed 's/^/   | /'
	fi
}

make -C "$ROOT/engine" -f Makefile.coreaudio tests/test_conversion tests/test_output_coreaudio > "$LOGS/make.log" 2>&1 ||
	{ cat "$LOGS/make.log"; echo "FAIL: the engine tests did not build"; exit 1; }

suite "engine conversion" '^result: PASS$' "$ROOT/engine/tests/test_conversion"
suite "engine output" '^result: PASS$' "$ROOT/engine/tests/test_output_coreaudio"
# Command Line Tools 27.0 (Swift 6.4): found by search, the Swift Testing macro plugin fails to load
# in about half the compiles ("plugin for module 'TestingMacros' not found"), even for a package
# with one test; named directly, 12 of 12 loaded (measured 2026-10-10). Xcode keeps it elsewhere.
TESTING_MACROS=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
set --
[ -f "$TESTING_MACROS" ] && set -- -Xswiftc -load-plugin-library -Xswiftc "$TESTING_MACROS"
suite "swift" 'Test run with [0-9]+ tests? in [0-9]+ suites? passed' swift test --package-path "$ROOT/app" "$@"
suite "install.sh" '^result: PASS$' sh "$ROOT/scripts/tests/test_install.sh"

echo "$results"
[ $bad -eq 0 ] && echo "regression suite: PASS" || echo "regression suite: FAIL"
exit $bad
