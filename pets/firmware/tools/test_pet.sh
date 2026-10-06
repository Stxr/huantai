#!/usr/bin/env bash
set -euo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
test_dir="${1:-$(mktemp -d /tmp/token-pet-tests.XXXXXX)}"
cjson_root="${IDF_PATH:-${root}/../.local/toolchains/esp-idf}/components/json/cJSON"
"${CC:-cc}" -std=c11 -Wall -Wextra -Werror -I"${root}/main" -I"${cjson_root}" \
    "${root}/tests/test_pet.c" "${root}/main/pet_model.c" "${root}/main/pet_protocol.c" "${root}/main/pet_stream.c" "${root}/main/pet_game.c" "${root}/main/pet_preferences.c" "${cjson_root}/cJSON.c" -lm -o "${test_dir}/test_pet"
"${test_dir}/test_pet"
"${CC:-cc}" -std=c11 -Wall -Wextra -Werror -I"${root}/main" \
    "${root}/tests/test_pet_sound.c" "${root}/main/pet_sound.c" "${root}/main/pet_preferences.c" -o "${test_dir}/test_pet_sound"
"${test_dir}/test_pet_sound"
PYTHONPATH="${root}/../host" PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s "${root}/../tests"
if [[ $# == 0 ]]; then rm -rf -- "${test_dir}"; fi
