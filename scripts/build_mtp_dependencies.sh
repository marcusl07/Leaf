#!/usr/bin/env bash
set -euo pipefail

# Build exact upstream releases for Leaf's deployment target. Nothing installs
# into Homebrew or system directories. Cached source archives are hash checked.
root="$(cd "$(dirname "$0")/.." && pwd)"
script_file="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
arch="${2:-$(uname -m)}"
prefix="${1:-$root/Build/MTPDependencies/$arch}"
mkdir -p "$prefix"
prefix="$(cd "$prefix" && pwd)"
source_cache="$prefix/share/leaf-mtp"
if ! command -v "${PKG_CONFIG:-pkg-config}" >/dev/null 2>&1; then
    echo "Developer prerequisite missing: install pkg-config (or set PKG_CONFIG to pkgconf)." >&2
    exit 1
fi
mkdir -p "$source_cache"
work="$(mktemp -d /tmp/leaf-mtp-dependencies.XXXXXX)"
trap 'rm -rf "$work"' EXIT
export LC_ALL=C
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}"
export CC="$(xcrun --find clang)"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
export CFLAGS="-arch $arch -isysroot $sdk -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET -O2"
export LDFLAGS="-arch $arch -isysroot $sdk -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
# libtool's Darwin probe uses sysctl, which is unavailable in restricted builds.
export lt_cv_sys_max_cmd_len=262144
jobs="${LEAF_BUILD_JOBS:-4}"

fetch() {
    local name="$1" url="$2" expected="$3"
    if [[ ! -f "$source_cache/$name" ]]; then
        curl -fL --retry 2 "$url" -o "$source_cache/$name"
    fi
    local actual
    actual="$(shasum -a 256 "$source_cache/$name" | awk '{print $1}')"
    [[ "$actual" == "$expected" ]] || { echo "Source checksum mismatch: $name" >&2; exit 1; }
}

fetch libusb-1.0.29.tar.bz2 \
    https://github.com/libusb/libusb/releases/download/v1.0.29/libusb-1.0.29.tar.bz2 \
    5977fc950f8d1395ccea9bd48c06b3f808fd3c2c961b44b0c2e6e29fc3a70a85
fetch libmtp-1.1.23.tar.gz \
    https://downloads.sourceforge.net/project/libmtp/libmtp/1.1.23/libmtp-1.1.23.tar.gz \
    74a2b6e8cb4a0304e95b995496ea3ac644c29371649b892b856e22f12a0bdeed
tar -xjf "$source_cache/libusb-1.0.29.tar.bz2" -C "$work"
tar -xzf "$source_cache/libmtp-1.1.23.tar.gz" -C "$work"
(
    cd "$work/libusb-1.0.29"
    ./configure --host="$arch-apple-darwin" --prefix="$prefix" --disable-static
    make -j"$jobs"
    make install
)
(
    cd "$work/libmtp-1.1.23"
    export LIBUSB_CFLAGS="-I$prefix/include/libusb-1.0"
    export LIBUSB_LIBS="-L$prefix/lib -lusb-1.0"
    ./configure --host="$arch-apple-darwin" --prefix="$prefix" --disable-static --disable-doxygen --disable-mtpz
    make -j"$jobs"
    make install
)
cp "$work/libusb-1.0.29/COPYING" "$source_cache/libusb-COPYING.txt"
cp "$work/libusb-1.0.29/AUTHORS" "$source_cache/libusb-AUTHORS.txt"
cp "$work/libmtp-1.1.23/COPYING" "$source_cache/libmtp-COPYING.txt"
cp "$work/libmtp-1.1.23/AUTHORS" "$source_cache/libmtp-AUTHORS.txt"
if [[ "$script_file" != "$source_cache/build_mtp_dependencies.sh" ]]; then
    cp "$script_file" "$source_cache/build_mtp_dependencies.sh"
fi
echo "Built MTP dependencies for $arch, macOS $MACOSX_DEPLOYMENT_TARGET: $prefix"
