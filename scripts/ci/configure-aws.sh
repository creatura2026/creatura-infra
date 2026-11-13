#!/usr/bin/env bash
set -euo pipefail
: "${AWS_ACCOUNT_ID:?Set AWS_ACCOUNT_ID}"
: "${TF_STATE_BUCKET:?Set TF_STATE_BUCKET to the existing bootstrap bucket}"
: "${EKS_KUBERNETES_VERSION:?Set EKS_KUBERNETES_VERSION}"
mkdir -p .deploy
account=$(aws sts get-caller-identity --query Account --output text)
[ "$account" = "$AWS_ACCOUNT_ID" ] || { echo 'Wrong AWS account' >&2; exit 1; }
aws s3api head-bucket --bucket "$TF_STATE_BUCKET"
principal=$(aws sts get-caller-identity --query Arn --output text)
# Static IAM credentials are used by this pipeline; STS session ARNs cannot be EKS principals.
[[ "$principal" =~ ^arn:aws:iam::[0-9]{12}:(user|role)/ ]] || { echo 'Expected an IAM user/role principal' >&2; exit 1; }
ip=$(curl --fail --silent --show-error --max-time 15 https://checkip.amazonaws.com | tr -d '[:space:]')
export CI_PRINCIPAL="$principal" CI_RUNNER_IP="$ip"
python - <<'PY'
import ipaddress, json, os
from pathlib import Path
ip = ipaddress.ip_address(os.environ['CI_RUNNER_IP'])
if ip.version != 4:
    raise ValueError('Expected runner IPv4')
cidrs = json.loads(os.environ['EKS_ADMIN_CIDRS'])
if not isinstance(cidrs, list):
    raise ValueError('EKS_ADMIN_CIDRS must be a JSON array')
for cidr in cidrs:
    if ipaddress.ip_network(cidr).prefixlen == 0:
        raise ValueError('Unrestricted EKS endpoint is not permitted')
values = dict(
    aws_region=os.environ['AWS_REGION'], cluster_name=os.environ['EKS_CLUSTER_NAME'],
    kubernetes_version=os.environ['EKS_KUBERNETES_VERSION'],
    administrator_principal_arn=os.environ.get('EKS_ADMIN_PRINCIPAL_ARN') or os.environ['CI_PRINCIPAL'],
    # Full provisioning and schema initialization require administrative Kubernetes access.
    deployment_principal_arn=None,
    ci_administrator_principal_arn=os.environ['CI_PRINCIPAL'],
    endpoint_public_access_cidrs=sorted(set(cidrs + [str(ip) + '/32'])),
    create_ecr_repositories=False, create_image_builder=False,
)
Path('eks/ci.auto.tfvars.json').write_text(json.dumps(values))
PY
for stack in eks infra; do
  key="$TF_EKS_STATE_KEY"; [ "$stack" = infra ] && key="$TF_STATE_KEY"
  terraform "-chdir=$stack" init -input=false -reconfigure \
    "-backend-config=bucket=$TF_STATE_BUCKET" "-backend-config=key=$key" \
    "-backend-config=region=$TF_STATE_REGION" -backend-config=encrypt=true -backend-config=use_lockfile=true
done

if [ -n "${CUSTOM_DOMAIN:-}" ]; then
  python - <<'PYCODE'
import json, os, re
from pathlib import Path
domain = os.environ['CUSTOM_DOMAIN']
if not re.fullmatch(r'([a-z0-9-]+\.)+[a-z]{2,}', domain):
    raise SystemExit('CUSTOM_DOMAIN must be a lowercase domain without protocol, path or trailing dot')
Path('dns/ci.auto.tfvars.json').write_text(json.dumps({'domain_name': domain}))
PYCODE
  terraform -chdir=dns init -input=false -reconfigure \
    "-backend-config=bucket=$TF_STATE_BUCKET" \
    "-backend-config=key=${TF_DNS_STATE_KEY:-dns/terraform.tfstate}" \
    "-backend-config=region=$TF_STATE_REGION" \
    -backend-config=encrypt=true -backend-config=use_lockfile=true
fi
