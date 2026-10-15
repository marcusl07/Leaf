#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
architectures="${ARCHS:-$(uname -m)}"
app="${1:-${TARGET_BUILD_DIR:?Missing app path}/${WRAPPER_NAME:?Missing wrapper name}}"
work="$(mktemp -d /tmp/leaf-mtp-helper.XXXXXX)"
trap 'rm -rf "$work"' EXIT
for arch in $architectures; do
    case "$arch" in arm64|x86_64) ;; *) echo "Unsupported architecture: $arch" >&2; exit 1 ;; esac
    prefix="${LEAF_MTP_PREFIX:-$root/Build/MTPDependencies/$arch}"
    if [[ ! -f "$prefix/include/libmtp.h" || ! -d "$prefix/share/leaf-mtp" ]]; then
        echo "Build bundled dependencies first: scripts/build_mtp_dependencies.sh '$prefix' '$arch'" >&2
        exit 1
    fi
    mkdir -p "$work/$arch/Contents/Helpers" "$work/$arch/Contents/Frameworks"
    xcrun clang -std=c11 -Wall -Wextra -Werror -O2 -arch "$arch" \
        -mmacosx-version-min="${MACOSX_DEPLOYMENT_TARGET:-13.0}" \
        -I"$prefix/include" -I"$prefix/include/libusb-1.0" \
        "$root/Native/KindleMTPHelper.c" -L"$prefix/lib" -lmtp -lusb-1.0 \
        -Wl,-rpath,@executable_path/../Frameworks -o "$work/$arch/Contents/Helpers/LeafMTPHelper"
    for library in libmtp.9.dylib libusb-1.0.0.dylib; do
        cp -f "$prefix/lib/$library" "$work/$arch/Contents/Frameworks/$library"
        chmod u+w "$work/$arch/Contents/Frameworks/$library"
        install_name_tool -id "@rpath/$library" "$work/$arch/Contents/Frameworks/$library"
    done
python3 - "$work/$arch" <<'PY'
from pathlib import Path
import subprocess
import sys
app = Path(sys.argv[1])
binaries = [app / 'Contents/Helpers/LeafMTPHelper',
            app / 'Contents/Frameworks/libmtp.9.dylib', app / 'Contents/Frameworks/libusb-1.0.0.dylib']
for binary in binaries:
    for line in subprocess.check_output(['otool', '-L', str(binary)], text=True).splitlines()[1:]:
        dependency = line.strip().split(' (compatibility version')[0]
        if dependency.startswith(('/usr/lib/', '/System/Library/', '@')):
            continue
        name = Path(dependency).name
        if name not in ('libmtp.9.dylib', 'libusb-1.0.0.dylib'):
            raise SystemExit(f'Unexpected non-system dependency: {dependency}')
        subprocess.run(['install_name_tool', '-change', dependency, '@rpath/' + name, str(binary)], check=True)
PY
done
mkdir -p "$app/Contents/Helpers" "$app/Contents/Frameworks" "$app/Contents/Resources/MTPLicenses"
for artifact in Helpers/LeafMTPHelper Frameworks/libmtp.9.dylib Frameworks/libusb-1.0.0.dylib; do
    inputs=()
    for arch in $architectures; do inputs+=("$work/$arch/Contents/$artifact"); done
    xcrun lipo -create "${inputs[@]}" -output "$app/Contents/$artifact"
done
cp "$prefix/share/leaf-mtp/"* "$app/Contents/Resources/MTPLicenses/"
cp "$root/docs/mtp-third-party-notices.txt" "$app/Contents/Resources/MTPLicenses/NOTICE.txt"
identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
if [[ -z "$identity" ]]; then identity=-; fi
for binary in "$app/Contents/Frameworks/libmtp.9.dylib" \
              "$app/Contents/Frameworks/libusb-1.0.0.dylib" "$app/Contents/Helpers/LeafMTPHelper"; do
    codesign --force --sign "$identity" "$binary"
done
