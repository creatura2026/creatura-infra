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
dns_args=()
if [ -n "${CUSTOM_DOMAIN:-}" ]; then
  # Never recreate a zone that already exists outside this remote state.
  terraform -chdir=dns show -json > .deploy/dns-state.json
  if ! jq -e '(.values.root_module.resources // []) | any(.address == "aws_route53_zone.site")' .deploy/dns-state.json > /dev/null; then
    aws route53 list-hosted-zones-by-name --dns-name "$CUSTOM_DOMAIN" --output json > .deploy/zones.json
    if jq -e --arg name "$CUSTOM_DOMAIN." '.HostedZones | any(.Name == $name)' .deploy/zones.json > /dev/null; then
      echo 'DNS zone already exists outside the configured DNS state. Migrate the old dns/ state or import the zone/certificate before retrying.' >&2
      exit 1
    fi
  fi
  plan_and_apply dns
  bash scripts/ci/validate-dns.sh
  dns_args=(
    "-var=custom_domain=$(terraform -chdir=dns output -raw domain_name)"
    "-var=certificate_arn=$(terraform -chdir=dns output -raw certificate_arn)"
    "-var=route53_zone_id=$(terraform -chdir=dns output -raw zone_id)"
  )
else
  # Missing configuration must not silently remove a domain already in use.
  terraform -chdir=infra output -json > .deploy/infra-outputs.json
  site=$(jq -r '.site_url.value // empty' .deploy/infra-outputs.json)
  case "$site" in
    ""|https://*.cloudfront.net/) ;;
    *) echo 'Set CUSTOM_DOMAIN to preserve the existing custom domain.' >&2; exit 1 ;;
  esac
fi
# Database missing from the eks/ state (environment destroyed by scripts/aws-down.sh): restore
# the latest creatura-db-* snapshot instead of creating an empty database, which would silently
# lose every player account. Fails if the snapshots cannot be listed.
eks_args=()
terraform -chdir=eks show -json > .deploy/eks-state.json
if ! jq -e '(.values.root_module.resources // []) | any(.address == "aws_db_instance.creatura")' .deploy/eks-state.json > /dev/null; then
  snapshot=$(bash scripts/latest-db-snapshot.sh "$AWS_REGION")
  if [ -n "$snapshot" ]; then
    echo "RDS instance not in state: restoring snapshot $snapshot"
    eks_args=("-var=db_snapshot_identifier=$snapshot")
  else
    echo "RDS instance not in state and no creatura-db-* snapshot: creating an empty database"
  fi
fi
plan_and_apply eks "${eks_args[@]}"
origin=$(terraform -chdir=eks output -raw api_origin_domain_name)
# Preserve both DNS settings and the WAF settings introduced on develop.
plan_and_apply infra \
  "-var=aws_region=$AWS_REGION" \
  "-var=api_origin_domain_name=$origin" \
  "-var=waf_enabled=${WAF_ENABLED:-false}" \
  "-var=waf_mode=${WAF_MODE:-block}" \
  "${dns_args[@]}"
