# SPDX-License-Identifier: Apache-2.0
"""Artifact-only inspection. Never emit matched values or decompressed contents.

LLVM formats: CoverageMappingReader.cpp (filename tables, versions 4-7),
InstrProf.cpp (length-prefixed, optionally zlib-compressed profile names).
Unsupported or malformed inputs fail closed; this is not a secret extractor.
"""
import hashlib
import io
import re
import struct
import zipfile
import zlib
from pathlib import Path

LIMIT = 512 * 1024 * 1024
MAGICS = (b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xfe\xed\xfa\xce', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca')
PATTERNS = {
    'current-user-home': re.escape(str(Path.home()).encode()),
    'user-home-path': rb'/(?:Users|home)/[^\s/"\x00<>]{1,80}',
    'private-key-marker': rb'-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----',
    'provider-token-candidate': rb'(?:gh[pousr]_[A-Za-z0-9]{30,120}|github_pat_[A-Za-z0-9_]{40,160}|AKIA[A-Z0-9]{16}|sk-(?:proj-)?[A-Za-z0-9_-]{30,160}|xox[baprs]-[A-Za-z0-9-]{20,160})',
    'credential-url': rb'https?://[^\s/:]{2,80}:[^\s/@]{2,100}@',
}


def take(data, offset, length):
    if offset < 0 or length < 0 or offset + length > len(data):
        raise ValueError('truncated region')
    return data[offset:offset + length]


def uleb(data, offset):
    value = 0
    for shift in range(0, 64, 7):
        byte = take(data, offset, 1)[0]
        offset += 1
        value |= (byte & 127) << shift
        if not byte & 128:
            return value, offset
    raise ValueError('invalid ULEB128')


def inflate(data, expected):
    if expected > LIMIT:
        raise ValueError('expanded region exceeds limit')
    decoder = zlib.decompressobj()
    result = decoder.decompress(data, expected + 1)
    if len(result) != expected or not decoder.eof or decoder.unused_data or decoder.unconsumed_tail:
        raise ValueError('invalid compressed region')
    return result


def profile_names(data):
    offset = 0
    while offset < len(data):
        if not any(data[offset:]):
            break  # LLVM permits zero alignment padding between records.
        raw, offset = uleb(data, offset)
        compressed, offset = uleb(data, offset)
        length = compressed or raw
        payload = take(data, offset, length)
        yield inflate(payload, raw) if compressed else payload
        offset += length
        while offset < len(data) and data[offset] == 0:
            offset += 1


def coverage_names(data, endian):
    offset = 0
    while offset < len(data):
        if not any(data[offset:]):
            break
        records, size, mapping, version = struct.unpack(endian + 'IIII', take(data, offset, 16))
        if records or mapping or version not in (3, 4, 5, 6):
            raise ValueError('unsupported coverage version/layout')
        table = take(data, offset + 16, size)
        count, pos = uleb(table, 0)
        raw, pos = uleb(table, pos)
        compressed, pos = uleb(table, pos)
        payload = take(table, pos, compressed or raw)
        if pos + len(payload) != len(table) or count == 0:
            raise ValueError('invalid coverage filename table')
        payload = inflate(payload, raw) if compressed else payload
        cursor = 0
        for _ in range(count):
            length, cursor = uleb(payload, cursor)
            yield take(payload, cursor, length)
            cursor += length
        if cursor != len(payload):
            raise ValueError('coverage filename trailing bytes')
        offset = (offset + 16 + size + 7) & ~7
        if offset > len(data):
            raise ValueError('coverage alignment outside section')


def sections(data):
    magic = data[:4]
    if magic in MAGICS[4:]:
        endian = '>' if magic in (MAGICS[4], MAGICS[6]) else '<'
        wide = magic in MAGICS[6:]
        count = struct.unpack(endian + 'I', take(data, 4, 4))[0]
        if count > 64:
            raise ValueError('too many Mach-O slices')
        for index in range(count):
            entry = take(data, 8 + index * (32 if wide else 20), 32 if wide else 20)
            offset, size = struct.unpack_from(endian + ('QQ' if wide else 'II'), entry, 8)
            slice_data = take(data, offset, size)
            if slice_data[:4] not in MAGICS[:4]:
                raise ValueError('invalid Mach-O slice')
            yield from sections(slice_data)
        return
    if magic not in MAGICS[:4]:
        return
    endian = '<' if magic in MAGICS[:2] else '>'
    wide = magic in (MAGICS[0], MAGICS[2])
    header = 32 if wide else 28
    count, command_bytes = struct.unpack_from(endian + 'II', take(data, 0, header), 16)
    commands = take(data, header, command_bytes)
    offset = 0
    for _ in range(count):
        command, size = struct.unpack(endian + 'II', take(commands, offset, 8))
        if size < 8:
            raise ValueError('invalid Mach-O command')
        body = take(commands, offset, size)
        if command in (1, 25):
            seg64 = command == 25
            base, stride = (72, 80) if seg64 else (56, 68)
            n = struct.unpack_from(endian + 'I', take(body, 0, base), base - 8)[0]
            for i in range(n):
                entry = take(body, base + i * stride, stride)
                name = entry[:16].split(b'\0')[0].decode('ascii')
                length, file_offset = struct.unpack_from(endian + ('QI' if seg64 else 'II'), entry, 40 if seg64 else 36)
                flags = struct.unpack_from(endian + 'I', entry, 64 if seg64 else 56)[0]
                # Zerofill sections have no bytes in the file.
                if flags & 255 in (1, 12, 18):
                    continue
                yield name, take(data, file_offset, length), endian
        offset += size
    if offset != len(commands):
        raise ValueError('Mach-O command size mismatch')


class Audit:
    def __init__(self, approvals=None):
        self.report = {'files': 0, 'macho': 0, 'zip': 0, 'findings': [], 'errors': [], 'instrumented_sections': [], 'reviewed': []}
        self.approvals = approvals or []
        self.expanded = 0

    def scan(self, data, label, region='raw'):
        counts = {name: len(list(re.finditer(pattern, data))) for name, pattern in PATTERNS.items()}
        counts = {name: count for name, count in counts.items() if count}
        if not counts:
            return
        digest = hashlib.sha256(data).hexdigest()
        for approval in self.approvals:
            if approval['sha256'] == digest and set(counts) <= set(approval['types']) and 'current-user-home' not in counts:
                self.report['reviewed'].append({'path': label, 'region': region, 'types': counts, 'sha256': digest})
                return
        for finding in self.report['findings']:
            if finding['path'] == label and finding['region'] == region:
                for name, count in counts.items():
                    finding['types'][name] = finding['types'].get(name, 0) + count
                return
        self.report['findings'].append({'path': label, 'region': region, 'types': counts})

    def inspect(self, data, label, depth=0):
        self.report['files'] += 1
        try:
            if len(data) > LIMIT and not (data[:4] in (b'PK\x03\x04', b'PK\x05\x06') and len(data) <= 2 * 1024**3):
                raise ValueError('file exceeds inspection limit')
            self.scan(data, label)
            # Java class files share the fat Mach-O magic; validate their version word.
            java_class = label.lower().endswith(('.class', '.sig')) and data[:4] == b'\xca\xfe\xba\xbe' and len(data) >= 8 and 45 <= struct.unpack_from('>H', data, 6)[0] <= 100
            if data[:4] in MAGICS and not java_class:
                self.report['macho'] += 1
                for name, payload, endian in sections(data):
                    if name.startswith(('__llvm_cov', '__llvm_prf')):
                        self.report['instrumented_sections'].append({'path': label, 'section': name, 'bytes': len(payload)})
                    if name == '__llvm_covmap':
                        for decoded in coverage_names(payload, endian):
                            self.scan(decoded, label, name)
                    elif name == '__llvm_prf_names':
                        for decoded in profile_names(payload):
                            self.scan(decoded, label, name)
            if data[:4] in (b'PK\x03\x04', b'PK\x05\x06') or label.lower().endswith(('.zip', '.jar')):
                if depth >= 5:
                    raise ValueError('archive nesting limit')
                self.report['zip'] += 1
                with zipfile.ZipFile(io.BytesIO(data)) as archive:
                    for entry in archive.infolist():
                        self.expanded += entry.file_size
                        if entry.file_size > LIMIT or self.expanded > 4 * 1024**3:
                            raise ValueError('archive expansion limit')
                        self.scan(entry.filename.encode('utf-8', errors='surrogateescape'), label, 'archive-member-name')
                        if entry.is_dir():
                            continue
                        parts = Path(entry.filename).parts
                        if '.git' in parts or any(x.endswith('.dSYM') for x in parts) or Path(entry.filename).suffix in ('.profraw', '.p12', '.pfx', '.mobileprovision', '.provisionprofile') or Path(entry.filename).name in ('.env', '.DS_Store', 'credentials'):
                            raise ValueError('forbidden archive member')
                        self.inspect(archive.read(entry), label + '!/' + entry.filename, depth + 1)
        except (ValueError, struct.error, UnicodeError, zlib.error, zipfile.BadZipFile, RuntimeError, NotImplementedError):
            self.report['errors'].append({'path': label, 'reason': 'required parsing failed or inspection limit exceeded'})

    def passed(self):
        return not any(self.report[key] for key in ('findings', 'errors', 'instrumented_sections'))
