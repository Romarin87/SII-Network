#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h}"
app_dir="$project_dir/build/NetWatchSII.app"
contents_dir="$app_dir/Contents"
helper_source="$project_dir/Tools/sii_srun_autologin.py"

if [[ ! -f "$helper_source" ]]; then
    echo "Missing SRun helper: $helper_source" >&2
    exit 1
fi

swift build -c release --package-path "$project_dir"

/bin/rm -rf "$app_dir"
/bin/mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
/bin/cp "$project_dir/.build/release/NetWatchSII" "$contents_dir/MacOS/NetWatchSII"
/bin/cp "$project_dir/Resources/Info.plist" "$contents_dir/Info.plist"

/bin/cp "$helper_source" "$contents_dir/Resources/sii_srun_autologin.py"

/bin/chmod 755 "$contents_dir/MacOS/NetWatchSII"
/usr/bin/codesign --force --deep --sign - --identifier cn.edu.sii.NetWatchSII "$app_dir"

echo "$app_dir"
