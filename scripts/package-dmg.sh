#!/bin/bash
set -euo pipefail
app_path="$1"
dmg_path="$2"
volume_name="${3:-Stratovo}"
script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/stratovo-dmg.XXXXXX")"
mount_dir="$work_dir/mounted"
cleanup() {
  if mount | /usr/bin/grep -Fq " on $mount_dir "; then /usr/bin/hdiutil detach "$mount_dir" -quiet || true; fi
  rm -rf "$work_dir"
}
trap cleanup EXIT
mkdir -p "$work_dir/stage/.background" "$mount_dir"
/usr/bin/ditto "$app_path" "$work_dir/stage/Stratovo.app"
ln -s /Applications "$work_dir/stage/Applications"
cp "$script_dir/../LICENSE" "$work_dir/stage/LICENSE"
cat > "$work_dir/stage/Bitte_zuerst_lesen.txt" <<'TEXT'
Stratovo — Public beta / Private test channel

Stratovo.app auf Applications ziehen und anschließend unter Programme öffnen.
Drag Stratovo.app to Applications, then open it from Applications.

macOS 14+ · Apple Silicon · Free & open source
Ad-hoc signed; not Developer ID signed or notarized.
Release notes: https://github.com/PwnedG0blin/Stratovo/releases
Website: https://pwnedg0blin.pages.dev/
TEXT
xcrun swift "$script_dir/dmg-background.swift" "$work_dir/stage/.background/background.png" "$app_path/Contents/Resources/Stratovo.icns"
python3 -m venv "$work_dir/tools"
"$work_dir/tools/bin/python" -m pip install --quiet --disable-pip-version-check ds_store==1.3.3 mac_alias==2.2.3
/usr/bin/hdiutil create -volname "$volume_name" -srcfolder "$work_dir/stage" -ov -format UDRW "$work_dir/layout.dmg" -quiet
/usr/bin/hdiutil attach "$work_dir/layout.dmg" -mountpoint "$mount_dir" -nobrowse -quiet
"$work_dir/tools/bin/python" "$script_dir/dmg-layout.py" "$mount_dir"
test -f "$mount_dir/.DS_Store"
test -f "$mount_dir/.background/background.png"
/usr/bin/hdiutil detach "$mount_dir" -quiet
/usr/bin/hdiutil convert "$work_dir/layout.dmg" -format UDZO -ov -o "$dmg_path" -quiet
/usr/bin/hdiutil verify "$dmg_path" -quiet
