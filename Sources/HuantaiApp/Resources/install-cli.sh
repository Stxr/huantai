#!/bin/bash
# Shared by Settings and the copyable terminal command. Never requires sudo.
set -euo pipefail
task_resources="$(cd "$(dirname "$0")" && pwd)"
task_cli="$(cd "$task_resources/../MacOS" && pwd)/ht"
task_bin="$HOME/.local/bin"
task_shell="${SHELL:-$(dscl . -read /Users/"$(id -un)" UserShell | awk '{print $2}')}"
task_profile=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --bin-dir|--profile|--shell)
      [ "$#" -ge 2 ] || { printf '缺少路径参数\n' >&2; exit 1; }
      case "$1" in --bin-dir) task_bin="$2" ;; --profile) task_profile="$2" ;; --shell) task_shell="$2" ;; esac
      shift 2 ;;
    *) printf '未知参数: %s\n' "$1" >&2; exit 1 ;;
  esac
done
case "$task_shell" in
  */bash) task_profile="${task_profile:-$HOME/.bash_profile}" ;;
  */zsh) task_profile="${task_profile:-$HOME/.zshrc}" ;;
  */fish) task_profile="${task_profile:-${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d/huantai-cli.fish}" ;;
  *) printf '暂不支持自动配置此 Shell，请将 App 内的 ht 加入 PATH。\n' >&2; exit 1 ;;
esac
[ -x "$task_cli" ] || { printf '应用内未找到 ht，请重新安装完整的换台 App。\n' >&2; exit 1; }
case "$task_cli" in /Volumes/*) printf '请先将换台拖入应用程序，再安装命令行工具。\n' >&2; exit 1 ;; esac
# Do not replace another tool, including a dangling symlink.
if [ -e "$task_bin/ht" ] || [ -L "$task_bin/ht" ]; then
  if [ ! -L "$task_bin/ht" ] || [ "$(readlink "$task_bin/ht")" != "$task_cli" ]; then
    printf '%s 已存在其他 ht，请先移动它或选择其他安装位置。\n' "$task_bin" >&2
    exit 1
  fi
fi
# Quote the path for the user's shell, including spaces and apostrophes.
task_quoted="$(printf '%s' "$task_bin" | sed "s/'/'\\\\''/g")"
task_export="export PATH='$task_quoted':\"\$PATH\""
if [[ "$task_shell" == */fish ]]; then task_export="fish_add_path --path '$task_quoted'"; fi
mkdir -p "$task_bin" "$(dirname "$task_profile")"
if ! grep -Fqx "$task_export" "$task_profile" 2>/dev/null; then
  if [ -e "$task_profile" ]; then
    task_backup="$(mktemp "$task_profile.huantai-backup.XXXXXX")"
    cp -p "$task_profile" "$task_backup"
  fi
  printf '\n# Huantai CLI\n%s\n' "$task_export" >> "$task_profile"
fi
if [ ! -L "$task_bin/ht" ]; then ln -s "$task_cli" "$task_bin/ht"; fi
printf 'ht 已安装到 %s/ht\nPATH 已配置到 %s\n新开终端后运行 ht --help。\n' "$task_bin" "$task_profile"
