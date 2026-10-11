#!/bin/sh
# Regression tests for scripts/install.sh, run in a sandbox: HOME and the install folder are in a
# temp directory, and every tool that could reach the real player, keychain or Finder (launchctl,
# open, lsof, ps, codesign, security, xattr) is a shim that records what it was asked. Nothing on
# this Mac is changed; the script refuses to run if a shim would be bypassed.
#
#   sh scripts/tests/test_install.sh [install.sh]   (default: the repo's)
#
# Prints one line per test and a summary line; exits 0 only if every test passed.
set -u

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
INSTALL="${1:-$ROOT/scripts/install.sh}"
passed=0
failed=0

ok() { passed=$((passed + 1)); echo "ok     $1"; }
bad() { failed=$((failed + 1)); echo "FAILED $1"; shift; for line in "$@"; do echo "    $line"; done; }

# sandbox: a fake app (version 9.9.9) and shims; $1 = cdhash the shim codesign reports
sandbox() {
	T=$(mktemp -d)
	mkdir -p "$T/home/Library/Application Support/LyrionPlay" "$T/Applications" "$T/bin" "$T/src/LyrionPlay.app/Contents/MacOS"
	for exe in LyrionPlay lyrionplay-agent squeezelite; do
		printf '#!/bin/sh\n' > "$T/src/LyrionPlay.app/Contents/MacOS/$exe"
		chmod +x "$T/src/LyrionPlay.app/Contents/MacOS/$exe"
	done
	cat > "$T/src/LyrionPlay.app/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>9.9.9</string></dict></plist>
EOF
	MARKER="$T/home/Library/Application Support/LyrionPlay/menu-session-ending"
	# an older copy is installed, and its menu is running
	ditto "$T/src/LyrionPlay.app" "$T/Applications/LyrionPlay.app"
	# detached, as the real menu is not install.sh's child: launchd reaps it when it is killed
	( sleep 60 > /dev/null 2>&1 & echo $! > "$T/menu.pid" )
	MENU_PID=$(cat "$T/menu.pid")
	shim security 'case "$1" in find-identity) echo "  1) 0123456789ABCDEF0123456789ABCDEF01234567 \"LyrionPlay Signing\"" ;; esac'
	shim codesign "case \"\$*\" in *-dvvv*) echo 'CDHash=$1' >&2 ;; esac"
	shim xattr ':'
	shim launchctl 'echo "launchctl $*" >> "$T/calls"; [ "$1" = print ] && exit 0; exit 0'
	shim lsof 'cat "$T/menu.pid"'
	# the menu is enumerated here: record whether the agent was already being held off
	shim ps '[ -e "$MARKER" ] && echo "marker at enumeration: yes" >> "$T/calls" || echo "marker at enumeration: no" >> "$T/calls"; echo "/Applications/LyrionPlay.app/Contents/MacOS/LyrionPlay"'
	shim open 'echo "open $*" >> "$T/calls"'
	: > "$T/calls"
}

shim() {
	printf '#!/bin/sh\nT="%s"\nMARKER="%s"\n%s\n' "$T" "$MARKER" "$2" > "$T/bin/$1"
	chmod +x "$T/bin/$1"
}

run_install() {
	for tool in launchctl open lsof ps codesign security xattr; do
		[ "$(PATH="$T/bin:$PATH" command -v $tool)" = "$T/bin/$tool" ] || { echo "a shim for $tool would be bypassed: refusing" >&2; exit 2; }
	done
	HOME="$T/home" PATH="$T/bin:$PATH" LYRIONPLAY_DEST="$T/Applications" LYRIONPLAY_KEYCHAIN="$T/none" \
		LYRIONPLAY_NO_START="${NO_START:-0}" sh "$INSTALL" "$T/src/LyrionPlay.app" > "$T/out" 2>&1
}

cleanup() {
	kill "$MENU_PID" 2>/dev/null
	rm -rf "$T"
}

# LYRIONPLAY review 2026-10-10, finding 9: with the player unchanged it keeps running, and its
# 2 s check reopened a missing menu: between the kill and the swap that was the OLD copy, which
# the final `open` then only brought to the front.
sandbox same
run_install; status=$?
if [ $status -eq 0 ] && grep -q "marker at enumeration: yes" "$T/calls" && ! kill -0 "$MENU_PID" 2>/dev/null &&
	grep -q "^open $T/Applications/LyrionPlay.app$" "$T/calls" && [ ! -d "$T/Applications/.LyrionPlay-installing.app" ] &&
	grep -q "player is unchanged" "$T/out" && ! grep -q "launchctl bootout" "$T/calls"; then
	ok "player unchanged: the agent is held off before the menu is replaced"
else
	bad "player unchanged: the agent is held off before the menu is replaced" "exit $status" "$(cat "$T/calls")" "$(tail -5 "$T/out")"
fi
cleanup

# control: a changed player is stopped first, so it cannot reopen anything; the menu is replaced
sandbox changed
shim codesign 'case "$*" in *-dvvv*Applications/LyrionPlay.app*) echo "CDHash=old" >&2 ;; *-dvvv*) echo "CDHash=new" >&2 ;; esac'
run_install; status=$?
if [ $status -eq 0 ] && grep -q "launchctl bootout" "$T/calls" && ! kill -0 "$MENU_PID" 2>/dev/null &&
	grep -q "^open $T/Applications/LyrionPlay.app$" "$T/calls"; then
	ok "player changed: stopped, menu replaced, new copy opened"
else
	bad "player changed: stopped, menu replaced, new copy opened" "exit $status" "$(cat "$T/calls")" "$(tail -5 "$T/out")"
fi
cleanup

# LYRIONPLAY_NO_START=1 (tests, packaging): nothing is stopped, killed, opened or held off
sandbox same
NO_START=1 run_install; status=$?
if [ $status -eq 0 ] && [ ! -e "$MARKER" ] && kill -0 "$MENU_PID" 2>/dev/null && ! grep -q "^open\|bootout" "$T/calls"; then
	ok "LYRIONPLAY_NO_START=1 leaves the player and the menu alone"
else
	bad "LYRIONPLAY_NO_START=1 leaves the player and the menu alone" "exit $status" "$(cat "$T/calls")"
fi
cleanup

echo "install.sh: $((passed + failed)) tests, $passed passed, $failed failed"
[ $failed -eq 0 ] && echo "result: PASS" || echo "result: FAIL"
[ $failed -eq 0 ]
