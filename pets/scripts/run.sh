#!/bin/sh
set -eu
PET_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export PYTHONPATH="$PET_ROOT/host${PYTHONPATH:+:$PYTHONPATH}"
PET_PYTHON="python3"
if [ -x "$PET_ROOT/.local/ble-env/bin/python" ]; then PET_PYTHON="$PET_ROOT/.local/ble-env/bin/python"; fi
exec "$PET_PYTHON" -m token_pet.app "$@"
