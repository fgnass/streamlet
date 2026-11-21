#!/bin/zsh
# Renders every image that shows the 3D icon from design/Streamlet.blend (Cycles, CPU).
# DockTile.png shows only the base plate and is not rendered here.
#   design/render-assets.sh            all images (the website animation takes about 25 minutes)
#   design/render-assets.sh icon       only the app icon and its sizes
set -euo pipefail
cd "${0:A:h}/.."
BLENDER="${BLENDER:-/Applications/Blender.app/Contents/MacOS/Blender}"
BLEND=design/Streamlet.blend
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
render() { "$BLENDER" -b "$BLEND" -P design/render_setup.py "${@:4}" -- "$1" "$2" "$3" >/dev/null; }

# App icon: last frame at 1024 px; all smaller sizes are scaled down with sips.
render 1024 1 "$TMP/icon" -f 55
ICON="$TMP/icon0055.png"
SET="$TMP/AppIcon.iconset"; mkdir -p "$SET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$ICON" --out "$SET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) "$ICON" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Streamlet/Assets/AppIcon.icns
sips -z 256 256 "$ICON" --out Streamlet/Assets/ChooserIcon.png >/dev/null
sips -z 256 256 "$ICON" --out docs/assets/apple-touch-icon.png >/dev/null
sips -z 64 64 "$ICON" --out docs/assets/favicon.png >/dev/null
sips -z 512 512 "$ICON" --out docs/assets/img/icon-512.png >/dev/null
cwebp -quiet -q 90 docs/assets/img/icon-512.png -o docs/assets/img/icon-512.webp
echo "Rendered the app icon"
[[ "${1:-}" == icon ]] && exit 0

# Build-up animation in the app: 55 frames at 256 px
render 256 1 "$PWD/Streamlet/Assets/IconAnimation/###" -a
echo "Rendered Streamlet/Assets/IconAnimation"

# Build-up animation on the website: 55 frames at 1280 px with a wider camera
render 1280 2 "$TMP/flight/###" -a
for f in "$TMP"/flight/*.png; do
  cwebp -quiet -q 80 "$f" -o "docs/assets/flight/$(basename "$f" .png).webp"
done
echo "Rendered docs/assets/flight"
