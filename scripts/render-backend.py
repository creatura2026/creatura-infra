"""Render Kubernetes manifests; requires PyYAML. No AWS calls."""
import argparse
import re
from pathlib import Path
import yaml

parser = argparse.ArgumentParser()
parser.add_argument('--image', required=True)
parser.add_argument('--port', type=int, default=8000)
parser.add_argument('--pull-secret', help='Optional Kubernetes registry Secret')
parser.add_argument('--health-path', default='/api/v1/health')
args = parser.parse_args()
# GHCR (CI de creatura-app) ou le dépôt ECR du compte (eks/ecr.tf), toujours épinglé par digest.
registries = r'(ghcr\.io/creatura2026|\d{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com)'
if not re.fullmatch(registries + r'/creatura-backend@sha256:[a-f0-9]{64}', args.image):
    parser.error('Expected creatura-backend from GHCR or the account ECR registry, pinned by digest')
if not 1 <= args.port <= 65535:
    parser.error('Invalid port')
if not args.health_path.startswith('/') or any(c.isspace() for c in args.health_path):
    parser.error('Health path must start with / and contain no whitespace')
root = Path(__file__).resolve().parents[1] / 'k8s' / 'backend'
deployment = yaml.safe_load((root / 'deployment.yaml').read_text())
if args.pull_secret:
    if not re.fullmatch(r'[a-z0-9](?:[-a-z0-9.]*[a-z0-9])?', args.pull_secret) or len(args.pull_secret) > 253:
        parser.error('Invalid pull secret name')
    deployment['spec']['template']['spec']['imagePullSecrets'] = [{'name': args.pull_secret}]
container = deployment['spec']['template']['spec']['containers'][0]
container['image'] = args.image
container['ports'][0]['containerPort'] = args.port
for probe in ['startupProbe', 'readinessProbe']:
    container[probe]['httpGet']['path'] = args.health_path
service_account, service = (yaml.safe_load((root / name).read_text()) for name in ['serviceaccount.yaml', 'service.yaml'])
print(yaml.safe_dump_all([service_account, deployment, service], sort_keys=False))
