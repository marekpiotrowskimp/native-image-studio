#!/bin/zsh
# Builds the PoC CLI with xcodebuild so MLX's Metal shaders (mlx.metallib) are compiled.
# Requires the Metal Toolchain component: xcodebuild -downloadComponent MetalToolchain
set -uo pipefail
cd "$(dirname "$0")/.."
LOG=.build/xcode-build.log
mkdir -p .build
xcodebuild -scheme nis-poc -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/xcode -configuration Release \
  -skipPackagePluginValidation -skipMacroValidation build "$@" > "$LOG" 2>&1
STATUS=$?
# Diagnostics from our code only (dependencies and vendored code excluded).
grep -E "(error|warning):" "$LOG" | grep -v "/SourcePackages/checkouts/\|/Vendor/\|/Intermediates.noindex/" | sort -u
grep -E "BUILD (SUCCEEDED|FAILED)" "$LOG"
exit $STATUS
