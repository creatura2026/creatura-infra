"""Validate provenance before any AWS operation. Inputs are artifacts of the app CI."""
import argparse
import json
import re
from pathlib import Path


def verify(run, release):
    expected = {
        'status': 'completed', 'conclusion': 'success', 'event': 'push',
        'head_branch': 'develop', 'path': '.github/workflows/ci.yml',
    }
    for field, value in expected.items():
        if run.get(field) != value:
            raise ValueError(f'Untrusted CI run: {field}')
    if run.get('head_repository', {}).get('full_name') != 'creatura2026/creatura-app':
        raise ValueError('Wrong source repository')
    if release.get('schema_version') != 2 or release.get('commit') != run.get('head_sha'):
        raise ValueError('Release commit does not match tested commit')
    if str(release.get('run_id')) != str(run.get('id')):
        raise ValueError('Release belongs to a different run')
    if str(release.get('run_attempt')) != str(run.get('run_attempt')):
        raise ValueError('Release belongs to a different attempt')
    if release.get('frontend_artifact') != f'frontend-dist-{run["id"]}-{run["run_attempt"]}':
        raise ValueError('Unexpected frontend artifact')
    if not re.fullmatch(r'[a-f0-9]{64}', release.get('frontend_sha256', '')):
        raise ValueError('Invalid frontend checksum')
    if not re.fullmatch(r'[a-f0-9]{40}', release['commit']):
        raise ValueError('Invalid commit')
    for name in ['creatura-backend', 'creatura-db']:
        image = release.get('images', {}).get(name, '')
        if not re.fullmatch(r'ghcr\.io/creatura2026/' + name + r'@sha256:[a-f0-9]{64}', image):
            raise ValueError(f'Invalid pinned image: {name}')
    return release


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('run', type=Path)
    p.add_argument('release', type=Path)
    args = p.parse_args()
    verify(json.loads(args.run.read_text()), json.loads(args.release.read_text()))
    print('CI provenance and immutable image references verified.')
