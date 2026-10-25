#!/usr/bin/env bash
set -euo pipefail

ARCH=arm64
SDK=iphoneos
SDKMINVER="${SDKMINVER:-17.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/engine/build"
SYSROOT="$ROOT/engine/sysroot"
SRC="$BUILD/src"
OUT="$ROOT/engine/out"
CROSS="$BUILD/ios-$ARCH.cross"
NCPU="${NCPU:-$(sysctl -n hw.ncpu)}"
TARGET="$ARCH-apple-ios$SDKMINVER"

LIBFFI_URL="https://github.com/libffi/libffi/releases/download/v3.5.0/libffi-3.5.0.tar.gz"
LIBFFI_SHA="8c72678628a5dd8782f08ad421d5a441e42c1c5c1b33e0bc211cbfcf1f3b3978"
GLIB_URL="https://download.gnome.org/sources/glib/2.83/glib-2.83.0.tar.xz"
GLIB_SHA="a07d9e1a57a4279c5ece71c26dc44eea12bd518ea9ff695d53e722997032b614"
PIXMAN_URL="https://www.cairographics.org/releases/pixman-0.38.0.tar.gz"
PIXMAN_SHA="a7592bef0156d7c27545487a52245669b00cf7e70054505381cff2136d890ca8"
QEMU_URL="https://github.com/utmapp/qemu/releases/download/v10.0.12-utm/qemu-10.0.12-utm.tar.xz"
QEMU_SHA="7c9605290b34152debb842e965a55d2e4fbba4793e536ab677b4027e5dc0ba1a"
ZSTD_URL="https://github.com/facebook/zstd/releases/download/v1.5.2/zstd-1.5.2.tar.gz"
ZSTD_SHA="7c42d56fac126929a6a85dbc73ff1db2411d04f104fae9bdea51305663a83fd0"
SLIRP_URL="https://github.com/utmapp/libslirp/releases/download/v4.9.1-release-mirror/libslirp-v4.9.1.tar.gz"
SLIRP_SHA="3970542143b7c11e6a09a4d2b50f30a133473c41f15ed0bdcc3b7a1c450d9a5c"

log() { echo "==> $*" >&2; }

die() { echo "ERROR: $*" >&2; exit 1; }

mkdir -p "$BUILD" "$SYSROOT" "$SRC" "$OUT"

[ "$(uname -s)" = "Darwin" ] || die "must run on macOS with Xcode"

SDKROOT="$(xcrun --sdk "$SDK" --show-sdk-path)"
CLANG="$(xcrun --sdk "$SDK" --find clang)"
CLANGXX="$(xcrun --sdk "$SDK" --find clang++)"
AR="$(xcrun --sdk "$SDK" --find ar)"
NM="$(xcrun --sdk "$SDK" --find nm)"
RANLIB="$(xcrun --sdk "$SDK" --find ranlib)"
STRIP="$(xcrun --sdk "$SDK" --find strip)"
PKG_CONFIG="$(command -v pkg-config || true)"
PYTHON="$(command -v python3 || true)"
MKENUMS="$(command -v glib-mkenums || true)"
GLIB_COMPILE_RESOURCES="$(command -v glib-compile-resources || true)"
MESON="$(command -v meson || true)"

[ -n "$PKG_CONFIG" ] || die "missing pkg-config (brew install pkg-config)"
[ -n "$PYTHON" ] || die "missing python3"
[ -n "$MESON" ] || die "missing meson (brew install meson)"
[ -n "$MKENUMS" ] || die "missing glib-mkenums (brew install glib)"
[ -n "$GLIB_COMPILE_RESOURCES" ] || die "missing glib-compile-resources (brew install glib)"

export CC="$CLANG -target $TARGET"
export CXX="$CLANGXX -target $TARGET"
export CPP="$CLANG -E -target $TARGET -isysroot $SDKROOT"
export OBJCC="$CLANG -target $TARGET"
export LD="$CLANG -target $TARGET"
export AR NM RANLIB STRIP
export CFLAGS="-arch $ARCH -isysroot $SDKROOT -I$SYSROOT/include -F$SYSROOT/Frameworks -O2 -fno-common"
export CXXFLAGS="$CFLAGS"
export OBJCFLAGS="$CFLAGS"
export LDFLAGS="-arch $ARCH -isysroot $SDKROOT -L$SYSROOT/lib -F$SYSROOT/Frameworks"
export CPPFLAGS="$CFLAGS -target $TARGET"
export PKG_CONFIG_LIBDIR="$SYSROOT/lib/pkgconfig"
export PKG_CONFIG_PATH="$SYSROOT/lib/pkgconfig"
export ac_cv_func_pipe2=no
export ac_cv_func_dup3=no
export NCPU

cat > "$CROSS" <<EOF
[properties]
needs_exe_wrapper = true
has_function_pipe2 = false
has_function_dup3 = false

[built-in options]
c_args = ['-arch', '$ARCH', '-isysroot', '$SDKROOT', '-I$SYSROOT/include', '-F$SYSROOT/Frameworks', '-O2', '-fno-common']
c_link_args = ['-arch', '$ARCH', '-isysroot', '$SDKROOT', '-L$SYSROOT/lib', '-F$SYSROOT/Frameworks']
cpp_args = ['-arch', '$ARCH', '-isysroot', '$SDKROOT', '-I$SYSROOT/include', '-F$SYSROOT/Frameworks', '-O2', '-fno-common']
cpp_link_args = ['-arch', '$ARCH', '-isysroot', '$SDKROOT', '-L$SYSROOT/lib', '-F$SYSROOT/Frameworks']
objc_args = ['-arch', '$ARCH', '-isysroot', '$SDKROOT', '-I$SYSROOT/include', '-F$SYSROOT/Frameworks', '-O2', '-fno-common']
objc_link_args = ['-arch', '$ARCH', '-isysroot', '$SDKROOT', '-L$SYSROOT/lib', '-F$SYSROOT/Frameworks']
default_library = 'shared'

[binaries]
c = ['$CLANG', '-target', '$TARGET']
cpp = ['$CLANGXX', '-target', '$TARGET']
objc = ['$CLANG', '-target', '$TARGET']
objcpp = ['$CLANGXX', '-target', '$TARGET']
ar = ['$AR']
nm = ['$NM']
ranlib = ['$RANLIB']
strip = ['$STRIP', '-x']
pkg-config = ['$PKG_CONFIG']
pkgconfig = ['$PKG_CONFIG']
python = ['$PYTHON']
glib-mkenums = ['$MKENUMS']
glib-compile-resources = ['$GLIB_COMPILE_RESOURCES']

[host_machine]
system = 'ios'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
EOF

fetch() {
    local url="$1" sha="$2"
    local file="$BUILD/$(basename "$url")"
    if [ ! -f "$file" ]; then
        log "fetch $(basename "$url")"
        curl -fL --retry 5 --retry-delay 3 -o "$file.part" "$url"
        mv "$file.part" "$file"
    fi
    local got
    got="$(shasum -a 256 "$file" | awk '{print $1}')"
    [ "$got" = "$sha" ] || die "sha256 mismatch: $file (got $got)"
    echo "$file"
}

unpack() {
    local file="$1"
    local name
    name="$(basename "$file")"
    name="${name%.tar.*}"
    if [ ! -d "$SRC/$name" ]; then
        log "extract $name"
        tar -xf "$file" -C "$SRC"
    fi
    echo "$SRC/$name"
}

autotools_build() {
    local dir="$1"
    shift
    (
        cd "$dir"
        if [ ! -f config.status ]; then
            log "configure $(basename "$dir")"
            ./configure --prefix="$SYSROOT" --host=aarch64-apple-darwin --disable-dependency-tracking "$@"
        fi
        log "make $(basename "$dir")"
        make -j"$NCPU"
        make install
    )
}

meson_build() {
    local dir="$1"
    shift
    (
        cd "$dir"
        if [ ! -d build-ios ]; then
            log "meson setup $(basename "$dir")"
            meson setup build-ios --prefix="$SYSROOT" --buildtype=release --cross-file "$CROSS" "$@"
        fi
        log "ninja $(basename "$dir")"
        meson compile -C build-ios -j "$NCPU"
        meson install -C build-ios
    )
}

log "SDK $SDKROOT | target $TARGET | $NCPU jobs"

LIBFFI_FILE="$(fetch "$LIBFFI_URL" "$LIBFFI_SHA")"
LIBFFI_DIR="$(unpack "$LIBFFI_FILE")"
autotools_build "$LIBFFI_DIR" --enable-static --enable-shared --disable-builddir
[ -f "$SYSROOT/lib/pkgconfig/libffi.pc" ] || die "libffi did not install libffi.pc"

GLIB_FILE="$(fetch "$GLIB_URL" "$GLIB_SHA")"
GLIB_DIR="$(unpack "$GLIB_FILE")"
meson_build "$GLIB_DIR" \
    -Dtests=false \
    -Ddtrace=disabled \
    -Dnls=disabled \
    -Dintrospection=disabled \
    -Dman-pages=disabled \
    -Dselinux=disabled \
    -Dlibmount=disabled \
    -Dsysprof=disabled \
    -Ddocumentation=false \
    -Dglib_debug=disabled
[ -f "$SYSROOT/lib/pkgconfig/glib-2.0.pc" ] || die "glib did not install glib-2.0.pc"

PIXMAN_FILE="$(fetch "$PIXMAN_URL" "$PIXMAN_SHA")"
PIXMAN_DIR="$(unpack "$PIXMAN_FILE")"
if [ ! -f "$PIXMAN_DIR/.devbox-patched" ]; then
    log "patch pixman"
    patch -d "$PIXMAN_DIR" -p1 < "$ROOT/engine/patches/pixman-0.38.0.patch"
    touch "$PIXMAN_DIR/.devbox-patched"
fi
autotools_build "$PIXMAN_DIR" --disable-libpng --disable-gtk
[ -f "$SYSROOT/lib/pkgconfig/pixman-1.pc" ] || die "pixman did not install pixman-1.pc"

SLIRP_FILE="$(fetch "$SLIRP_URL" "$SLIRP_SHA")"
SLIRP_DIR="$(unpack "$SLIRP_FILE")"
if [ ! -f "$SLIRP_DIR/.devbox-patched" ]; then
    log "patch libslirp"
    patch -d "$SLIRP_DIR" -p1 < "$ROOT/engine/patches/libslirp-v4.9.1.patch"
    touch "$SLIRP_DIR/.devbox-patched"
fi
meson_build "$SLIRP_DIR"
[ -f "$SYSROOT/lib/pkgconfig/slirp.pc" ] || die "libslirp did not install slirp.pc"

QEMU_FILE="$(fetch "$QEMU_URL" "$QEMU_SHA")"
QEMU_DIR="$(unpack "$QEMU_FILE")"
if [ ! -f "$QEMU_DIR/.devbox-patched" ]; then
    log "patch qemu ios jit"
    patch -d "$QEMU_DIR" -p1 < "$ROOT/engine/patches/qemu-ios-jit.patch"
    touch "$QEMU_DIR/.devbox-patched"
fi

ZSTD_FILE="$(fetch "$ZSTD_URL" "$ZSTD_SHA")"
ZSTD_DIR="$(unpack "$ZSTD_FILE")"
meson_build "$ZSTD_DIR/build/meson" \
    -Dbin_programs=false \
    -Dbin_tests=false \
    -Dbin_contrib=false \
    -Dzlib=disabled \
    -Dlzma=disabled \
    -Dlz4=disabled
[ -f "$SYSROOT/lib/pkgconfig/libzstd.pc" ] || die "zstd did not install libzstd.pc"

(
    cd "$QEMU_DIR"
    if [ ! -f build/build.ninja ]; then
        log "configure qemu"
        ./configure \
            --prefix="$SYSROOT" \
            --host=aarch64-apple-darwin \
            --cross-prefix="" \
            --target-list=aarch64-softmmu \
            --enable-shared-lib \
            --enable-slirp \
            --enable-ucontext \
            --with-coroutine=libucontext \
            --disable-hvf \
            --disable-cocoa \
            --disable-sdl \
            --disable-coreaudio \
            --disable-slirp-smbd \
            --disable-debug-info \
            --disable-docs \
            --disable-tools \
            --disable-guest-agent \
            --disable-install-blobs \
            --disable-plugins \
            --disable-vnc \
            --disable-gtk \
            --disable-spice \
            --disable-opengl \
            --disable-virglrenderer \
            --disable-dbus-display \
            --disable-curl \
            --disable-xen \
            --disable-kvm \
            --disable-tpm \
            --disable-auth-pam
    fi
    log "build qemu"
    ninja -C build -j "$NCPU"
    ninja -C build install
)

framework_name() {
    local base
    base="$(basename "$1")"
    base="${base%.dylib}"
    echo "${base#lib}"
}

write_plist() {
    local path="$1" exe="$2" bundle="$3" minos="$4"
    cat > "$path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>$exe</string>
	<key>CFBundleIdentifier</key>
	<string>$bundle</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>$exe</string>
	<key>CFBundlePackageType</key>
	<string>FMWK</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>MinimumOSVersion</key>
	<string>$minos</string>
</dict>
</plist>
EOF
}

pack_frameworks() {
    local lib name fw minos dep depname src
    rm -rf "$OUT/Frameworks"
    mkdir -p "$OUT/Frameworks"
    for lib in "$SYSROOT"/lib/*.dylib "$QEMU_DIR"/build/libqemu*.dylib; do
        [ -f "$lib" ] || continue
        if [ -L "$lib" ]; then
            continue
        fi
        name="$(framework_name "$lib")"
        fw="$OUT/Frameworks/$name.framework"
        mkdir -p "$fw"
        cp "$lib" "$fw/$name"
        minos="$(vtool -show-build-version "$lib" 2>/dev/null | awk '/minos/ {print $2; exit}')"
        [ -n "$minos" ] || minos="$SDKMINVER"
        write_plist "$fw/Info.plist" "$name" "app.devbox.engine.$name" "$minos"
        install_name_tool -id "@rpath/$name.framework/$name" "$fw/$name"
    done
    for fw in "$OUT"/Frameworks/*.framework; do
        [ -d "$fw" ] || continue
        src="$fw/$(basename "$fw" .framework)"
        otool -L "$src" | tail -n +2 | awk '{print $1}' | while read -r dep; do
            case "$dep" in
                /usr/lib/* | /System/*) continue ;;
            esac
            depname="$(framework_name "$dep")"
            if [ -d "$OUT/Frameworks/$depname.framework" ]; then
                install_name_tool -change "$dep" "@rpath/$depname.framework/$depname" "$src"
            fi
        done
    done
}

pack_frameworks

log "done"
ls -la "$OUT/Frameworks"
du -sh "$OUT/Frameworks"

