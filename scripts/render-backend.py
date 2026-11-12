"""Render Kubernetes manifests; requires PyYAML. No AWS calls."""
import argparse
import re
from pathlib import Path
import yaml

parser = argparse.ArgumentParser()
parser.add_argument('--image', required=True)
parser.add_argument('--port', type=int, default=8000)
parser.add_argument('--health-path', default='/api/v1/health')
args = parser.parse_args()
if not re.fullmatch(r'ghcr\.io/creatura2026/creatura-backend@sha256:[a-f0-9]{64}', args.image):
    parser.error('Expected ghcr.io/creatura2026/creatura-backend pinned by digest')
if not 1 <= args.port <= 65535:
    parser.error('Invalid port')
if not args.health_path.startswith('/') or any(c.isspace() for c in args.health_path):
    parser.error('Health path must start with / and contain no whitespace')
root = Path(__file__).resolve().parents[1] / 'k8s' / 'backend'
deployment = yaml.safe_load((root / 'deployment.yaml').read_text())
container = deployment['spec']['template']['spec']['containers'][0]
container['image'] = args.image
container['ports'][0]['containerPort'] = args.port
for probe in ['startupProbe', 'readinessProbe']:
    container[probe]['httpGet']['path'] = args.health_path
print(yaml.safe_dump_all([deployment, yaml.safe_load((root / 'service.yaml').read_text())], sort_keys=False))
