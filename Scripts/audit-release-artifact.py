#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Fail-closed release inspection, including Mach-O compression and nested ZIP/JAR."""
import argparse
import json
from pathlib import Path
from release_artifact_audit import Audit, LIMIT, PATTERNS, MAGICS
import re
import os


def main():
    parser = argparse.ArgumentParser()
    inputs = parser.add_mutually_exclusive_group(required=True)
    inputs.add_argument('--app', type=Path)
    inputs.add_argument('--input', type=Path)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--approvals', type=Path)
    args = parser.parse_args()
    approvals = json.loads(args.approvals.read_text()) if args.approvals else []
    audit = Audit(approvals)
    source = args.app or args.input
    if not source.exists():
        audit.report['errors'].append({'path': 'input', 'reason': 'missing artifact'})
    if args.app:
        main_binary = source/'Contents/MacOS/CompEditor'
        if not main_binary.is_file() or main_binary.read_bytes()[:4] not in MAGICS:
            audit.report['errors'].append({'path': 'Contents/MacOS/CompEditor', 'reason': 'required main Mach-O missing or invalid'})
        if (source/'Contents/Frameworks/Sparkle.framework').exists():
            audit.report['errors'].append({'path': 'Contents/Frameworks/Sparkle.framework', 'reason': 'updater remains'})
    is_directory = source.is_dir()
    # Scan exactly the root/member names that the packager serializes, not host paths.
    audit.scan(os.fsencode(source.name), 'input', 'root-name')
    if source.is_symlink():
        try:
            audit.scan(os.fsencode(os.readlink(source)), 'input', 'symlink-target')
        except OSError:
            audit.report['errors'].append({'path': 'input', 'reason': 'unreadable symlink root'})
        audit.report['errors'].append({'path': 'input', 'reason': 'symlink artifact root refused'})
        files = []
    else:
        files = sorted(source.rglob('*')) if is_directory else [source]
    for file in files:
        label = str(file.relative_to(source)) if is_directory else source.name
        member_name = source.name + '/' + label if is_directory else label
        audit.scan(os.fsencode(member_name), label, 'member-name')
        if file.is_symlink():
            try:
                target = os.readlink(file)
                audit.scan(os.fsencode(target), label, 'symlink-target')
                if Path(target).is_absolute() or not file.resolve().is_relative_to(source.resolve()):
                    audit.report['errors'].append({'path': label, 'reason': 'external symlink'})
            except (OSError, RuntimeError, ValueError):
                audit.report['errors'].append({'path': label, 'reason': 'unreadable or invalid symlink'})
            continue
        if not file.is_file():
            continue
        if '.git' in file.parts or any(x.endswith('.dSYM') for x in file.parts) or file.suffix in ('.p12', '.pfx', '.mobileprovision', '.provisionprofile', '.profraw') or file.name in ('.env', '.DS_Store', 'credentials'):
            audit.report['errors'].append({'path': label, 'reason': 'forbidden release file'})
        if file.stat().st_size > (2 * 1024**3 if file.suffix in ('.zip', '.jar') else LIMIT):
            audit.report['errors'].append({'path': label, 'reason': 'file exceeds inspection limit'})
            continue
        try:
            audit.inspect(file.read_bytes(), label)
        except OSError:
            audit.report['errors'].append({'path': label, 'reason': 'unreadable artifact'})
    audit.report['passed'] = audit.passed()
    audit.report['limits'] = 'Bounded pattern audit, Mach-O filename/profile decoding, ZIP/JAR recursion. Not a proof of absence of secrets; other compression formats are not decoded.'
    # Also suppress candidates occurring in malicious/member filenames.
    report = json.dumps(audit.report, indent=2)
    for pattern in PATTERNS.values():
        report = re.sub(pattern.decode(), '[redacted]', report)
    args.report.write_text(report + '\n')
    print('Artifact audit:', 'PASS' if audit.passed() else 'FAIL', '; files:', audit.report['files'], '; Mach-O:', audit.report['macho'], '; archives:', audit.report['zip'])
    return 0 if audit.passed() else 1


if __name__ == '__main__':
    raise SystemExit(main())
