#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
work="$(mktemp -d /tmp/leaf-mtp-tests.XXXXXX)"
trap 'rm -rf "$work"' EXIT
prefix="${LEAF_MTP_PREFIX:-$root/Build/MTPDependencies/$(uname -m)}"
cc -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined \
    -I"$prefix/include" Tests/test_mtp_probe.c -L"$prefix/lib" -lmtp \
    -Wl,-rpath,"$prefix/lib" -o "$work/test-mtp-probe"
"$work/test-mtp-probe"
cc -std=c11 -Wall -Wextra -Werror -fsanitize=address,undefined \
    -I"$prefix/include" -I"$prefix/include/libusb-1.0" Tests/MTP/test_helper.c \
    -L"$prefix/lib" -lmtp -lusb-1.0 -Wl,-rpath,"$prefix/lib" -o "$work/test-mtp-helper"
"$work/test-mtp-helper"
swiftc -warnings-as-errors -module-cache-path "$work/module-cache" \
    Models/Book.swift Models/Highlight.swift Models/DedupeKeyBuilder.swift \
    Parsing/ClippingsParser.swift App/ImportCoordinator.swift \
    App/MTPKindleWatcher.swift App/MTPImportService.swift Tests/MTP/main.swift \
    -o "$work/test-mtp-swift"
"$work/test-mtp-swift"
