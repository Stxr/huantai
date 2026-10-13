#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/../.." && pwd)"
task_output="${1:?请指定资源输出目录}"
mkdir -p "$task_output/Huantai.iconset"
swift "$task_root/scripts/packaging/Artwork.swift" "$task_output"
for task_size in 16 32 128 256 512; do
  sips -z "$task_size" "$task_size" "$task_output/icon-1024.png" --out "$task_output/Huantai.iconset/icon_${task_size}x${task_size}.png" >/dev/null
  task_retina=$((task_size * 2))
  sips -z "$task_retina" "$task_retina" "$task_output/icon-1024.png" --out "$task_output/Huantai.iconset/icon_${task_size}x${task_size}@2x.png" >/dev/null
done
iconutil -c icns "$task_output/Huantai.iconset" -o "$task_output/Huantai.icns"
