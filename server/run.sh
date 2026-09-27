#!/bin/bash
set -euo pipefail
server_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -x "$server_dir/.venv/bin/python" ]]; then
  echo 'Run server/setup.sh first.' >&2
  exit 1
fi
exec "$server_dir/.venv/bin/python" "$server_dir/main.py" "$@"
