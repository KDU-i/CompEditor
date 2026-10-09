#!/usr/bin/env python3
# Modified for the unofficial Java/Python semantic fork; see FORK_CHANGES.md.
# SPDX-License-Identifier: Apache-2.0
"""Create a LOCAL ZIP only after input and completed ZIP both pass inspection."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import zipfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--input', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    outputs = [args.output] + [args.output.with_suffix(args.output.suffix + suffix)
                              for suffix in ('.inventory.json', '.sha256', '.audit.json', '.input-audit.json')]
    if any(path.exists() or path.is_symlink() for path in outputs):
        raise SystemExit('Existing archive/sidecar is protected')
    if not args.input.is_dir() or args.input.is_symlink():
        raise SystemExit('Regular source/app directory required')
    source = args.input.resolve()
    files = sorted(file for file in source.rglob('*') if file.is_file() or file.is_symlink())
    root = Path(__file__).resolve().parent.parent
    args.output.parent.mkdir(parents=True, exist_ok=True)

    def audit(path, report, app=False):
        result = subprocess.run([sys.executable, str(root/'Scripts/audit-release-artifact.py'),
                                 '--app' if app else '--input', str(path),
                                 '--approvals', str(root/'Release/audit-reviewed-upstream.json'),
                                 '--report', str(report)])
        if result.returncode:
            raise SystemExit('Artifact audit failed; see value-suppressed report')

    audit(source, outputs[4], source.suffix == '.app')
    inventory = []
    # The final name and checksum are published only after scanning the actual ZIP.
    descriptor, temporary = tempfile.mkstemp(prefix='.candidate-', suffix='.zip', dir=args.output.parent)
    os.close(descriptor)
    temporary = Path(temporary)
    try:
        with zipfile.ZipFile(temporary, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
            for file in files:
                if '.git' in file.parts or any(part.endswith('.dSYM') for part in file.parts) or file.name in ('.DS_Store', '.env', 'credentials') or file.suffix in ('.p12', '.pfx', '.mobileprovision', '.provisionprofile', '.profraw'):
                    raise SystemExit('Forbidden archive member')
                name = source.name + '/' + str(file.relative_to(source))
                if Path(name).is_absolute() or '..' in Path(name).parts:
                    raise SystemExit('Unsafe archive member')
                link = file.is_symlink()
                if link:
                    target = os.readlink(file)
                    if Path(target).is_absolute() or not file.resolve().is_relative_to(source):
                        raise SystemExit('External symlink refused')
                    data = os.fsencode(target)
                else:
                    data = file.read_bytes()
                entry = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
                entry.create_system = 3
                entry.compress_type = zipfile.ZIP_DEFLATED
                entry.external_attr = (file.lstat().st_mode & 0xffff) << 16
                archive.writestr(entry, data)
                inventory.append({'path': name, 'bytes': len(data),
                                  'sha256': hashlib.sha256(data).hexdigest(), 'symlink': link})
        audit(temporary, outputs[3])
        digest = hashlib.sha256(temporary.read_bytes()).hexdigest()
        # Exclusive creation also protects a destination created during inspection.
        os.link(temporary, args.output)
        with outputs[1].open('x') as stream:
            stream.write(json.dumps(inventory, indent=2) + '\n')
        with outputs[2].open('x') as stream:
            stream.write(digest + '  ' + args.output.name + '\n')
        print('Local archive created:', args.output.name, 'members:', len(files), 'sha256:', digest)
    finally:
        temporary.unlink(missing_ok=True)


if __name__ == '__main__':
    main()
