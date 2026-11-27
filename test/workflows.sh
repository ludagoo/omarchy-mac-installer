#!/usr/bin/env bash
# Every workflow is dispatch-only, or a workflow_call that a dispatch workflow uses.
# pull_request_target is forbidden as a trigger. Refusal strings inside a job stay.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT/.github/workflows" <<'PY'
import re
import sys
from pathlib import Path
import yaml

root = Path(sys.argv[1])
files = sorted(root.glob("*.yml"))
assert files, "no workflows"
allowed = {"workflow_dispatch", "workflow_call"}
forbidden = ("push", "pull_request", "pull_request_target", "schedule", "workflow_run", "release", "repository_dispatch")
callers = {}
texts = {}
for path in files:
    text = path.read_text(encoding="utf-8")
    texts[path.name] = text
    for match in re.findall(r"uses:\s*(\./\.github/workflows/\S+)", text):
        callers.setdefault(Path(match).name, []).append(path.name)

def on_map(data, name):
    on = data.get(True)
    if on is None:
        on = data.get("on")
    if not isinstance(on, dict):
        raise SystemExit(f"{name}: trigger is not a mapping: {on!r}")
    return on

for path in files:
    data = yaml.safe_load(texts[path.name])
    keys = list(on_map(data, path.name))
    if not keys or any(key not in allowed for key in keys):
        raise SystemExit(f"{path.name}: triggers must be workflow_dispatch and/or workflow_call, got {keys}")
    for word in forbidden:
        if word in keys:
            raise SystemExit(f"{path.name}: forbidden trigger {word}")
    if keys == ["workflow_call"] and path.name not in callers:
        raise SystemExit(f"{path.name}: workflow_call is not called by a dispatch workflow")

check = yaml.safe_load(texts["check.yml"])
job = check["jobs"]["check"]
if job.get("runs-on") != "ubuntu-latest":
    raise SystemExit("check.yml must run on ubuntu-latest")
if "secrets." in texts["check.yml"]:
    raise SystemExit("check.yml names a secret")
if "bash bin/test-ci.sh" not in texts["check.yml"]:
    raise SystemExit("check.yml does not run bin/test-ci.sh")
step = next(step for step in job["steps"] if str(step.get("uses", "")).startswith("actions/checkout@"))
if not re.search(r"uses: actions/checkout@[0-9a-f]{40} # v[0-9]", texts["check.yml"]):
    raise SystemExit("check.yml checkout is not pinned")
if (step.get("with") or {}).get("persist-credentials") is not False:
    raise SystemExit("check.yml checkout keeps credentials")
print(f"workflows: {len(files)} dispatch-only or called")
PY
echo ok
