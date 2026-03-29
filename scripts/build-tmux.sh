#!/bin/bash
set -euo pipefail

# Build tmux from HEAD with static libevent/ncurses/utf8proc for bundling inside Amux.app.
# Output: build/tmux-bundle/tmux (a binary with no Homebrew dylib dependencies)

BUILD_DIR="$(cd "$(dirname "$0")/.." && pwd)/build/tmux-deps"
OUTPUT_DIR="$(cd "$(dirname "$0")/.." && pwd)/build/tmux-bundle"
NPROC=$(sysctl -n hw.ncpu)

mkdir -p "$BUILD_DIR" "$OUTPUT_DIR"

echo "=== Building tmux for Amux.app bundle ==="
echo "Build dir: $BUILD_DIR"
echo "Output dir: $OUTPUT_DIR"

# Check build tools
for tool in autoconf automake pkg-config cmake; do
    if ! command -v "$tool" &>/dev/null; then
        echo "Missing: $tool. Install with: brew install $tool"
        exit 1
    fi
done

# --- libevent (static) ---
if [ ! -f "$BUILD_DIR/lib/libevent.a" ]; then
    echo ""
    echo "=== Building libevent (static) ==="
    cd /tmp
    rm -rf libevent-build
    git clone --depth 1 --branch release-2.1.12-stable https://github.com/libevent/libevent.git libevent-build
    cd libevent-build
    cmake -DCMAKE_INSTALL_PREFIX="$BUILD_DIR" \
          -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
          -DEVENT__LIBRARY_TYPE=STATIC \
          -DEVENT__DISABLE_OPENSSL=ON \
          -DEVENT__DISABLE_BENCHMARK=ON \
          -DEVENT__DISABLE_TESTS=ON \
          -DEVENT__DISABLE_SAMPLES=ON \
          .
    make -j"$NPROC"
    make install
    cd /tmp
    rm -rf libevent-build
    echo "✓ libevent built"
else
    echo "✓ libevent already built"
fi

# --- ncurses (static) ---
if [ ! -f "$BUILD_DIR/lib/libncursesw.a" ]; then
    echo ""
    echo "=== Building ncurses (static) ==="
    cd /tmp
    rm -rf ncurses-build
    curl -sSL https://ftp.gnu.org/pub/gnu/ncurses/ncurses-6.5.tar.gz -o ncurses.tar.gz
    tar xzf ncurses.tar.gz
    mv ncurses-6.5 ncurses-build
    rm ncurses.tar.gz
    cd ncurses-build
    ./configure --prefix="$BUILD_DIR" \
                --without-shared \
                --with-normal \
                --without-debug \
                --without-ada \
                --enable-widec \
                --enable-pc-files \
                --with-pkg-config-libdir="$BUILD_DIR/lib/pkgconfig"
    make -j"$NPROC"
    make install
    cd /tmp
    rm -rf ncurses-build
    echo "✓ ncurses built"
else
    echo "✓ ncurses already built"
fi

# --- utf8proc (static) ---
if [ ! -f "$BUILD_DIR/lib/libutf8proc.a" ]; then
    echo ""
    echo "=== Building utf8proc (static) ==="
    cd /tmp
    rm -rf utf8proc-build
    git clone --depth 1 --branch v2.9.0 https://github.com/JuliaStrings/utf8proc.git utf8proc-build
    cd utf8proc-build
    mkdir _build
    cd _build
    cmake -DCMAKE_INSTALL_PREFIX="$BUILD_DIR" \
          -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
          -DBUILD_SHARED_LIBS=OFF \
          ..
    make -j"$NPROC"
    make install
    cd /tmp
    rm -rf utf8proc-build
    echo "✓ utf8proc built"
else
    echo "✓ utf8proc already built"
fi

# --- tmux (HEAD, linked against static deps) ---
echo ""
echo "=== Building tmux HEAD ==="
cd /tmp
rm -rf tmux-build
git clone --depth 1 https://github.com/tmux/tmux.git tmux-build
cd tmux-build

# Save license
cp COPYING "$OUTPUT_DIR/LICENSE-tmux.txt"

sh autogen.sh

PKG_CONFIG_PATH="$BUILD_DIR/lib/pkgconfig" \
CPPFLAGS="-I$BUILD_DIR/include -I$BUILD_DIR/include/ncursesw" \
LDFLAGS="-L$BUILD_DIR/lib" \
./configure --enable-utf8proc

make -j"$NPROC"

# Copy binary
cp tmux "$OUTPUT_DIR/tmux"
echo "✓ tmux built"

# Verify no Homebrew dylib dependencies
echo ""
echo "=== Checking dynamic dependencies ==="
otool -L "$OUTPUT_DIR/tmux" | grep -v /usr/lib | grep -v /System | grep -v "$OUTPUT_DIR" || echo "(no external dylibs — good)"

cd /tmp
rm -rf tmux-build

echo ""
echo "=== Done ==="
echo "tmux binary: $OUTPUT_DIR/tmux"
echo "tmux license: $OUTPUT_DIR/LICENSE-tmux.txt"
