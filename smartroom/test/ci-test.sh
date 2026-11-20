#!/bin/bash
# The SmartRoom CI workflow guards the shipped branches with the suites the
# fork carries, and runs without secrets or write access.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
wf=$here/../../.github/workflows/smartroom-ci.yml
bad() { echo "FAIL ci: $*" >&2; exit 1; }
[[ -f $wf ]] || bad "no .github/workflows/smartroom-ci.yml"
grep -qx "    branches: \[smartroom/main, smartroom/edge, 'fix/\*\*'\]" "$wf" || bad "pushes to smartroom/main, smartroom/edge and fix/** run the checks"
grep -qx '  contents: read' "$wf" || bad "the workflow reads only"
! grep -qE 'secrets\.|pull_request_target|contents: write|id-token' "$wf" || bad "the workflow uses no secrets and no write token"
! grep -q 'persist-credentials: true' "$wf" && [[ $(grep -c 'persist-credentials: false' "$wf") == "$(grep -c 'actions/checkout@' "$wf")" ]] ||
  bad "no checkout keeps credentials"
! grep -E 'uses: [^ ]+@' "$wf" | grep -vqE '@[0-9a-f]{40} ' || bad "every action is pinned to a commit"
grep -q 'bash image-builder/test/all' "$wf" && grep -q 'bash omarchy-mac-installer/smartroom/test/all' "$wf" ||
  bad "the workflow runs image-builder/test/all and smartroom/test/all"
grep -qE '^  PKGS_REF: smartroom/(main|edge)$' "$wf" || bad "the boot leaves come from a SmartRoom pkgs line"
echo "ok - smartroom-ci.yml runs the fork's suites on the shipped branches without secrets"
