#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
architectures="${LEAF_BETA_ARCHS:-arm64 x86_64}"
scripts/generate_project.sh
xcodebuild -project Leaf.xcodeproj -scheme Leaf -configuration Release \
    -derivedDataPath "$root/Build/MTPBeta" -clonedSourcePackagesDirPath "$root/Build/SourcePackages" \
    -disableAutomaticPackageResolution -skipPackageUpdates \
    ARCHS="$architectures" ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build \
    > "$root/Build/MTPBeta-build.log" 2>&1
app="$root/Build/MTPBeta/Build/Products/Release/Leaf.app"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
stage="$(mktemp -d "$root/Build/leaf-mtp-package.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/Leaf MTP Beta"
ditto "$app" "$stage/Leaf MTP Beta/Leaf.app"
# Friend instructions only; omit developer tooling details from the handoff.
sed '/^# Developer build/,$d' docs/mtp-beta-testing.md > "$stage/Leaf MTP Beta/START HERE.txt"
archive="$root/Build/Leaf-MTP-Beta.zip"
ditto -c -k --sequesterRsrc --keepParent "$stage/Leaf MTP Beta" "$archive"
unzip -tq "$archive"
echo "Friend test package: $archive"
