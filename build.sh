#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")" && pwd)"
cd "$project_root"
compiler="${MORNINGTEN_SWIFTC:-$(xcrun -f swiftc)}"
sdk_path="${MORNINGTEN_SDK:-$(xcrun --sdk macosx --show-sdk-path)}"
lipo_tool="${MORNINGTEN_LIPO:-$(xcrun -f lipo)}"
mkdir -p build dist
common=(-swift-version 5 -parse-as-library -sdk "$sdk_path" -module-cache-path "$project_root/build/module-cache")
"$compiler" "${common[@]}" Sources/Models.swift Sources/Feeds.swift Sources/Verification.swift Tests/SelfTests.swift -framework PDFKit -o build/MorningTenTests
build/MorningTenTests Resources/feeds.json
app_bundle="dist/晨间十条.app"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"
for architecture in arm64 x86_64; do
  mkdir -p "build/$architecture"
  "$compiler" "${common[@]}" -O -whole-module-optimization -target "$architecture-apple-macos15.0" \
    Sources/Models.swift Sources/Feeds.swift Sources/Verification.swift Sources/Store.swift Sources/App.swift \
    -framework AppKit -framework SwiftUI -framework UserNotifications -framework ServiceManagement -framework Translation -framework PDFKit \
    -o "build/$architecture/MorningTen"
done
"$lipo_tool" -create build/arm64/MorningTen build/x86_64/MorningTen -output "$app_bundle/Contents/MacOS/MorningTen"
cp Resources/Info.plist "$app_bundle/Contents/Info.plist"
cp Resources/feeds.json Resources/AppIcon.icns "$app_bundle/Contents/Resources/"
source_bundle="$app_bundle/Contents/Resources/Source"
mkdir -p "$source_bundle"
cp -R Sources Resources Tests build.sh README.md "$source_bundle/"
chmod 755 "$app_bundle/Contents/MacOS/MorningTen"
codesign --force --deep --sign - "$app_bundle"
codesign --verify --deep --strict "$app_bundle"
ditto -c -k --norsrc --noextattr --keepParent "$app_bundle" dist/晨间十条.app.zip
shasum -a 256 dist/晨间十条.app.zip > dist/SHA256SUMS
