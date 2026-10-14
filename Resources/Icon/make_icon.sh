#!/bin/zsh
# Regenerates Resources/AppIcon.icns from render_icon.swift.
set -euo pipefail
cd "$(dirname "$0")"
python3 make_mascot.py .
swift render_icon.swift .
SET=$(mktemp -d)/AppIcon.iconset
mkdir -p "$SET"
for s in 16 32 128 256 512; do
    sips -z $s $s legacy.png --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) legacy.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o ../AppIcon.icns
echo "Kész: Resources/AppIcon.icns"
