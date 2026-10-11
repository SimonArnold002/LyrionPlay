#!/bin/sh
# Builds build/LyrionPlay.app: codec libraries (skipped when built) -> engine -> Swift agent and
# menu bar app -> icon -> bundle -> ad-hoc signature, then checks the result.
#   scripts/build.sh            build and check
#   scripts/build.sh --install  then install it with scripts/install.sh, signed with your own
#                               certificate, exactly as a user installs a release
#   scripts/build.sh --release  then make dist/LyrionPlay-<version>.zip: the app, install.sh,
#                               uninstall.sh and INSTALL.md
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
MODE="${1:-}"
case "$MODE" in "" | --install | --release) ;; *) echo "usage: $0 [--install | --release]" >&2; exit 2 ;; esac

echo "== codec libraries"
"$ROOT/deps/build-cmake.sh"
"$ROOT/deps/build-deps.sh" | tail -15

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
	swiftc -O "$ROOT/tools/icon/make-icon.swift" -o "$MAKE_ICON" 2>&1 | grep -v 'search path' || true
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
cp "$ROOT/app/Resources/NOTICES.txt" "$APP/Contents/Resources/"
cp "$ROOT/engine/LICENSE.txt" "$APP/Contents/Resources/squeezelite-LICENSE.txt"

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
	rm -rf "$DIST" "$DIST.zip"
	mkdir -p "$DIST"
	ditto "$APP" "$DIST/$NAME.app"
	python3 "$ROOT/tools/make_readme_html.py" >/dev/null # the pages, with this version's badge
	cp "$ROOT/scripts/install.sh" "$ROOT/scripts/uninstall.sh" "$ROOT/INSTALL.md" "$ROOT/INSTALL.html" "$DIST/"
	ditto -c -k --norsrc --noextattr --keepParent "$DIST" "$DIST.zip" # no ._ files: Mac metadata does not ship
	echo "release: $DIST.zip ($(du -h "$DIST.zip" | cut -f1))"
	;;
esac
