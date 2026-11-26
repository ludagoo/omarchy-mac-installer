#!/usr/bin/env bash
# The rename lint fails on a stray old name and passes the legacy-alias list.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 "$here/legacy_names_lint.py"
python3 "$here/legacy_names_lint.py" --self-test
echo "ok - legacy names lint"
