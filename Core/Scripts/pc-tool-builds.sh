#!/usr/bin/env bash
# Builds the backup tool for Linux and for both kinds of Mac into Core/dist.
# Windows builds it for itself on GitHub: .github/workflows/pc-tool-windows.yml.
#
# Needs the Swift toolchain on PATH and xtool's Darwin SDK installed.
set -euo pipefail

core="$(cd "$(dirname "$0")/.." && pwd)"
sdk="${DARWIN_SDK:-$(swift sdk configure --show-configuration darwin arm64-apple-macosx 2>/dev/null \
  | sed -n 's/^sdkRootPath: \(.*\)\/Platforms\/.*/\1/p')}"
if [ -z "$sdk" ] || [ ! -d "$sdk" ]; then
  sdk="$HOME/.swiftpm/swift-sdks/darwin.artifactbundle/Developer"
fi
mkdir -p "$core/dist"
cd "$core"

# The Swift runtime goes inside, so the computer needs no Swift of its own.
swift build -c release --product spacekeeper-backup --static-swift-stdlib \
  --build-system native --scratch-path .build-linux
strip -o dist/spacekeeper-backup-linux-x86_64 \
  .build-linux/x86_64-unknown-linux-gnu/release/spacekeeper-backup

# macOS has the Swift runtime built in; the linker signs the program ad hoc.
for arch in arm64 x86_64; do
  DEVELOPER_DIR="$sdk" swift build -c release --product spacekeeper-backup \
    --swift-sdk "$arch-apple-macosx" --build-system native --scratch-path .build-macos
  cp ".build-macos/$arch-apple-macosx/release/spacekeeper-backup" "dist/spacekeeper-backup-macos-$arch"
done

ls -l dist
