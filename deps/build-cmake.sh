#!/bin/sh
# Builds CMake from its source release with the Command Line Tools, so the build
# tool is Apple Silicon only and lives in the repo (deps/tools), not system-wide.
# Simon asked 2026-10-09 for native tools rather than the universal CMake.app.
set -eu

CMAKE_VERSION=4.4.4
# From cmake-4.4.4-SHA-256.txt on the v4.4.4 GitHub release.
CMAKE_SHA256=bd24c30d80a7744ae84b845ff080cc8453b06c622ef01066564108e9cefc44cf

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$ROOT/deps/src"
TOOLS="$ROOT/deps/tools"
TARBALL="$SRC/cmake-$CMAKE_VERSION.tar.gz"
JOBS=$(sysctl -n hw.ncpu)

if [ -x "$TOOLS/bin/cmake" ] && "$TOOLS/bin/cmake" --version | grep -q "cmake version $CMAKE_VERSION\$"; then
	echo "cmake $CMAKE_VERSION already built: $TOOLS/bin/cmake"
	exit 0
fi

mkdir -p "$SRC"
if [ ! -f "$TARBALL" ]; then
	curl -fL --retry 3 -o "$TARBALL.part" \
		"https://github.com/Kitware/CMake/releases/download/v$CMAKE_VERSION/cmake-$CMAKE_VERSION.tar.gz"
	mv "$TARBALL.part" "$TARBALL"
fi
echo "$CMAKE_SHA256  $TARBALL" | shasum -a 256 -c -

rm -rf "$SRC/cmake-$CMAKE_VERSION"
tar -xzf "$TARBALL" -C "$SRC"
cd "$SRC/cmake-$CMAKE_VERSION"

# OpenSSL off: nothing here downloads over HTTPS from inside CMake.
./bootstrap --prefix="$TOOLS" --parallel="$JOBS" -- \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_OSX_ARCHITECTURES=arm64 \
	-DCMAKE_USE_OPENSSL=OFF \
	-DBUILD_TESTING=OFF
make -j"$JOBS"
make install

ARCHS=$(lipo -archs "$TOOLS/bin/cmake")
echo "built $("$TOOLS/bin/cmake" --version | head -1), architectures: $ARCHS"
[ "$ARCHS" = "arm64" ] || { echo "FAIL: expected arm64 only" >&2; exit 1; }
