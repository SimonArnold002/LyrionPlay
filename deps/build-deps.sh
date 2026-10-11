#!/bin/sh
# Builds the engine's codec libraries as STATIC arm64 libraries into deps/out
# (include/ + lib/) with the CMake from build-cmake.sh. Static only, so the
# engine has no dylib dependencies and needs no hardened-runtime exceptions.
#
# Every source archive is pinned by SHA-256. "Xiph" = Xiph's published
# SHA256SUMS; "pinned here" = no published checksum exists, so this is the hash
# of the first download (2026-10-09). A changed archive stops the build.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SRC="$ROOT/deps/src"
OUT="$ROOT/deps/out"
CMAKE="$ROOT/deps/tools/bin/cmake"
JOBS=$(sysctl -n hw.ncpu)
MACOS_MIN=14.0
export MACOSX_DEPLOYMENT_TARGET=$MACOS_MIN

[ -x "$CMAKE" ] || { echo "run deps/build-cmake.sh first" >&2; exit 1; }
mkdir -p "$SRC" "$OUT"

fetch() { # file url sha256
	if [ ! -f "$SRC/$1" ]; then
		curl -fL --retry 3 -o "$SRC/$1.part" "$2"
		mv "$SRC/$1.part" "$SRC/$1"
	fi
	echo "$3  $SRC/$1" | shasum -a 256 -c -
}

unpack() { # archive dir
	rm -rf "$SRC/$2"
	mkdir -p "$SRC/$2"
	tar -xf "$SRC/$1" -C "$SRC/$2" --strip-components=1
}

cmake_build() { # source-dir build-dir [cmake args...]
	s=$1
	b=$2
	shift 2
	# CMAKE_POLICY_VERSION_MINIMUM: CMake 4 refuses projects that ask for < 3.5 (soxr, vorbis).
	"$CMAKE" -S "$s" -B "$b" \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_OSX_ARCHITECTURES=arm64 \
		-DCMAKE_OSX_DEPLOYMENT_TARGET=$MACOS_MIN \
		-DCMAKE_INSTALL_PREFIX="$OUT" \
		-DCMAKE_PREFIX_PATH="$OUT" \
		-DBUILD_SHARED_LIBS=OFF \
		-DBUILD_TESTING=OFF \
		-DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
		"$@"
	"$CMAKE" --build "$b" -j "$JOBS"
	"$CMAKE" --install "$b"
}

# A stamp per library+version, so a rerun skips what is already built.
built() { [ -f "$OUT/.built-$1" ] && echo "$1 already built"; }
stamp() { touch "$OUT/.built-$1"; }

# libogg 1.3.6 (Xiph)
if ! built libogg-1.3.6; then
fetch libogg-1.3.6.tar.xz https://downloads.xiph.org/releases/ogg/libogg-1.3.6.tar.xz \
	5c8253428e181840cd20d41f3ca16557a9cc04bad4a3d04cce84808677fa1061
unpack libogg-1.3.6.tar.xz ogg
cmake_build "$SRC/ogg" "$SRC/ogg/_build" -DINSTALL_DOCS=OFF
stamp libogg-1.3.6
fi

# FLAC 1.5.0 (Xiph), with Ogg FLAC
if ! built flac-1.5.0; then
fetch flac-1.5.0.tar.xz https://downloads.xiph.org/releases/flac/flac-1.5.0.tar.xz \
	f2c1c76592a82ffff8413ba3c4a1299b6c7ab06c734dee03fd88630485c2b920
unpack flac-1.5.0.tar.xz flac
cmake_build "$SRC/flac" "$SRC/flac/_build" -DWITH_OGG=ON -DBUILD_CXXLIBS=OFF -DBUILD_PROGRAMS=OFF \
	-DBUILD_EXAMPLES=OFF -DBUILD_DOCS=OFF -DINSTALL_MANPAGES=OFF
stamp flac-1.5.0
fi

# libvorbis 1.3.7 (Xiph)
if ! built libvorbis-1.3.7; then
fetch libvorbis-1.3.7.tar.xz https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.xz \
	b33cc4934322bcbf6efcbacf49e3ca01aadbea4114ec9589d1b1e9d20f72954b
unpack libvorbis-1.3.7.tar.xz vorbis
cmake_build "$SRC/vorbis" "$SRC/vorbis/_build"
stamp libvorbis-1.3.7
fi

# Opus 1.6.1 (Xiph)
if ! built opus-1.6.1; then
fetch opus-1.6.1.tar.gz https://downloads.xiph.org/releases/opus/opus-1.6.1.tar.gz \
	6ffcb593207be92584df15b32466ed64bbec99109f007c82205f0194572411a1
unpack opus-1.6.1.tar.gz opus
cmake_build "$SRC/opus" "$SRC/opus/_build" -DOPUS_BUILD_PROGRAMS=OFF -DOPUS_BUILD_TESTING=OFF
stamp opus-1.6.1
fi

# opusfile 0.12 (Xiph). Its release archive has no CMakeLists.txt (that is only in
# git), so its four core sources are compiled here; http.c is left out (no OpenSSL).
if ! built opusfile-0.12; then
fetch opusfile-0.12.tar.gz https://downloads.xiph.org/releases/opus/opusfile-0.12.tar.gz \
	118d8601c12dd6a44f52423e68ca9083cc9f2bfe72da7a8c1acb22a80ae3550b
unpack opusfile-0.12.tar.gz opusfile
mkdir -p "$SRC/opusfile/_build" "$OUT/lib" "$OUT/include/opus"
(
	cd "$SRC/opusfile/_build"
	for f in info.c internal.c opusfile.c stream.c; do
		clang -O2 -arch arm64 -mmacosx-version-min=$MACOS_MIN -DOP_HAVE_LRINTF \
			-I../include -I"$OUT/include" -I"$OUT/include/opus" -c "../src/$f"
	done
	rm -f "$OUT/lib/libopusfile.a"
	libtool -static -o "$OUT/lib/libopusfile.a" ./*.o
)
cp "$SRC/opusfile/include/opusfile.h" "$OUT/include/opus/"
stamp opusfile-0.12
fi

# mpg123 1.33.7 (pinned here; mpg123.de publishes only a GPG signature)
if ! built mpg123-1.33.7; then
fetch mpg123-1.33.7.tar.bz2 https://www.mpg123.de/download/mpg123-1.33.7.tar.bz2 \
	31d0e35a4ca567ec9b5ebda6c3062bb4435d6d3eacd6ef0d95cadd7854dc03ee
unpack mpg123-1.33.7.tar.bz2 mpg123
cmake_build "$SRC/mpg123/ports/cmake" "$SRC/mpg123/_build" -DBUILD_LIBOUT123=OFF -DNETWORK=OFF
stamp mpg123-1.33.7
fi

# faad2 2.11.4 (pinned here; GitHub tag archive)
if ! built faad2-2.11.4; then
fetch faad2-2.11.4.tar.gz https://github.com/knik0/faad2/archive/refs/tags/2.11.4.tar.gz \
	ee479ccbae4a8387ab696e6f21a481bd83fe3881471cafa81b4ae59d7d3aed43
unpack faad2-2.11.4.tar.gz faad2
cmake_build "$SRC/faad2" "$SRC/faad2/_build" -DFAAD_BUILD_CLI=OFF
stamp faad2-2.11.4
fi

# soxr 0.1.3 (pinned here; SourceForge publishes no SHA-256)
if ! built soxr-0.1.3; then
fetch soxr-0.1.3-Source.tar.xz https://downloads.sourceforge.net/project/soxr/soxr-0.1.3-Source.tar.xz \
	b111c15fdc8c029989330ff559184198c161100a59312f5dc19ddeb9b5a15889
unpack soxr-0.1.3-Source.tar.xz soxr
cmake_build "$SRC/soxr" "$SRC/soxr/_build" -DBUILD_TESTS=OFF -DBUILD_EXAMPLES=OFF -DWITH_OPENMP=OFF \
	-DWITH_LSR_BINDINGS=OFF
stamp soxr-0.1.3
fi

# Apple ALAC decoder (pinned here; macosforge/alac has no build system or releases).
# squeezelite's alac_wrapper.cpp includes "ALACDecoder.h" and links -lalac.
ALAC_COMMIT=c38887c5c5e64a4b31108733bd79ca9b2496d987
if ! built alac-c38887c; then
fetch alac-$ALAC_COMMIT.tar.gz https://github.com/macosforge/alac/archive/$ALAC_COMMIT.tar.gz \
	98635ece42fb1c3fceb75eaa4b5164d866e09f0195b3e7ec4085f1123c5e272f
unpack alac-$ALAC_COMMIT.tar.gz alac
mkdir -p "$SRC/alac/_build" "$OUT/lib" "$OUT/include/alac"
(
	cd "$SRC/alac/_build"
	FLAGS="-O2 -arch arm64 -mmacosx-version-min=$MACOS_MIN"
	clang++ $FLAGS -c ../codec/ALACDecoder.cpp
	for f in ALACBitUtilities.c EndianPortable.c ag_dec.c dp_dec.c matrix_dec.c; do
		clang $FLAGS -c "../codec/$f"
	done
	rm -f "$OUT/lib/libalac.a"
	libtool -static -o "$OUT/lib/libalac.a" ./*.o
)
cp "$SRC/alac/codec/"*.h "$OUT/include/alac/"
stamp alac-c38887c
fi

# Every library must be static arm64 only.
echo "--- deps/out/lib:"
for lib in "$OUT"/lib/*.a; do
	printf '%-28s %s\n' "$(basename "$lib")" "$(lipo -archs "$lib")"
done
if ls "$OUT"/lib/*.dylib >/dev/null 2>&1; then
	echo "FAIL: a dylib was built" >&2
	exit 1
fi
