#!/bin/sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_image=${1:-"$root_dir/Resources/AppIcon.png"}
iconset_dir="$root_dir/work/AppIcon.iconset"
output_icon="$root_dir/Resources/AppIcon.icns"

mkdir -p "$iconset_dir" "$root_dir/Resources" "$root_dir/outputs/icon"

for size in 16 32 128 256 512; do
    retina_size=$((size * 2))
    /usr/bin/sips -z "$size" "$size" "$source_image" \
        --out "$iconset_dir/icon_${size}x${size}.png" >/dev/null
    /usr/bin/sips -z "$retina_size" "$retina_size" "$source_image" \
        --out "$iconset_dir/icon_${size}x${size}@2x.png" >/dev/null
done

/usr/bin/iconutil -c icns "$iconset_dir" -o "$output_icon"
cp "$output_icon" "$root_dir/outputs/icon/AppIcon.icns"
echo "Built $output_icon"
