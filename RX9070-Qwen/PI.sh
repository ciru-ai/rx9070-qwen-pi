#!/usr/bin/env bash
# Run this from the project directory where Pi should work.
set -euo pipefail
launcher_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$launcher_dir/launch.py" --pi "$@"
