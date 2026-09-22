#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 -m unittest discover -s tests -v
bash -n init-seafile13ce.sh
if command -v shellcheck >/dev/null; then
  shellcheck init-seafile13ce.sh tests/*.sh
fi
