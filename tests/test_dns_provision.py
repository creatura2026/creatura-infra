import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MOCK = r'''
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ['CALLS'], 'a') as f: f.write(Path(sys.argv[0]).name + ' ' + ' '.join(args) + '\n')
if Path(sys.argv[0]).name == 'terraform':
    stack = args[0]
    if 'show' in args:
        if stack == '-chdir=dns' and not any('ci.tfplan' in a for a in args):
            print(json.dumps({'values': {'root_module': {'resources': [{'address':'aws_route53_zone.site'}] if os.environ.get('MANAGED') == 'yes' else []}}}))
        else: print('{"resource_changes": []}')
    if 'output' in args:
        if '-json' in args:
            if stack == '-chdir=dns': print('{"name_servers":{"value":["ns1.example.net"]},"certificate_arn":{"value":"arn:aws:acm:us-east-1:123456789012:certificate/test"}}')
            else: print(json.dumps({'site_url':{'value':os.environ.get('SITE', '')}}))
        else: print({'domain_name':'game.example.com','zone_id':'ZEXAMPLE','certificate_arn':'arn:aws:acm:us-east-1:123456789012:certificate/test','api_origin_domain_name':'api.elb.amazonaws.com'}[args[-1]])
if Path(sys.argv[0]).name == 'aws':
    if args[0] == 'route53': print(json.dumps({'HostedZones':[{'Name':'game.example.com.'}] if os.environ.get('EXISTING') == 'yes' else []}))
    else: print(os.environ.get('CERT_STATUS','ISSUED'))
'''


class DNSProvisionTests(unittest.TestCase):
    def run_provision(self, **settings):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            (root/'.deploy').mkdir()
            (root/'bin').mkdir()
            (root/'scripts/ci').mkdir(parents=True)
            shutil.copy(ROOT/'scripts/ci/validate-dns.sh', root/'scripts/ci/validate-dns.sh')
            for name in ['aws', 'terraform', 'sleep']:
                p = root/'bin'/name
                p.write_text('#!' + sys.executable + '\n' + MOCK)
                p.chmod(0o755)
            env = {**os.environ, 'PATH':str(root/'bin')+os.pathsep+os.environ['PATH'],
                'CALLS':str(root/'calls'), 'AWS_REGION':'eu-north-1', 'CUSTOM_DOMAIN':'game.example.com',
                'GITHUB_STEP_SUMMARY':str(root/'summary'), **settings}
            result = subprocess.run(['bash', str(ROOT/'scripts/ci/provision.sh')], cwd=root,
                env=env, capture_output=True, text=True)
            return result, (root/'calls').read_text()

    def test_valid_domain_passed_to_cloudfront(self):
        result, calls = self.run_provision(MANAGED='yes')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('-var=custom_domain=game.example.com', calls)
        self.assertIn('-var=route53_zone_id=ZEXAMPLE', calls)
        self.assertLess(calls.index('-chdir=dns apply'), calls.index('-chdir=eks plan'))

    def test_unmanaged_zone_refused_before_creation(self):
        result, calls = self.run_provision(EXISTING='yes')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('-chdir=dns plan', calls)

    def test_pending_certificate_does_not_start_eks(self):
        result, calls = self.run_provision(MANAGED='yes', CERT_STATUS='PENDING_VALIDATION')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('-chdir=eks plan', calls)

    def test_missing_variable_does_not_remove_existing_domain(self):
        result, calls = self.run_provision(CUSTOM_DOMAIN='', SITE='https://game.example.com/')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('-chdir=infra plan', calls)

    def test_optional_dns_with_cloudfront_hostname(self):
        result, calls = self.run_provision(CUSTOM_DOMAIN='', SITE='https://test.cloudfront.net/')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('-chdir=dns', calls)
