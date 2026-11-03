#!/bin/zsh
# Builds NativeImageStudio.app (Release) with xcodebuild and wraps the SwiftPM executable
# into an app bundle with its resource bundles (incl. MLX's Metal library).
set -uo pipefail
setopt null_glob
cd "$(dirname "$0")/.."
LOG=.build/xcode-app.log
mkdir -p .build
xcodebuild -scheme NativeImageStudio -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/xcode -configuration Release \
  -skipPackagePluginValidation -skipMacroValidation build > "$LOG" 2>&1
STATUS=$?
grep -E "(error|warning):" "$LOG" | grep -v "/SourcePackages/checkouts/\|/Vendor/\|/Intermediates.noindex/\|appintentsmetadataprocessor" | sort -u
grep -E "BUILD (SUCCEEDED|FAILED)" "$LOG"
[[ $STATUS -eq 0 ]] || exit $STATUS

PRODUCTS=.build/xcode/Build/Products/Release
APP=.build/NativeImageStudio.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PRODUCTS/NativeImageStudio" "$APP/Contents/MacOS/"
for b in "$PRODUCTS"/*.bundle; do cp -R "$b" "$APP/Contents/Resources/"; done
FRAMEWORKS=("$PRODUCTS"/PackageFrameworks/*.framework)
if (( ${#FRAMEWORKS} > 0 )); then
  mkdir -p "$APP/Contents/Frameworks"
  cp -R "${FRAMEWORKS[@]}" "$APP/Contents/Frameworks/"
fi
# App icon: drawn by scripts/make-icon.swift, regenerated only when the script changes.
ICON=.build/AppIcon.icns
if [[ ! -f "$ICON" || scripts/make-icon.swift -nt "$ICON" ]]; then
  rm -rf .build/AppIcon.iconset
  swift scripts/make-icon.swift .build/AppIcon.iconset && iconutil -c icns .build/AppIcon.iconset -o "$ICON" \
    || echo "warning: app icon not generated"
fi
[[ -f "$ICON" ]] && cp "$ICON" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Native Image Studio</string>
  <key>CFBundleDisplayName</key><string>Native Image Studio</string>
  <key>CFBundleIdentifier</key><string>dev.nativeimagestudio.app</string>
  <key>CFBundleExecutable</key><string>NativeImageStudio</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>2</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.graphics-design</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP" >/dev/null 2>&1
echo "App: $APP"
