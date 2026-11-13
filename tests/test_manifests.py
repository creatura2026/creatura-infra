import json
from pathlib import Path
import subprocess
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]


class ManifestTests(unittest.TestCase):
    def test_eks_release_uses_pod_identity_and_exact_image(self):
        image = '470805151953.dkr.ecr.eu-north-1.amazonaws.com/creatura-backend@sha256:' + 'a'*64
        out = subprocess.check_output(['python', str(ROOT/'scripts/render-backend.py'), '--image', image, '--pull-secret', 'ghcr-pull'], text=True)
        account, deployment, service = list(yaml.safe_load_all(out))
        pod = deployment['spec']['template']['spec']
        self.assertEqual(pod['serviceAccountName'], account['metadata']['name'])
        self.assertEqual(pod['imagePullSecrets'], [{'name': 'ghcr-pull'}])
        self.assertEqual(pod['containers'][0]['image'], image)
        self.assertEqual(pod['containers'][0]['readinessProbe']['httpGet']['path'], '/api/v1/health')
        self.assertEqual(service['spec']['selector'], deployment['spec']['selector']['matchLabels'])
        self.assertEqual(service['spec']['ports'][0]['nodePort'], 30080)

    def test_schema_job_never_loads_demo_data(self):
        job = yaml.safe_load((ROOT/'k8s/db/schema-job.yaml').read_text())
        env = job['spec']['template']['spec']['containers'][0]['env']
        self.assertEqual(next(x['value'] for x in env if x['name'] == 'CREATURA_DEMO'), 'false')
