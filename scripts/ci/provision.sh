#!/usr/bin/env bash
set -euo pipefail
plan_and_apply() {
  local stack="$1"
  shift
  terraform "-chdir=$stack" plan -input=false -out=ci.tfplan "$@"
  # Automatic deployment never destroys or replaces existing resources, especially RDS.
  terraform "-chdir=$stack" show -json ci.tfplan > .deploy/plan.json
  python - <<'PY'
import json
from pathlib import Path
p = json.loads(Path('.deploy/plan.json').read_text())
deleted = [r['address'] for r in p.get('resource_changes', []) if 'delete' in r['change']['actions']]
if deleted:
    raise SystemExit('Destructive plan requires a separately reviewed manual operation: ' + ', '.join(deleted))
PY
  terraform "-chdir=$stack" apply -input=false ci.tfplan
}
plan_and_apply eks
origin=$(terraform -chdir=eks output -raw api_origin_domain_name)
# WAF : variables de dépôt WAF_ENABLED (défaut false) et WAF_MODE (défaut block).
plan_and_apply infra "-var=aws_region=$AWS_REGION" "-var=api_origin_domain_name=$origin" \
  "-var=waf_enabled=${WAF_ENABLED:-false}" "-var=waf_mode=${WAF_MODE:-block}"
