#!/usr/bin/env bash
set -euo pipefail
export KUBECONFIG="$PWD/.deploy/kubeconfig"
namespace=creatura
export DB_IMAGE
DB_IMAGE=$(jq -r '.images["creatura-db"]' .deploy/release/release.json)
backend_image=$(jq -r '.images["creatura-backend"]' .deploy/release/release.json)
# Track the selected release before mutating application state. Retry this version or a newer one after failure.
bucket=$(terraform -chdir=infra output -raw bucket_name)
aws s3 cp .deploy/release/release.json "s3://$bucket/.creatura/deployment.json" \
  --content-type application/json --cache-control no-store --only-show-errors
aws eks update-kubeconfig --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION"
# EKS access policies may need a short propagation delay after first creation.
for _ in $(seq 1 30); do
  kubectl auth can-i create namespaces --quiet && break
  sleep 5
done
kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f -
# Dedicated read:packages token; never use the short-lived CI GITHUB_TOKEN for future node pulls.
python - <<'PYCODE' | kubectl apply -f -
import base64, json, os
username = os.environ['GHCR_USERNAME']
token = os.environ['GHCR_READ_TOKEN']
config = json.dumps({'auths': {'ghcr.io': {
    'auth': base64.b64encode(f'{username}:{token}'.encode()).decode()}}})
print(json.dumps(dict(apiVersion='v1', kind='Secret', type='kubernetes.io/dockerconfigjson',
    metadata=dict(name='ghcr-pull', namespace='creatura'),
    data={'.dockerconfigjson': base64.b64encode(config.encode()).decode()})))
PYCODE

cleanup() {
  kubectl -n "$namespace" delete secret creatura-db-admin --ignore-not-found >/dev/null 2>&1 || true
}
trap cleanup EXIT
# Credentials stay in memory and stdin: no secret-bearing command arguments or artifacts.
python - <<'PY' | kubectl apply -f -
import json, subprocess

def output(name):
    return subprocess.check_output(['terraform', '-chdir=eks', 'output', '-raw', name], text=True).strip()
secret = json.loads(subprocess.check_output([
    'aws', 'secretsmanager', 'get-secret-value', '--secret-id', output('db_master_secret_arn'),
    '--query', 'SecretString', '--output', 'text'], text=True))
print(json.dumps(dict(apiVersion='v1', kind='Secret',
    metadata=dict(name='creatura-db-admin', namespace='creatura'), type='Opaque',
    stringData=dict(PGHOST=output('db_endpoint'), PGPORT='5432', PGDATABASE=output('db_name'),
        PGUSER=output('db_master_username'), PGSSLMODE='require', PGPASSWORD=secret['password']))))
PY
kubectl -n "$namespace" delete job creatura-db-schema --ignore-not-found --wait=true
python - <<'PY' | kubectl apply -f -
import os, yaml
from pathlib import Path
job = yaml.safe_load(Path('k8s/db/schema-job.yaml').read_text())
job['spec']['template']['spec']['containers'][0]['image'] = os.environ['DB_IMAGE']
job['spec']['template']['spec']['imagePullSecrets'] = [{'name': 'ghcr-pull'}]
print(yaml.safe_dump(job))
PY
if ! kubectl -n "$namespace" wait --for=condition=complete job/creatura-db-schema --timeout=300s; then
  kubectl -n "$namespace" logs job/creatura-db-schema --tail=60 || true
  exit 1
fi
cleanup
# Preserve JWT/admin credentials across releases; replace only infrastructure-derived settings.
python - <<'PY' | kubectl apply -f -
import json, secrets, subprocess

def tf(stack, name):
    return subprocess.check_output(['terraform', f'-chdir={stack}', 'output', '-raw', name], text=True).strip()
raw = subprocess.check_output(['kubectl', '-n', 'creatura', 'get', 'secret', 'creatura-backend',
    '--ignore-not-found', '-o', 'json'], text=True)
data = json.loads(raw).get('data', {}) if raw.strip() else {}
cdn = tf('infra', 'site_url').rstrip('/')
values = dict(DATABASE_URL=tf('eks', 'backend_database_url'), DB_IAM_AUTH='true',
    AWS_REGION=__import__('os').environ['AWS_REGION'], TIMEZONE='Europe/Paris',
    IMAGE_BASE_URL=cdn, CORS_ORIGINS=cdn)
if 'JWT_SECRET' not in data:
    values['JWT_SECRET'] = secrets.token_urlsafe(48)
if not raw.strip():
    values.update(ADMIN_LOGIN='admin', ADMIN_PASSWORD=secrets.token_urlsafe(24))
print(json.dumps(dict(apiVersion='v1', kind='Secret', type='Opaque',
    metadata=dict(name='creatura-backend', namespace='creatura'), data=data, stringData=values)))
PY
python scripts/render-backend.py --image "$backend_image" --pull-secret ghcr-pull > .deploy/backend.yaml
kubectl apply --dry-run=server -f .deploy/backend.yaml
kubectl apply -f .deploy/backend.yaml
# Secret updates must be read even when the digest did not change (infra-only push).
kubectl -n "$namespace" rollout restart deployment/creatura-backend
if ! kubectl -n "$namespace" rollout status deployment/creatura-backend --timeout=330s; then
  kubectl -n "$namespace" get pods
  kubectl -n "$namespace" logs deployment/creatura-backend --tail=60 || true
  exit 1
fi
# Publish the already-tested artifact. This flag prevents any frontend rebuild.
bash scripts/deploy-frontend.sh --skip-build
cdn="$(terraform -chdir=infra output -raw site_url)"
cdn="${cdn%/}"
distribution=$(terraform -chdir=infra output -raw cloudfront_distribution_id)
# Wait for the last invalidation issued by the publisher before smoke checks.
invalidation=$(aws cloudfront create-invalidation --distribution-id "$distribution" --paths '/*' --query Invalidation.Id --output text)
aws cloudfront wait invalidation-completed --distribution-id "$distribution" --id "$invalidation"
for _ in $(seq 1 40); do
  if curl --fail --silent --show-error --max-time 10 "$cdn/api/v1/health" > .deploy/health.json && \
      jq -e '.status == "ok" and .database == "ok"' .deploy/health.json >/dev/null; then
    break
  fi
  sleep 10
done
jq -e '.status == "ok" and .database == "ok"' .deploy/health.json >/dev/null
for path in / /admin/; do
  curl --fail --silent --show-error --max-time 20 -D .deploy/headers "$cdn$path" -o /dev/null
  grep -iq '^content-type: text/html' .deploy/headers
done
bucket=$(terraform -chdir=infra output -raw bucket_name)
aws s3 cp .deploy/release/release.json "s3://$bucket/.creatura/release.json" \
  --content-type application/json --cache-control no-store --only-show-errors
