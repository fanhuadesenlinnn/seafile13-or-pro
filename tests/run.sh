#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 -m unittest discover -s tests -v
bash -n init-seafile13ce.sh
bash -n init-seafile13pro-fixed-v2.sh
if command -v shellcheck >/dev/null; then
  shellcheck init-seafile13ce.sh init-seafile13pro-fixed-v2.sh tests/*.sh
fi
