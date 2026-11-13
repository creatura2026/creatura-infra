"""Never silently deploy an older build over a selected or successfully deployed one."""
import json
from pathlib import Path
import sys


def key(release):
    return (int(release['run_id']), int(release['run_attempt']))


def check_order(current, candidate):
    if key(candidate) < key(current):
        raise ValueError('Older app run/attempt rejected; retry the selected release or deploy a newer one')
    if key(candidate) == key(current):
        fields = ['commit', 'frontend_sha256', 'images']
        if any(candidate.get(field) != current.get(field) for field in fields):
            raise ValueError('Same run/attempt has conflicting release contents')


if __name__ == '__main__':
    check_order(*(json.loads(Path(p).read_text()) for p in sys.argv[1:]))
