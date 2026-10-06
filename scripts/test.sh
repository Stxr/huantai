#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$task_root"
export CLANG_MODULE_CACHE_PATH="$task_root/.build/clang-module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$task_root/.build/swift-module-cache"
swift test --cache-path "$task_root/.build/cache" --config-path "$task_root/.build/config" \
  --security-path "$task_root/.build/security" --disable-netrc --disable-keychain "$@"
