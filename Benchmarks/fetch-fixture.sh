#!/usr/bin/env bash
# Downloads a real TreeHerder job payload to use as a benchmark fixture.
# Usage: ./fetch-fixture.sh [output-path] [push-id]
set -euo pipefail
OUT="${1:-/tmp/push.json}"
PUSH_ID="${2:-}"

if [[ -z "$PUSH_ID" ]]; then
  echo "Finding the largest recent try push…"
  PUSH_ID=$(curl -fsS "https://treeherder.mozilla.org/api/project/try/push/?count=20" \
    | python3 -c 'import json,sys; print(max(p["id"] for p in json.load(sys.stdin)["results"]))')
fi

URL="https://treeherder.mozilla.org/api/project/try/jobs/?push_id=${PUSH_ID}&count=2000&return_type=list&exclusion_profile=false"
curl -fsS "$URL" -o "$OUT"
python3 - "$OUT" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
print(f"wrote {sys.argv[1]}: {len(d.get('results',[]))} jobs, {len(d.get('job_property_names',[]))} columns")
PY
