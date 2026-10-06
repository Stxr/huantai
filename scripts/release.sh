#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
task_version="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' scripts/Info.plist)}"
task_version="${task_version#v}"
if [ "$#" -gt 1 ] || ! [[ "$task_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf '用法: scripts/release.sh [v主版本.次版本.补丁版本]\n' >&2
  exit 1
fi
if [ "$(uname -m)" != "arm64" ]; then
  printf '请在 Apple Silicon Mac 上构建 ARM64 版本。\n' >&2
  exit 1
fi
task_tag="v$task_version"
mkdir -p "$task_root/.local" "$task_root/dist"
task_work="$(mktemp -d "$task_root/.local/release-$task_version.XXXXXX")"
trap 'rm -rf "$task_work"' EXIT
export CLANG_MODULE_CACHE_PATH="$task_root/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$task_root/.build/swift-module-cache"
task_swift_args=(--configuration release --arch arm64 --scratch-path "$task_root/.build/release-arm64"
  --cache-path "$task_root/.build/cache" --config-path "$task_root/.build/config"
  --security-path "$task_root/.build/security" --disable-netrc --disable-keychain
  -Xswiftc -gnone -Xswiftc -file-prefix-map -Xswiftc "$task_root=/src/huantai")
swift build "${task_swift_args[@]}"
task_bin="$(swift build "${task_swift_args[@]}" --show-bin-path)"
task_image="$task_work/image"
task_app="$task_image/换台.app"
task_cli_name="huantai-cli-$task_tag-macos-arm64"
task_cli="$task_work/$task_cli_name"
mkdir -p "$task_app/Contents/MacOS" "$task_cli"
cp "$task_bin/HuantaiApp" "$task_app/Contents/MacOS/HuantaiApp"
cp "$task_bin/ht" "$task_cli/ht"
cp scripts/Info.plist "$task_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $task_version" "$task_app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $task_version" "$task_app/Contents/Info.plist"
for task_executable in "$task_app/Contents/MacOS/HuantaiApp" "$task_cli/ht"; do
  if [ "$(lipo -archs "$task_executable")" != "arm64" ]; then
    printf '产物架构核验失败: %s\n' "$task_executable" >&2
    exit 1
  fi
  strip -S "$task_executable"
done
task_signing="${HUANTAI_SIGNING_IDENTITY:--}"
task_sign_args=(--force --sign "$task_signing" --options runtime)
if [ "$task_signing" != "-" ]; then task_sign_args+=(--timestamp); fi
codesign "${task_sign_args[@]}" "$task_cli/ht"
codesign "${task_sign_args[@]}" "$task_app"
codesign --verify --strict "$task_cli/ht"
codesign --verify --deep --strict "$task_app"
cat > "$task_cli/README.txt" <<'EOF'
换台 ht · macOS ARM64

macOS 14 及以上。运行 ./ht --help 查看命令。
默认状态目录: ~/Library/Application Support/huantai
可用 HUANTAI_HOME 覆盖，与 App 使用相同目录可共享收藏和完成状态。

项目: https://github.com/Stxr/huantai
EOF
ln -s /Applications "$task_image/Applications"
task_dmg="huantai-$task_tag-macos-arm64.dmg"
task_archive="$task_cli_name.tar.gz"
hdiutil create -srcfolder "$task_image" -volname "换台 $task_tag" -format UDZO \
  -ov "$task_root/dist/$task_dmg"
tar --no-mac-metadata -czf "$task_root/dist/$task_archive" -C "$task_work" "$task_cli_name"
(
  cd "$task_root/dist"
  shasum -a 256 "$task_dmg" "$task_archive" > SHA256SUMS.txt
)
printf 'ARM64 发布产物位于 %s/dist/\n' "$task_root"
