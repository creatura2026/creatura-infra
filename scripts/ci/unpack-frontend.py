"""Verify the packaged build and extract regular frontend files only."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import tarfile


def unpack(release, archive, destination):
    archive, destination = Path(archive), Path(destination)
    if hashlib.sha256(archive.read_bytes()).hexdigest() != release['frontend_sha256']:
        raise ValueError('Frontend checksum differs from the tested release')
    if destination.exists():
        raise ValueError('Extraction target must not already exist')
    with tarfile.open(archive, 'r:gz') as tar:
        members = tar.getmembers()
        seen = set()
        for member in members:
            path = PurePosixPath(member.name)
            if (not member.isfile() or path.is_absolute() or '..' in path.parts
                    or not path.parts or '\\' in member.name
                    or path.parts[0] in ('sprites', '.creatura') or member.name in seen):
                raise ValueError('Unexpected frontend archive member: ' + member.name)
            seen.add(member.name)
        if not {'index.html', 'admin/index.html'} <= seen:
            raise ValueError('Missing player/admin entry points')
        destination.mkdir(parents=True)
        for member in members:
            path = destination/member.name
            path.parent.mkdir(parents=True, exist_ok=True)
            with tar.extractfile(member) as source:
                path.write_bytes(source.read())


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('release', type=Path)
    p.add_argument('archive', type=Path)
    p.add_argument('destination', type=Path)
    args = p.parse_args()
    unpack(json.loads(args.release.read_text()), args.archive, args.destination)
    print('Frontend archive checksum verified and exact build extracted.')
