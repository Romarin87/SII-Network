#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
app_dir="$project_dir/build/NetWatchSII.app"
contents_dir="$app_dir/Contents"
helper_source="$project_dir/Tools/sii_srun_autologin.py"
info_plist="$project_dir/Resources/Info.plist"
icon_source="$project_dir/Resources/AppIcon.png"
icon_resource="$project_dir/Resources/AppIcon.icns"
icon_generator="$project_dir/scripts/generate-icon.sh"

if [[ ! -f "$helper_source" ]]; then
    echo "Missing SRun helper: $helper_source" >&2
    exit 1
fi

if [[ ! -x "$icon_generator" ]]; then
    echo "Missing executable icon generator: $icon_generator" >&2
    exit 1
fi

bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")"

"$icon_generator" "$icon_source" "$icon_resource" >/dev/null
swift build -c release --package-path "$project_dir"

/bin/rm -rf "$app_dir"
/bin/mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
/bin/cp "$project_dir/.build/release/NetWatchSII" "$contents_dir/MacOS/NetWatchSII"
/bin/cp "$info_plist" "$contents_dir/Info.plist"

/bin/cp "$icon_resource" "$contents_dir/Resources/AppIcon.icns"
/bin/cp "$helper_source" "$contents_dir/Resources/sii_srun_autologin.py"

/bin/chmod 755 "$contents_dir/MacOS/NetWatchSII"
/usr/bin/strip -S "$contents_dir/MacOS/NetWatchSII"
/usr/bin/codesign --force --deep --sign - --identifier "$bundle_identifier" "$app_dir"

echo "$app_dir"
