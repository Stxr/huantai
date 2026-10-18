#!/bin/bash
# A branded, drag-to-install disk image. Finder writes portable .DS_Store layout metadata.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/../.." && pwd)"
task_app="${1:?请指定 .app 路径}"
task_output="${2:?请指定 DMG 输出路径}"
task_version="${3:?请指定版本}"
task_artwork="${4:?请指定 artwork.sh 输出目录}"
mkdir -p "$(dirname "$task_output")" "$task_root/.local"
task_work="$(mktemp -d "$task_root/.local/dmg.XXXXXX")"
task_mount="$task_work/mount"
cleanup() {
  if mount | grep -Fq " on $task_mount "; then
    if ! hdiutil detach "$task_mount" -quiet; then
      printf '请手动推出安装磁盘，保留临时目录: %s\n' "$task_work" >&2
      return
    fi
  fi
  rm -rf "$task_work"
}
trap cleanup EXIT
mkdir -p "$task_work/image/.background" "$task_mount"
ditto "$task_app" "$task_work/image/换台.app"
ln -s /Applications "$task_work/image/Applications"
cp "$task_artwork/background.png" "$task_work/image/.background/background.png"
cp "$task_artwork/Huantai.icns" "$task_work/image/.VolumeIcon.icns"
hdiutil create -srcfolder "$task_work/image" -volname "换台 $task_version" -fs HFS+ -format UDRW -ov "$task_work/layout.dmg" -quiet
hdiutil attach "$task_work/layout.dmg" -mountpoint "$task_mount" -nobrowse -quiet
SetFile -a C "$task_mount"
osascript - "$task_mount" <<'APPLESCRIPT'
on run argv
    set mountPath to item 1 of argv
    set volumeFolder to POSIX file mountPath as alias
    tell application "Finder"
        open volumeFolder
        set installerWindow to container window of volumeFolder
        set current view of installerWindow to icon view
        set toolbar visible of installerWindow to false
        set statusbar visible of installerWindow to false
        set bounds of installerWindow to {180, 160, 820, 588}
        set options to icon view options of installerWindow
        set arrangement of options to not arranged
        set icon size of options to 112
        set text size of options to 14
        set background picture of options to file ".background:background.png" of volumeFolder
        set position of item "换台.app" of volumeFolder to {170, 200}
        set position of item "Applications" of volumeFolder to {470, 200}
        update volumeFolder without registering applications
        delay 2
        close installerWindow
    end tell
end run
APPLESCRIPT
# Finder flushes the window layout on close; refuse an unstyled release.
if [ ! -s "$task_mount/.DS_Store" ]; then
  printf 'Finder 未保存安装窗口布局，停止打包。\n' >&2
  exit 1
fi
sync
hdiutil detach "$task_mount" -quiet
hdiutil convert "$task_work/layout.dmg" -format UDZO -imagekey zlib-level=9 -ov -o "$task_output" -quiet
hdiutil verify "$task_output" -quiet
printf '安装镜像: %s\n' "$task_output"
