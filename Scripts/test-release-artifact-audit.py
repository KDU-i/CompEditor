#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Anonymous binary fixtures, not captured private paths or profile names."""
import io
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
        self.assertNotIn(b'/Users/', data)
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

    def test_unrecognized_coverage_version(self):
        audit = Audit(); audit.inspect(macho('__llvm_covmap', struct.pack('<4I', 0, 0, 0, 99)), 'fixture')
        self.assertTrue(audit.report['errors'])


if __name__ == '__main__':
    unittest.main()
