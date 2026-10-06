#!/usr/bin/env bash
set -euo pipefail
PET_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export IDF_TOOLS_PATH="${PET_ROOT}/.local/idf-tools"
PET_PYTHON_ENV="${IDF_TOOLS_PATH}/python_env/idf5.5_py3.12_env/bin"
if [[ -x "${PET_PYTHON_ENV}/python3" ]]; then export PATH="${PET_PYTHON_ENV}:${PATH}"; fi
if [[ ! -f "${PET_ROOT}/.local/toolchains/esp-idf/export.sh" ]]; then
    echo "Install ESP-IDF 5.5.3 into pets/.local/toolchains/esp-idf first." >&2
    exit 1
fi
source "${PET_ROOT}/.local/toolchains/esp-idf/export.sh"
cd "${PET_ROOT}/firmware"
if [[ $# == 0 ]]; then exec ./tools/validate.sh --all; else exec ./tools/validate.sh "$@"; fi
