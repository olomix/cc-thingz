#!/usr/bin/env bash
# Regenerate AppIcon.icns from AppIcon.svg. Dev-only: the .icns is
# committed and never built at install time. Needs macOS 14+ (SVG in NSImage).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

master="$work/icon-1024.png"
xcrun swift "$here/make-icon.swift" "$here/AppIcon.svg" "$master" 1024

iconset="$work/AppIcon.iconset"
mkdir "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$master" \
    --out "$iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$master" \
    --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns -o "$here/AppIcon.icns" "$iconset"
echo "wrote $here/AppIcon.icns"
