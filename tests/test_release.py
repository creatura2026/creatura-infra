import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('release', Path(__file__).resolve().parents[1] / 'scripts/ci/verify-release.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ProvenanceTests(unittest.TestCase):
    def setUp(self):
        self.run = dict(status='completed', conclusion='success', event='push', head_branch='develop',
            path='.github/workflows/ci.yml', head_repository={'full_name': 'creatura2026/creatura-app'},
            head_sha='a' * 40, id=123, run_attempt=1)
        self.release = dict(schema_version=2, commit='a' * 40, run_id='123', run_attempt='1',
            frontend_artifact='frontend-dist-123-1', frontend_sha256='d'*64, images={name: f'ghcr.io/creatura2026/{name}@sha256:' + 'b'*64
                for name in ['creatura-backend', 'creatura-db']})

    def test_verified_release(self):
        module.verify(self.run, self.release)

    def test_untrusted_sources_never_deploy(self):
        for field, value in [('event', 'pull_request'), ('conclusion', 'failure'), ('status', 'in_progress'),
                             ('head_branch', 'untrusted'), ('path', '.github/workflows/other.yml'),
                             ('head_repository', {'full_name': 'attacker/creatura-app'})]:
            with self.subTest(field=field), self.assertRaises(ValueError):
                module.verify({**self.run, field: value}, self.release)

    def test_artifacts_from_another_commit_or_attempt(self):
        for field, value in [('commit', 'c'*40), ('run_id', '124'), ('run_attempt', '2'), ('frontend_artifact', 'frontend-dist-123-2'), ('frontend_sha256', 'bad')]:
            with self.subTest(field=field), self.assertRaises(ValueError):
                module.verify(self.run, {**self.release, field: value})

    def test_floating_or_foreign_images_rejected(self):
        for image in ['ghcr.io/creatura2026/creatura-backend:develop',
                      'ghcr.io/attacker/creatura-backend@sha256:' + 'b'*64]:
            r = copy.deepcopy(self.release)
            r['images']['creatura-backend'] = image
            with self.assertRaises(ValueError):
                module.verify(self.run, r)


if __name__ == '__main__':
    unittest.main()
