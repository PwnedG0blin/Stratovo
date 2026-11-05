#!/bin/bash
set -Eeuo pipefail
phase="initialization"
trap 'status=$?; printf "DMG packaging failed during %s (line %s, exit %s): %s\n" "$phase" "$LINENO" "$status" "$BASH_COMMAND" >&2; exit "$status"' ERR
app_path="$1"
dmg_path="$2"
volume_name="${3:-Stratovo}"
script_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/stratovo-dmg.XXXXXX")"
mount_dir="$work_dir/mounted"
attached=0
cleanup() {
  if [[ "$attached" == 1 ]]; then /usr/bin/hdiutil detach "$mount_dir" -quiet || true; fi
  rm -rf "$work_dir"
}
trap cleanup EXIT
phase="stage app and installation files"
mkdir -p "$work_dir/stage/.background" "$mount_dir"
/usr/bin/ditto "$app_path" "$work_dir/stage/Stratovo.app"
ln -s /Applications "$work_dir/stage/Applications"
cp "$script_dir/../LICENSE" "$work_dir/stage/.background/LICENSE"
phase="render shared light installation background"
python3 "$script_dir/dmg-background.py" "$work_dir/stage/.background/background.png"
phase="create writable HFS+ image"
# Reserve space for Finder metadata written after the staged files are copied.
stage_kib="$(du -sk "$work_dir/stage" | awk '{print $1}')"
image_mib="$(( (stage_kib + stage_kib / 5 + 1023) / 1024 + 64 ))"
/usr/bin/hdiutil create -volname "$volume_name" -fs HFS+ -size "${image_mib}m" -srcfolder "$work_dir/stage" -ov -format UDRW "$work_dir/layout.dmg"
phase="mount writable image"
/usr/bin/hdiutil attach "$work_dir/layout.dmg" -mountpoint "$mount_dir" -readwrite -nobrowse
attached=1
phase="configure and verify Finder layout"
/usr/bin/osascript "$script_dir/finder-layout.applescript" "$mount_dir" configure
test -f "$mount_dir/.DS_Store"
test -f "$mount_dir/.background/background.png"
sync
phase="unmount writable image"
/usr/bin/hdiutil detach "$mount_dir"
attached=0
phase="compress distribution image"
/usr/bin/hdiutil convert "$work_dir/layout.dmg" -format UDZO -ov -o "$dmg_path"
phase="verify distribution image"
/usr/bin/hdiutil verify "$dmg_path"
/usr/bin/hdiutil attach "$dmg_path" -mountpoint "$mount_dir" -readonly -nobrowse
attached=1
/usr/bin/osascript "$script_dir/finder-layout.applescript" "$mount_dir" verify
/usr/bin/hdiutil detach "$mount_dir"
attached=0
