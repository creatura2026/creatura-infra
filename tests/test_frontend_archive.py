import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

def load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT/f'scripts/ci/{name}.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

archive = load('unpack-frontend')
order = load('check-release-order')


class FrontendArchiveTests(unittest.TestCase):
    def make_archive(self, root, extra=None):
        path = root/'frontend.tar.gz'
        with tarfile.open(path, 'w:gz') as tar:
            for name in ['index.html', 'admin/index.html']:
                entry = tarfile.TarInfo(name)
                data = b'<html></html>'
                entry.size = len(data)
                tar.addfile(entry, io.BytesIO(data))
            if extra:
                tar.addfile(extra)
        return path, {'frontend_sha256': hashlib.sha256(path.read_bytes()).hexdigest()}

    def test_valid_archive(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            path, release = self.make_archive(root)
            archive.unpack(release, path, root/'site')
            self.assertTrue((root/'site/admin/index.html').is_file())

    def test_tampered_archive_rejected_before_extracting(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            path, release = self.make_archive(root)
            path.write_bytes(path.read_bytes() + b'changed')
            with self.assertRaises(ValueError):
                archive.unpack(release, path, root/'site')
            self.assertFalse((root/'site').exists())

    def test_unsafe_or_reserved_files_rejected(self):
        for name in ['../outside', '/outside', 'sprites/card.png', '.creatura/release.json']:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                path, release = self.make_archive(root, tarfile.TarInfo(name))
                with self.assertRaises(ValueError):
                    archive.unpack(release, path, root/'site')
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            link = tarfile.TarInfo('link')
            link.type, link.linkname = tarfile.SYMTYPE, '/outside'
            path, release = self.make_archive(root, link)
            with self.assertRaises(ValueError):
                archive.unpack(release, path, root/'site')

    def test_release_order_includes_attempt_and_contents(self):
        current = dict(run_id='200', run_attempt='2', commit='a'*40, images={}, frontend_sha256='b'*64)
        order.check_order(current, current)
        order.check_order(current, {**current, 'run_id': '201', 'run_attempt': '1'})
        for changed in [{'run_id': '199'}, {'run_attempt': '1'}, {'frontend_sha256': 'c'*64}]:
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                order.check_order(current, {**current, **changed})
