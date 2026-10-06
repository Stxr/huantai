#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_app="$task_root/build/换台.app"
if [ ! -x "$task_app/Contents/MacOS/HuantaiApp" ]; then
  printf '请先运行 scripts/build.sh\n' >&2
  exit 1
fi
export HUANTAI_HOME="${HUANTAI_HOME:-$task_root/.local/state}"
# This local development launch shares its private index with bin/ht.
task_env_args=(--env "HUANTAI_HOME=$HUANTAI_HOME")
for task_env in HUANTAI_CODEX_HOME HUANTAI_BOTMUX_HOME HUANTAI_TEST_MODE; do
  if [ -n "${!task_env:-}" ]; then
    task_env_args+=(--env "$task_env=${!task_env}")
  fi
done
exec open -a "$task_app" "${task_env_args[@]}" --args --show "$@"
