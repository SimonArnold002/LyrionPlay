#!/bin/sh
# Builds build/LyrionPlay.app: codec libraries (skipped when built) -> engine -> Swift agent and
# menu bar app -> icon -> bundle -> ad-hoc signature, then checks the result.
#   scripts/build.sh            build and check
#   scripts/build.sh --install  then install it with scripts/install.sh, signed with your own
#                               certificate, exactly as a user installs a release
#   scripts/build.sh --release  then make dist/LyrionPlay-<version>.zip: the app, install.sh,
#                               uninstall.sh, INSTALL.md and INSTALL.html; and
#                               dist/LyrionPlay-<version>-codec-sources.zip, the codec libraries'
#                               source, which the GPL asks to go out with the app
# Every user signs LyrionPlay with their own certificate (INSTALL.md), so the build itself is
# only signed ad-hoc: Apple Silicon runs nothing unsigned, and install.sh re-signs it.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
NAME=LyrionPlay
VERSION=$(cat "$ROOT/VERSION") # the one place the version is set; the docs pages read it too
BUILD=$(date +%Y%m%d%H%M) # bumped every build
APP="$ROOT/build/$NAME.app"
BUNDLE_ID=com.crystalgipsy.lyrionplay
JOBS=$(sysctl -n hw.ncpu)
DEPS="$ROOT/deps/src"
MODE="${1:-}"
case "$MODE" in "" | --install | --release) ;; *) echo "usage: $0 [--install | --release]" >&2; exit 2 ;; esac

echo "== codec libraries"
"$ROOT/deps/build-cmake.sh"
# Into a log, then its tail: piped into tail, the status was tail's, so a codec build that failed (an
# archive changed, a download or a compile failed) carried on and linked what an earlier build left
# in deps/out (/code-review 2026-10-12 (5), finding 1). Not `pipefail`: dash, which /bin/sh can be,
# lacks it.
mkdir -p "$ROOT/build"
DEPS_LOG="$ROOT/build/build-deps.log"
"$ROOT/deps/build-deps.sh" > "$DEPS_LOG" || {
	tail -15 "$DEPS_LOG"
	echo "FAIL: deps/build-deps.sh stopped (its output: $DEPS_LOG)" >&2
	exit 1
}
tail -15 "$DEPS_LOG"

# --release: the codec libraries' source goes out with the app (A RELEASE CARRIES ITS SOURCE in the
# repo's CLAUDE.md). Each archive build-deps.sh fetches, with the SHA-256 on the line after its fetch,
# read from it so a version change there cannot go stale here: "<sha256>  <archive>" lines.
codec_pins() {
	alac=$(sed -n 's/^ALAC_COMMIT=//p' "$ROOT/deps/build-deps.sh")
	awk '/^fetch /{ f = $2; next } f && /^\t[0-9a-f]{64}$/{ sub(/^\t/, ""); print $0 "  " f } { f = "" }' \
		"$ROOT/deps/build-deps.sh" | sed "s/\$ALAC_COMMIT/$alac/"
}
# stops unless the folder holds every archive build-deps.sh fetches, each matching its SHA-256.
# build-deps.sh checks an archive only when it builds that library, and skips one already built, so
# an archive changed since would otherwise ship as the source of a build it was not part of.
check_codec_sources() { # folder
	[ "$(grep -c '^fetch ' "$ROOT/deps/build-deps.sh")" -eq 9 ] && [ "$(echo "$PINS" | wc -l)" -eq 9 ] || {
		echo "build-deps.sh fetches other than the 9 codec archives, each with its SHA-256 on the next line:" $ARCHIVES >&2
		exit 1
	}
	for archive in $ARCHIVES; do
		[ -s "$1/$archive" ] || { echo "missing codec source: $1/$archive" >&2; exit 1; }
	done
	(cd "$1" && echo "$PINS" | shasum -a 256 -c -q -) || {
		echo "a codec source in $1 differs from the SHA-256 deps/build-deps.sh pins (above)" >&2
		exit 1
	}
}
if [ "$MODE" = --release ]; then
	# here, straight after the codec build (whose fetch brings the archives on a fresh checkout) and
	# before anything else is built or zipped: it used to run after the app's zip was made, so a
	# failure left that zip, naming a codec-sources zip never made (/code-review 2026-10-12 (5), finding 2)
	echo "== codec sources"
	PINS=$(codec_pins)
	ARCHIVES=$(echo "$PINS" | awk '{ print $2 }')
	check_codec_sources "$DEPS"
fi

echo "== engine"
make -C "$ROOT/engine" -f Makefile.coreaudio -j"$JOBS" >/dev/null

echo "== agent and app"
swift build --package-path "$ROOT/app" -c release --arch arm64
BIN=$(swift build --package-path "$ROOT/app" -c release --arch arm64 --show-bin-path)

echo "== regression suite"
# stops the build on any failure (it used to print swift test's result and carry on)
sh "$ROOT/scripts/test.sh"

echo "== icon"
# one source, app/Resources/LyrionPlay.svg: the menu bar draws it, and the app icon is rendered from it
mkdir -p "$ROOT/build/tools"
MAKE_ICON="$ROOT/build/tools/make-icon"
if [ ! -x "$MAKE_ICON" ] || [ "$ROOT/tools/icon/make-icon.swift" -nt "$MAKE_ICON" ]; then
	# swiftc's own status: through `| grep … || true`, a failed compile went on with an older make-icon
	swiftc -O "$ROOT/tools/icon/make-icon.swift" -o "$MAKE_ICON" > "$MAKE_ICON.log" 2>&1 || {
		cat "$MAKE_ICON.log" >&2
		rm -f "$MAKE_ICON" # so the next build compiles it again
		echo "FAIL: make-icon did not compile" >&2
		exit 1
	}
	grep -v 'search path' "$MAKE_ICON.log" || true
fi
"$MAKE_ICON" "$ROOT/app/Resources/$NAME.svg" "$ROOT/build/AppIcon.iconset"

echo "== bundle $VERSION ($BUILD)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" "$ROOT/app/Resources/Info.plist" > "$APP/Contents/Info.plist"
cp "$BIN/App" "$APP/Contents/MacOS/$NAME"
cp "$BIN/Agent" "$APP/Contents/MacOS/lyrionplay-agent"
cp "$ROOT/engine/squeezelite" "$APP/Contents/MacOS/squeezelite"
iconutil -c icns "$ROOT/build/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/app/Resources/$NAME.svg" "$APP/Contents/Resources/"
# NOTICES.txt names this version's source tag and codec-sources zip
sed "s/<version>/$VERSION/g" "$ROOT/app/Resources/NOTICES.txt" > "$APP/Contents/Resources/NOTICES.txt"
# the full licence text of everything in the app (NOTICES.txt lists them): BSD, MIT and Apache ask a
# binary release to carry it. The codecs' texts come from their sources, which deps/build-deps.sh keeps
# in deps/src; the GPLv3 text squeezelite's names and the icon's two are kept in app/Resources/licences.
LICENCES="$APP/Contents/Resources/licences"
mkdir -p "$LICENCES"
licence() { # name source...: the sources, in order, as one text; a missing or empty one stops the build
	name=$1
	shift
	for src in "$@"; do
		[ -s "$src" ] || { echo "missing licence text: $src" >&2; exit 1; }
	done
	cat "$@" > "$LICENCES/$name"
}
licence LyrionPlay.txt "$ROOT/LICENSE"
licence squeezelite.txt "$ROOT/engine/LICENSE.txt"
licence GPL-3.0.txt "$ROOT/app/Resources/licences/GPL-3.0.txt"
licence dsd2pcm.txt "$ROOT/engine/dsd2pcm/LICENSE.txt"
licence FLAC.txt "$DEPS/flac/COPYING.Xiph"
licence libogg.txt "$DEPS/ogg/COPYING"
licence libvorbis.txt "$DEPS/vorbis/COPYING"
licence Opus.txt "$DEPS/opus/COPYING"
licence opusfile.txt "$DEPS/opusfile/COPYING"
licence mpg123.txt "$DEPS/mpg123/COPYING"
licence FAAD2.txt "$DEPS/faad2/COPYING"
licence soxr.txt "$DEPS/soxr/LICENCE" "$DEPS/soxr/COPYING.LGPL" # its notice, then the LGPL it names
licence ALAC.txt "$DEPS/alac/LICENSE"
licence MaterialSymbols.txt "$ROOT/app/Resources/licences/MaterialSymbols.txt"
licence LMS-Material.txt "$ROOT/app/Resources/licences/LMS-Material.txt"

echo "== sign ad-hoc"
# inside-out: nested executables first, then the bundle (which signs the menu app)
for exe in squeezelite lyrionplay-agent; do
	codesign --force --options runtime --timestamp=none -s - -i "$BUNDLE_ID.$exe" "$APP/Contents/MacOS/$exe"
done
codesign --force --options runtime --timestamp=none -s - "$APP"

echo "== checks"
codesign --verify --strict -vv "$APP"
for exe in $NAME lyrionplay-agent squeezelite; do
	f="$APP/Contents/MacOS/$exe"
	flags=$(codesign -dv "$f" 2>&1 | sed -n 's/.*flags=\([^ ]*\).*/\1/p')
	ents=$(codesign -d --entitlements - "$f" 2>/dev/null | grep -c '<key>' || true)
	libs=$(otool -L "$f" | tail -n +2 | awk '{print $1}' | grep -v -E '^(/usr/lib/|/System/Library/)' || true)
	printf '%-16s %-6s flags %-26s entitlements %s  non-system libraries: %s\n' "$exe" "$(lipo -archs "$f")" "$flags" "$ents" "${libs:-none}"
	[ "$(lipo -archs "$f")" = arm64 ] || { echo "FAIL: $exe is not arm64-only" >&2; exit 1; }
	case "$flags" in *runtime*) ;; *) echo "FAIL: $exe lacks the hardened runtime" >&2; exit 1 ;; esac
	[ "$ents" = "0" ] || { echo "FAIL: $exe has entitlements" >&2; exit 1; }
	[ -z "$libs" ] || { echo "FAIL: $exe links a non-system library" >&2; exit 1; }
done
echo "built: $APP"

case "$MODE" in
--install)
	sh "$ROOT/scripts/install.sh" "$APP"
	;;
--release)
	DIST="$ROOT/dist/$NAME-$VERSION"
	SOURCES="$ROOT/dist/$NAME-$VERSION-codec-sources"
	rm -rf "$DIST" "$DIST.zip" "$SOURCES" "$SOURCES.zip"
	# The codec sources first, the app's zip last, so a release that stops anywhere leaves no app zip
	# without its sources. The engine links these codec libraries statically, so their source is part
	# of the engine's Corresponding Source (GPLv3 section 6): FAAD2 is GPL, mpg123 and soxr LGPL.
	# Attach this zip to the GitHub release with the app's, so it stays available whatever happens to
	# the upstream sites. The copies are checked again: what ships is what was pinned.
	mkdir -p "$SOURCES"
	for archive in $ARCHIVES; do
		cp "$DEPS/$archive" "$SOURCES/"
	done
	check_codec_sources "$SOURCES"
	cp "$ROOT/deps/build-deps.sh" "$SOURCES/"
	cat > "$SOURCES/README.txt" <<SOURCES_README
The source code of the codec libraries linked into LyrionPlay $VERSION's audio engine, exactly as
built: each archive as downloaded, and build-deps.sh, which names where each came from, its SHA-256,
and how it was built. The engine's own source, and the rest of LyrionPlay's, is the tag v$VERSION at
https://github.com/SimonArnold002/LyrionPlay
SOURCES_README
	ditto -c -k --norsrc --noextattr --keepParent "$SOURCES" "$SOURCES.zip"
	mkdir -p "$DIST"
	ditto "$APP" "$DIST/$NAME.app"
	python3 "$ROOT/tools/make_readme_html.py" >/dev/null # the pages, with this version's badge
	cp "$ROOT/scripts/install.sh" "$ROOT/scripts/uninstall.sh" "$ROOT/INSTALL.md" "$ROOT/INSTALL.html" "$DIST/"
	ditto -c -k --norsrc --noextattr --keepParent "$DIST" "$DIST.zip" # no ._ files: Mac metadata does not ship
	echo "release: $DIST.zip ($(du -h "$DIST.zip" | cut -f1))"
	echo "release: $SOURCES.zip ($(du -h "$SOURCES.zip" | cut -f1)), attach it to the release too"
	;;
esac
