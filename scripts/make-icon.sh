#!/bin/sh
# Regenerates App/Doppio.icns from scripts/make-icon.swift. Only needed when the icon changes;
# the .icns is committed so building the app doesn't depend on it.
set -eu
cd "$(dirname "$0")/.."
work=$(mktemp -d)
swift scripts/make-icon.swift "$work/icon-1024.png"
set_dir="$work/Doppio.iconset"
mkdir "$set_dir"
for size in 16 32 128 256 512; do
  sips -z $size $size "$work/icon-1024.png" --out "$set_dir/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$work/icon-1024.png" --out "$set_dir/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$set_dir" -o App/Doppio.icns
echo "Wrote App/Doppio.icns"
