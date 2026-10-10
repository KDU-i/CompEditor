#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Anonymous binary fixtures, not captured private paths or profile names."""
import io
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
from unittest import mock
import json
import struct
import unittest
import zipfile
import zlib
from release_artifact_audit import Audit, coverage_names, profile_names


def leb(value):
    out = bytearray()
    while value >= 128:
        out.append((value & 127) | 128)
        value >>= 7
    return bytes(out + bytes([value]))


def compressed(raw):
    packed = zlib.compress(raw)
    return leb(len(raw)) + leb(len(packed)) + packed


def macho(name, payload):
    size = 72 + 80
    offset = 32 + size
    header = struct.pack('<8I', 0xfeedfacf, 0x100000c, 0, 2, 1, size, 0, 0)
    segment = struct.pack('<II16sQQQQIIII', 25, size, b'__DATA', 0, len(payload), offset, len(payload), 7, 3, 1, 0)
    section = struct.pack('<16s16sQQIIIIIIII', name.encode(), b'__DATA', 0, len(payload), offset, 0, 0, 0, 0, 0, 0, 0)
    return header + segment + section + payload


def zipdata(name, data):
    out = io.BytesIO()
    with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(name, data)
    return out.getvalue()


class AuditTests(unittest.TestCase):
    def test_compressed_profile_hidden_from_raw_scan(self):
        data = macho('__llvm_prf_names', compressed(b'/' + b'Users/anonymous-fixture/file.swift:function'))
        self.assertNotIn(b'/' + b'Users/', data)
        audit = Audit(); audit.inspect(data, 'fixture')
        self.assertFalse(audit.passed())
        self.assertEqual(audit.report['findings'][0]['region'], '__llvm_prf_names')
        self.assertNotIn('anonymous-fixture', json.dumps(audit.report))

    def test_coverage_table(self):
        name = b'/' + b'Users/anonymous-fixture/file.swift'
        table = leb(1) + compressed(leb(len(name)) + name)
        payload = struct.pack('<4I', 0, len(table), 0, 6) + table
        payload += b'\0' * (-len(payload) % 8)
        self.assertEqual(list(coverage_names(payload, '<')), [name])
        audit = Audit(); audit.inspect(macho('__llvm_covmap', payload), 'fixture')
        self.assertFalse(audit.passed())
        self.assertFalse(audit.report['errors'])

    def test_uncompressed_and_multiple_profile_records(self):
        self.assertEqual(list(profile_names(b'\x03\x00abc\0' + compressed(b'def'))), [b'abc', b'def'])

    def test_bad_compression_fails_closed(self):
        audit = Audit(); audit.inspect(macho('__llvm_prf_names', b'\x03\x03bad'), 'fixture')
        self.assertTrue(audit.report['errors'])
        self.assertFalse(audit.passed())

    def test_truncated_macho_fails_closed(self):
        audit = Audit(); audit.inspect(b'\xcf\xfa\xed\xfe', 'fixture')
        self.assertTrue(audit.report['errors'])

    def test_nested_zip_and_library(self):
        data = zipdata('inner.jar', zipdata('library.dylib', macho('__llvm_prf_names', compressed(b'/' + b'home/anonymous-fixture/file'))))
        audit = Audit(); audit.inspect(data, 'fixture.zip')
        self.assertEqual(audit.report['zip'], 2)
        self.assertEqual(audit.report['macho'], 1)
        self.assertFalse(audit.passed())

    def test_clean_and_public_attribution(self):
        audit = Audit(); audit.inspect(b'Copyright public upstream author. Apache-2.0', 'LICENSE')
        self.assertTrue(audit.passed())

    def test_java_class_not_macho(self):
        audit = Audit(); audit.inspect(b'\xca\xfe\xba\xbe\x00\x00\x00\x3dpublic', 'fixture.class')
        self.assertTrue(audit.passed())
        self.assertEqual(audit.report['macho'], 0)

    def test_fat_header_cannot_masquerade_as_java_library(self):
        audit = Audit(); audit.inspect(b'\xca\xfe\xba\xbe\x00\x00\x00\x2d', 'fixture.dylib')
        self.assertTrue(audit.report['errors'])

    def test_public_credentials_namespace_is_directory(self):
        audit = Audit(); audit.inspect(zipdata('org/public/credentials/', b''), 'fixture.jar')
        self.assertTrue(audit.passed())

    def test_nested_profile_file_fails_closed(self):
        audit = Audit(); audit.inspect(zipdata('default.profraw', b'profile'), 'fixture.zip')
        self.assertTrue(audit.report['errors'])

    def test_fat_library_all_slices(self):
        payload = macho('__llvm_prf_names', compressed(b'/' + b'Users/anonymous-fixture/file'))
        offset = 8 + 20
        data = struct.pack('>II5I', 0xcafebabe, 1, 0x100000c, 0, offset, len(payload), 0) + payload
        audit = Audit(); audit.inspect(data, 'fixture.dylib')
        self.assertFalse(audit.report['errors'])
        self.assertFalse(audit.passed())

    def test_bad_zip_fails_closed(self):
        audit = Audit(); audit.inspect(b'PK\x03\x04bad', 'fixture.zip')
        self.assertTrue(audit.report['errors'])

    def test_review_is_hash_and_type_scoped(self):
        import hashlib
        data = b'/' + b'home/public-build/test'
        approval = {'sha256': hashlib.sha256(data).hexdigest(), 'types': ['user-home-path']}
        audit = Audit([approval]); audit.inspect(data, 'fixture'); self.assertTrue(audit.passed())
        audit = Audit([approval]); audit.inspect(data + b'changed', 'fixture'); self.assertFalse(audit.passed())

    def directory_audit(self, source, report):
        return subprocess.run([sys.executable, str(Path(__file__).with_name('audit-release-artifact.py')),
                               '--input', str(source), '--report', str(report)], capture_output=True)

    def test_directory_member_names_fail_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); source = root/'artifact'
            file = source/'payload'/'home'/'anonymous-fixture'/'file'
            file.parent.mkdir(parents=True); file.write_text('public fixture')
            result = self.directory_audit(source, root/'report.json')
            self.assertNotEqual(result.returncode, 0)
            report = json.loads((root/'report.json').read_text())
            self.assertTrue(any(x['region'] == 'member-name' for x in report['findings']))
            self.assertNotIn('anonymous-fixture', json.dumps(report))

    def test_relative_symlink_target_fail_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); source = root/'artifact'
            (source/'safe').mkdir(parents=True); (source/'safe/file').write_text('public fixture')
            target = '/'.join(['safe', 'home', 'anonymous-fixture', '..', '..', 'file'])
            (source/'link').symlink_to(target)
            result = self.directory_audit(source, root/'report.json')
            self.assertNotEqual(result.returncode, 0)
            report = json.loads((root/'report.json').read_text())
            self.assertTrue(any(x['region'] == 'symlink-target' for x in report['findings']))
            self.assertNotIn('anonymous-fixture', json.dumps(report))

    def test_empty_zip_directory_name_is_inspected(self):
        name = '/'.join(['artifact', 'home', 'anonymous-fixture']) + '/'
        audit = Audit(); audit.inspect(zipdata(name, b''), 'fixture.zip')
        self.assertFalse(audit.passed())

    def test_symlink_artifact_root_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); source = root/'artifact'; source.mkdir()
            (source/'file').write_text('public fixture')
            link = root/'link'; link.symlink_to(source, target_is_directory=True)
            self.assertNotEqual(self.directory_audit(link, root/'report.json').returncode, 0)

    def test_source_root_name_is_inspected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); source = root/('ghp_' + 'A' * 40)
            source.mkdir(); (source/'file').write_text('public fixture')
            self.assertNotEqual(self.directory_audit(source, root/'report.json').returncode, 0)

    def test_completed_zip_failure_keeps_final_outputs_absent(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); source = root/'artifact'; source.mkdir()
            file = source/'file'; file.write_text('public fixture')
            output = root/'fixture.zip'; original_run = subprocess.run; calls = []

            def run_and_mutate(*args, **kwargs):
                result = original_run(*args, capture_output=True, **kwargs)
                calls.append(result.returncode)
                if len(calls) == 1:
                    # Simulate bytes changing after directory preflight, before ZIP writing.
                    file.write_bytes(b'/' + b'home/anonymous-fixture/file')
                return result

            with mock.patch.object(sys, 'argv', ['package-release-archive.py', '--input', str(source), '--output', str(output)]):
                with mock.patch('subprocess.run', side_effect=run_and_mutate):
                    with self.assertRaises(SystemExit):
                        runpy.run_path(str(Path(__file__).with_name('package-release-archive.py')), run_name='__main__')
            self.assertEqual(calls, [0, 1])
            self.assertFalse(output.exists())
            self.assertFalse(Path(str(output) + '.sha256').exists())
            self.assertFalse(Path(str(output) + '.inventory.json').exists())
            self.assertFalse(list(root.glob('.candidate-*.zip')))
            self.assertFalse(json.loads(Path(str(output) + '.audit.json').read_text())['passed'])

    def test_clean_internal_symlink_survives_both_gates(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); source = root/'artifact'; source.mkdir()
            (source/'public.txt').write_text('public fixture')
            (source/'link').symlink_to('public.txt')
            output = root/'fixture.zip'
            result = subprocess.run([sys.executable, str(Path(__file__).with_name('package-release-archive.py')),
                                     '--input', str(source), '--output', str(output)], capture_output=True)
            self.assertEqual(result.returncode, 0)
            with zipfile.ZipFile(output) as archive:
                self.assertEqual(archive.read('artifact/link'), b'public.txt')
            for suffix in ('.input-audit.json', '.audit.json'):
                self.assertTrue(json.loads(Path(str(output) + suffix).read_text())['passed'])

    def test_existing_output_is_protected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp); source = root/'artifact'; source.mkdir()
            (source/'file').write_text('public fixture')
            output = root/'fixture.zip'; output.write_bytes(b'owner-existing-output')
            result = subprocess.run([sys.executable, str(Path(__file__).with_name('package-release-archive.py')),
                                     '--input', str(source), '--output', str(output)], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(output.read_bytes(), b'owner-existing-output')

    def test_unrecognized_coverage_version(self):
        audit = Audit(); audit.inspect(macho('__llvm_covmap', struct.pack('<4I', 0, 0, 0, 99)), 'fixture')
        self.assertTrue(audit.report['errors'])


if __name__ == '__main__':
    unittest.main()
