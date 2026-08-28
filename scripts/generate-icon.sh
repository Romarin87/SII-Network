#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
source_png="${1:-$project_dir/Resources/AppIcon.png}"
output_icns="${2:-$project_dir/Resources/AppIcon.icns}"

if [[ ! -f "$source_png" ]]; then
    echo "Missing icon source: $source_png" >&2
    exit 1
fi

image_format="$(/usr/bin/sips -g format "$source_png" 2>/dev/null | /usr/bin/awk '/format:/ { print $2 }')"
pixel_width="$(/usr/bin/sips -g pixelWidth "$source_png" 2>/dev/null | /usr/bin/awk '/pixelWidth:/ { print $2 }')"
pixel_height="$(/usr/bin/sips -g pixelHeight "$source_png" 2>/dev/null | /usr/bin/awk '/pixelHeight:/ { print $2 }')"

if [[ "$image_format" != "png" || "$pixel_width" != <-> || "$pixel_height" != <-> ]]; then
    echo "Icon source must be a readable PNG: $source_png" >&2
    exit 1
fi

if [[ "$pixel_width" != "$pixel_height" || "$pixel_width" -lt 1024 ]]; then
    echo "Icon source must be a square PNG at least 1024 x 1024 pixels: $source_png" >&2
    exit 1
fi

temporary_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/sii-network-icon.XXXXXX")"
trap '/bin/rm -rf "$temporary_dir"' EXIT

iconset_dir="$temporary_dir/AppIcon.iconset"
generated_icns="$temporary_dir/AppIcon.icns"
/bin/mkdir -p "$iconset_dir" "${output_icns:h}"

write_icon() {
    local logical_size="$1"
    local scale="$2"
    local pixel_size=$(( logical_size * scale ))
    local filename="icon_${logical_size}x${logical_size}"

    if (( scale == 2 )); then
        filename="${filename}@2x"
    fi

    /usr/bin/sips \
        --resampleHeightWidth "$pixel_size" "$pixel_size" \
        "$source_png" \
        --out "$iconset_dir/$filename.png" >/dev/null
}

write_icon 16 1
write_icon 16 2
write_icon 32 1
write_icon 32 2
write_icon 128 1
write_icon 128 2
write_icon 256 1
write_icon 256 2
write_icon 512 1
write_icon 512 2

/usr/bin/iconutil --convert icns "$iconset_dir" --output "$generated_icns"
/bin/cp "$generated_icns" "$output_icns"

echo "$output_icns"
