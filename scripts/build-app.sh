#!/bin/sh
# Builds Doppio.app with SwiftPM only (no Xcode needed) and signs it ad hoc.
# Usage: scripts/build-app.sh [output-folder]   (default: build/)
set -eu
cd "$(dirname "$0")/.."
out=${1:-build}
version=$(sed -n 's/.*public static let version = "\(.*\)".*/\1/p' Sources/DoppioCore/Report/AuditReport.swift)

swift build -c release --product DoppioApp
bin=$(swift build -c release --product DoppioApp --show-bin-path)/DoppioApp

app="$out/Doppio.app"
staging="$out/.Doppio.app.new"
# Assemble in a staging folder, then swap it in, so a failed build never leaves a
# half-built app behind. (Only this script's own build output is replaced here.)
mkdir -p "$out"
rm -rf "$staging"
mkdir -p "$staging/Contents/MacOS" "$staging/Contents/Resources"
cp "$bin" "$staging/Contents/MacOS/Doppio"
sed "s/__VERSION__/$version/g" App/Info.plist > "$staging/Contents/Info.plist"
cp App/Doppio.icns "$staging/Contents/Resources/Doppio.icns"
printf 'APPL????' > "$staging/Contents/PkgInfo"
codesign --force --sign - --timestamp=none "$staging"
codesign --verify --strict "$staging"
rm -rf "$app"
mv "$staging" "$app"
echo "Built $app (version $version, ad-hoc signed)"
