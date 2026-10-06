#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
export CLANG_MODULE_CACHE_PATH="$task_root/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$task_root/.build/swift-module-cache"
swift build --cache-path "$task_root/.build/cache" --config-path "$task_root/.build/config" \
  --security-path "$task_root/.build/security" --disable-netrc --disable-keychain "$@"
task_app="$task_root/build/换台.app"
mkdir -p "$task_app/Contents/MacOS"
cp .build/debug/HuantaiApp "$task_app/Contents/MacOS/HuantaiApp.new"
mv -f "$task_app/Contents/MacOS/HuantaiApp.new" "$task_app/Contents/MacOS/HuantaiApp"
cp scripts/Info.plist "$task_app/Contents/Info.plist"
codesign --force --sign - "$task_app"
printf '本地 App: %s\nCLI: %s\n' "$task_app" "$task_root/bin/ht"
