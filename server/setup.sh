#!/bin/bash
set -euo pipefail
server_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
python_bin="${FVM_PYTHON:-python3}"
"$python_bin" -c 'import sys; assert sys.version_info >= (3, 11), "Python 3.11 or newer is required"'
if [[ ! -x "$server_dir/.venv/bin/python" ]]; then
  "$python_bin" -m venv "$server_dir/.venv"
fi
"$server_dir/.venv/bin/python" -m pip install -r "$server_dir/requirements.txt"
if (( $# )); then
  exec "$server_dir/.venv/bin/python" "$server_dir/configure_host.py" "$@"
fi
echo 'Ready. Start with server/run.sh; it binds only 127.0.0.1.'
