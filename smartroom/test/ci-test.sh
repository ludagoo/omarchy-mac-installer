#!/bin/bash
# The SmartRoom CI workflow guards the shipped branches with the suites the
# fork carries, and runs without secrets or write access.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
wf=$here/../../.github/workflows/smartroom-ci.yml
bad() { echo "FAIL ci: $*" >&2; exit 1; }
[[ -f $wf ]] || bad "no .github/workflows/smartroom-ci.yml"
python3 - "$wf" <<'PY' || bad "the workflow is not workflow_dispatch only"
import re, sys
text = open(sys.argv[1]).read()
on = re.search(r"^on:\n((?:[ \t].*\n|\n)*)", text, re.M)
keys = re.findall(r"^  ([a-z_]+):", on.group(1), re.M) if on else []
assert keys == ["workflow_dispatch"], keys
for word in ("push", "pull_request", "pull_request_target", "schedule", "workflow_run"):
    assert word not in keys, word
PY
grep -qx '  contents: read' "$wf" || bad "the workflow reads only"
! grep -qE 'secrets\.|pull_request_target|contents: write|id-token' "$wf" || bad "the workflow uses no secrets and no write token"
! grep -q 'persist-credentials: true' "$wf" && [[ $(grep -c 'persist-credentials: false' "$wf") == "$(grep -c 'actions/checkout@' "$wf")" ]] ||
  bad "no checkout keeps credentials"
! grep -E 'uses: [^ ]+@' "$wf" | grep -vqE '@[0-9a-f]{40} ' || bad "every action is pinned to a commit"
grep -q 'bash image-builder/test/all' "$wf" && grep -q 'bash omarchy-mac-installer/smartroom/test/all' "$wf" ||
  bad "the workflow runs image-builder/test/all and smartroom/test/all"
grep -qE '^  PKGS_REF: smartroom/(main|edge)$' "$wf" || bad "the boot leaves come from a SmartRoom pkgs line"
echo "ok - smartroom-ci.yml runs the fork's suites on workflow_dispatch without secrets"
