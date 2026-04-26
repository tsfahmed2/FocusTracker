#!/bin/bash
#
# build-icon.sh — generate macOS AppIcon.icns from AppIcon.svg
#
# Requirements:
#   • librsvg (brew install librsvg)
#   • Xcode command-line tools (for iconutil)
#
# Usage:
#   ./build-icon.sh
#
# Output:
#   AppIcon.icns         — drop into Xcode's Assets.xcassets
#   AppIcon.iconset/     — intermediate folder (kept for inspection)

set -e

SVG="AppIcon.svg"
ICONSET="AppIcon.iconset"
ICNS="AppIcon.icns"

if [ ! -f "$SVG" ]; then
    echo "Error: $SVG not found in current directory."
    exit 1
fi

if ! command -v rsvg-convert &> /dev/null; then
    echo "Error: rsvg-convert not installed."
    echo "Install with: brew install librsvg"
    exit 1
fi

# Clean previous build
rm -rf "$ICONSET" "$ICNS"
mkdir "$ICONSET"

echo "Generating PNG sizes from $SVG..."

# macOS .iconset requires these exact sizes and filenames.
# The 1x and 2x variants ship together so the OS can pick the right one
# for Retina vs non-Retina displays.
sizes=(
    "16    icon_16x16.png"
    "32    icon_16x16@2x.png"
    "32    icon_32x32.png"
    "64    icon_32x32@2x.png"
    "128   icon_128x128.png"
    "256   icon_128x128@2x.png"
    "256   icon_256x256.png"
    "512   icon_256x256@2x.png"
    "512   icon_512x512.png"
    "1024  icon_512x512@2x.png"
)

for entry in "${sizes[@]}"; do
    size=$(echo "$entry" | awk '{print $1}')
    name=$(echo "$entry" | awk '{print $2}')
    rsvg-convert -w "$size" -h "$size" "$SVG" -o "$ICONSET/$name"
    echo "  ✓ $name (${size}×${size})"
done

echo ""
echo "Packaging into .icns..."
iconutil -c icns "$ICONSET" -o "$ICNS"

echo ""
echo "Done. Output: $ICNS"
echo ""
echo "Next steps:"
echo "  1. Open Xcode → click Assets.xcassets in the navigator"
echo "  2. Click AppIcon (or create one if missing)"
echo "  3. Drag AppIcon.icns onto the asset slot, OR drag individual"
echo "     PNGs from $ICONSET into the size-specific slots"
echo "  4. Build and run — your icon should appear in /Applications"
