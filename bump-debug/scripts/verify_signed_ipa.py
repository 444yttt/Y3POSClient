#!/usr/bin/env python3
"""Independently verify Bump signed-code and profile integrity on Linux.

CMS signatures are checked against embedded certificates, without CA trust or
revocation checks. This does not execute the app or substitute for macOS codesign
or real-device tests. Generic parsers are adapted from the reviewed
444yttt/BeReal493 scripts/verify_signed_delivery.py; no BeReal binary patch runs.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import ssl
import stat
import struct
import subprocess
import tempfile
import uuid
import zipfile

ORIGINAL_SHA = "0b18338b5db68e39ba1de6f5e45c8c79d2211d25da58dc9d4ffa6783bb41773e"
APP = "Payload/Location.app"
ROOT_ID = "com.ayato.bumpdebug"
SUFFIXES = ("", ".lpse", ".friend-widget", ".nce", ".friend-intent",
            ".on-my-way-live-activity", ".nse", ".imessage-stickers-extension", ".share")
EXPECTED_IDS = {ROOT_ID + suffix for suffix in SUFFIXES}
ADAPTER = "@executable_path/Frameworks/BumpLocationDebug.dylib"
MACH_MAGICS = {b'\xce\xfa\xed\xfe', b'\xcf\xfa\xed\xfe',
               b'\xfe\xed\xfa\xce', b'\xfe\xed\xfa\xcf',
               b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca',
               b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}


class VerificationError(ValueError):
    """Safe, deliberately authored diagnostic without private input values."""


def require(condition, message):
    if not condition:
        raise VerificationError(message)


def utc(value):
    require(isinstance(value, dt.datetime), 'Missing or invalid profile date')
    return value.replace(tzinfo=dt.timezone.utc) if value.tzinfo is None else value.astimezone(dt.timezone.utc)


def iso(value):
    return utc(value).isoformat().replace('+00:00', 'Z')


def run_openssl(arguments, data=None):
    result = subprocess.run(['openssl', *arguments], input=data, capture_output=True)
    require(result.returncode == 0, 'OpenSSL validation failed during ' + arguments[0])
    return result.stdout


def digest_file(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def certificate_details(der, now):
    fingerprint = hashlib.sha256(der).hexdigest()
    dates = run_openssl(['x509', '-inform', 'DER', '-noout', '-startdate', '-enddate'], der).decode()
    values = {}
    for line in dates.splitlines():
        key, value = line.split('=', 1)
        values[key] = dt.datetime.strptime(value, '%b %d %H:%M:%S %Y %Z').replace(tzinfo=dt.timezone.utc)
    require(values['notBefore'] <= now < values['notAfter'], 'Signing certificate is not currently valid')
    subject = run_openssl(['x509', '-inform', 'DER', '-noout', '-subject', '-nameopt', 'RFC2253'], der).decode().strip()
    subject = re.sub(r'^subject\s*=\s*', '', subject)
    teams = re.findall(r'(?:^|,)OU=([A-Z0-9]{10})(?=,|$)', subject)
    require(len(teams) == 1, 'Signing certificate must identify one Apple team')
    require(re.search(r'(?:^|,)CN=(?:Apple|iPhone) Distribution(?:[^,]*)(?:,|$)', subject),
            'Signing certificate is not a distribution certificate')
    return {'sha256': fingerprint, 'team': teams[0], 'expiration': iso(values['notAfter'])}


def safe_archive(archive):
    names = archive.namelist()
    require(len(names) == len(set(names)), 'Duplicate ZIP paths')
    require(names, 'Empty ZIP archive')
    for item in archive.infolist():
        name = item.filename
        path = PurePosixPath(name)
        normalized = str(path) + ('/' if item.is_dir() else '')
        require(name and '\\' not in name and '\x00' not in name and ':' not in name
                and not path.is_absolute() and '..' not in path.parts and normalized == name,
                'Unsafe or noncanonical ZIP path')
        require(item.orig_filename == item.filename, 'Noncanonical original ZIP path')
        require(stat.S_IFMT(item.external_attr >> 16) in (0, stat.S_IFREG, stat.S_IFDIR), 'Unsupported ZIP entry file type')
        require(not item.flag_bits & 1, 'Unexpected encrypted ZIP member')
    require(archive.testzip() is None, 'ZIP CRC verification failed')
    return names


def macho_slices(data):
    magic = data[:4]
    if magic in MACH_MAGICS - {b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca',
                              b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}:
        return [data]
    require(magic in MACH_MAGICS and len(data) >= 8, 'Invalid Mach-O header')
    endian = '>' if magic[:1] == b'\xca' else '<'
    is_64 = magic in (b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca')
    count = struct.unpack_from(endian + 'I', data, 4)[0]
    entry_size = 32 if is_64 else 20
    table_end = 8 + count * entry_size
    require(0 < count <= 32 and table_end <= len(data), 'Invalid fat Mach-O table')
    slices, ranges = [], []
    for index in range(count):
        entry = 8 + index * entry_size
        offset, size = struct.unpack_from(endian + ('QQ' if is_64 else 'II'), data, entry + 8)
        require(size and offset >= table_end and offset + size <= len(data), 'Invalid fat Mach-O slice')
        require(all(offset + size <= start or end <= offset for start, end in ranges), 'Overlapping Mach-O slices')
        ranges.append((offset, offset + size))
        piece = data[offset:offset + size]
        require(piece[:4] in (b'\xce\xfa\xed\xfe', b'\xcf\xfa\xed\xfe',
                               b'\xfe\xed\xfa\xce', b'\xfe\xed\xfa\xcf'), 'Invalid nested Mach-O slice')
        slices.append(piece)
    return slices


def commands(data):
    magic = data[:4]
    endian = '<' if magic in (b'\xce\xfa\xed\xfe', b'\xcf\xfa\xed\xfe') else '>'
    header = 32 if magic in (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf') else 28
    require(len(data) >= header, 'Truncated Mach-O header')
    cpu = struct.unpack_from(endian + 'I', data, 4)[0]
    count, size = struct.unpack_from(endian + 'II', data, 16)
    end = header + size
    require(count <= 65536 and end <= len(data), 'Invalid Mach-O load command table')
    result, offset = [], header
    for _ in range(count):
        require(offset + 8 <= end, 'Truncated Mach-O load command')
        command, length = struct.unpack_from(endian + 'II', data, offset)
        require(length >= 8 and length % 4 == 0 and offset + length <= end, 'Invalid Mach-O load command size')
        result.append((command, data[offset:offset + length]))
        offset += length
    require(offset == end, 'Mach-O command count and size differ')
    return endian, cpu, result


def cstring(blob, offset):
    require(0 < offset < len(blob), 'Invalid code signature string offset')
    end = blob.find(b'\x00', offset)
    require(end >= offset, 'Unterminated code signature string')
    return blob[offset:end].decode('utf-8')


def superblob(data):
    require(len(data) >= 12, 'Truncated Mach-O signature')
    magic, length, count = struct.unpack_from('>III', data)
    require(magic == 0xFADE0CC0 and 12 <= length <= len(data) and count <= 1024,
            'Invalid Mach-O embedded signature')
    table_end = 12 + count * 8
    require(table_end <= length, 'Truncated signature index')
    slots, spans = {}, []
    for index in range(count):
        slot, offset = struct.unpack_from('>II', data, 12 + index * 8)
        require(slot not in slots and table_end <= offset and offset + 8 <= length,
                'Invalid or duplicate signature slot')
        _, size = struct.unpack_from('>II', data, offset)
        require(size >= 8 and offset + size <= length, 'Invalid signature blob length')
        require(all(offset + size <= start or end <= offset for start, end in spans),
                'Overlapping signature blobs')
        slots[slot] = data[offset:offset + size]
        spans.append((offset, offset + size))
    require(0 in slots and 0x10000 in slots, 'Missing CodeDirectory or CMS signature')
    require(struct.unpack_from('>I', slots[0])[0] == 0xFADE0C02, 'Invalid primary CodeDirectory')
    require(struct.unpack_from('>I', slots[0x10000])[0] == 0xFADE0B01, 'Invalid CMS signature wrapper')
    return slots


def code_directory(blob, executable, signature_offset, slots, external_slots):
    require(len(blob) >= 44 and struct.unpack_from('>I', blob)[0] == 0xFADE0C02, 'Invalid CodeDirectory')
    _, length, version, _, hash_offset, ident_offset, special_count, count, limit = struct.unpack_from('>9I', blob)
    hash_size, hash_type, _, page_exp = struct.unpack_from('>4B', blob, 36)
    algorithms = {1: ('sha1', 20), 2: ('sha256', 32), 3: ('sha256', 20),
                  4: ('sha384', 48), 5: ('sha512', 64)}
    require(length == len(blob) and version >= 0x20001 and hash_type in algorithms,
            'Unsupported CodeDirectory')
    algorithm, expected_size = algorithms[hash_type]
    require(hash_size == expected_size and page_exp <= 30, 'Invalid CodeDirectory hash parameters')
    minimum_length = 44 if version < 0x20100 else 48
    if version >= 0x20200:
        minimum_length = 52
    if version >= 0x20300:
        minimum_length = 64
    if version >= 0x20400:
        minimum_length = 88
    if version >= 0x20500:
        minimum_length = 96
    if version >= 0x20600:
        minimum_length = 108
    require(len(blob) >= minimum_length, 'Truncated versioned CodeDirectory')
    if version >= 0x20100:
        require(struct.unpack_from('>I', blob, 44)[0] == 0, 'Scatter CodeDirectories are unsupported')
    if version >= 0x20300 and limit == 0xFFFFFFFF:
        limit = struct.unpack_from('>Q', blob, 56)[0]
    require(0 < limit == signature_offset <= len(executable), 'Invalid or partially unsigned signed-code limit')
    page_size = (1 << page_exp) if page_exp else limit
    require(count == (limit + page_size - 1) // page_size, 'Incorrect code-page count')
    require(hash_offset - special_count * hash_size >= minimum_length
            and hash_offset + count * hash_size <= len(blob), 'CodeDirectory hashes out of bounds')
    def hashed(value):
        return hashlib.new(algorithm, value).digest()[:hash_size]
    for index in range(count):
        start = index * page_size
        require(hashed(executable[start:min(start + page_size, limit)])
                == blob[hash_offset + index * hash_size:hash_offset + (index + 1) * hash_size],
                'Signed Mach-O code-page hash mismatch')
    for slot, value in {**slots, **external_slots}.items():
        if 0 < slot < 0x1000:
            require(slot <= special_count, 'Signature metadata is not bound by the CodeDirectory')
            require(hashed(value) == blob[hash_offset - slot * hash_size:hash_offset - (slot - 1) * hash_size],
                    'Signed Mach-O entitlement or resource hash mismatch')
    known_special = {slot for slot in {**slots, **external_slots} if 0 < slot < 0x1000}
    for slot in range(1, special_count + 1):
        value = blob[hash_offset - slot * hash_size:hash_offset - (slot - 1) * hash_size]
        require(slot in known_special or not any(value),
                'Unsupported nonzero CodeDirectory special slot without corresponding data')
    require(minimum_length <= ident_offset < hash_offset - special_count * hash_size,
            'CodeDirectory identifier overlaps hash data')
    identifier = cstring(blob, ident_offset)
    team_offset = struct.unpack_from('>I', blob, 48)[0] if version >= 0x20200 else 0
    if team_offset:
        require(minimum_length <= team_offset < hash_offset - special_count * hash_size,
                'CodeDirectory team overlaps hash data')
    team = cstring(blob, team_offset) if team_offset else None
    return identifier, team


def cms_signer(cms, directory, temporary):
    content = temporary / 'code-directory.bin'
    signer = temporary / 'cms-signer.pem'
    content.write_bytes(directory)
    # Validate the CMS signature; no Apple CA/chain trust assertion is made.
    run_openssl(['cms', '-verify', '-binary', '-inform', 'DER', '-noverify',
                 '-content', str(content), '-signer', str(signer)], cms)
    certificates = re.findall(br'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----', signer.read_bytes(), re.S)
    require(len(certificates) == 1, 'Expected exactly one CMS signer')
    return ssl.PEM_cert_to_DER_cert(certificates[0].decode())


def embedded_info_plist(executable, load_commands, endian, signature_offset):
    """Read the signed __TEXT,__info_plist used by standalone Mach-O dylibs.

    A standalone dylib can bind CodeDirectory slot 1 to this section even though
    it has no enclosing bundle Info.plist. Use its complete section bytes,
    including any padding, rather than reserializing the parsed dictionary.
    """
    found = []
    for kind, command in load_commands:
        if kind not in (0x1, 0x19):  # LC_SEGMENT and LC_SEGMENT_64
            continue
        is64 = kind == 0x19
        header_size, section_size = (72, 80) if is64 else (56, 68)
        require(len(command) >= header_size, 'Truncated embedded-info segment')
        count = struct.unpack_from(endian + 'I', command, 64 if is64 else 48)[0]
        require(header_size + count * section_size <= len(command), 'Truncated embedded-info section table')
        segment = command[8:24].rstrip(b'\0')
        for index in range(count):
            offset = header_size + index * section_size
            section = command[offset:offset + section_size]
            if segment != b'__TEXT' or section[:16].rstrip(b'\0') != b'__info_plist':
                continue
            require(section[16:32].rstrip(b'\0') == b'__TEXT', 'Embedded-info section segment mismatch')
            size = struct.unpack_from(endian + ('Q' if is64 else 'I'), section, 40 if is64 else 36)[0]
            file_offset = struct.unpack_from(endian + 'I', section, 48 if is64 else 40)[0]
            flags = struct.unpack_from(endian + 'I', section, 64 if is64 else 56)[0]
            require(flags & 0xFF not in (1, 0xC, 0x12) and 0 < size <= 1024 * 1024
                    and 0 < file_offset < signature_offset
                    and file_offset + size <= signature_offset <= len(executable),
                    'Embedded Info.plist is not bounded by signed file data')
            value = executable[file_offset:file_offset + size]
            try:
                parsed = plistlib.loads(value)
            except (ValueError, TypeError, plistlib.InvalidFileException):
                raise VerificationError('Invalid embedded Info.plist') from None
            require(isinstance(parsed, dict), 'Embedded Info.plist is not a dictionary')
            found.append(value)
    require(len(found) <= 1, 'Ambiguous embedded Info.plist sections')
    return found[0] if found else None


def verify_macho(data, temporary, certificate_cache, now, expected=None, external_slots=None):
    records = []
    for executable in macho_slices(data):
        endian, cpu, load_commands = commands(executable)
        signatures = [raw for command, raw in load_commands if command == 0x1D]
        require(len(signatures) == 1 and len(signatures[0]) == 16, 'Expected one LC_CODE_SIGNATURE per slice')
        offset, size = struct.unpack_from(endian + 'II', signatures[0], 8)
        require(size and offset + size <= len(executable), 'Mach-O signature out of bounds')
        for command, raw in load_commands:
            if command in (0x21, 0x2C):
                require(len(raw) >= 20 and struct.unpack_from(endian + 'I', raw, 16)[0] == 0,
                        'Unexpected encrypted Mach-O')
        slots = superblob(executable[offset:offset + size])
        bound_external = dict(external_slots or {})
        embedded_info_used = False
        if 1 not in bound_external:
            embedded_info = embedded_info_plist(executable, load_commands, endian, offset)
            if embedded_info is not None:
                bound_external[1] = embedded_info
                embedded_info_used = True
        cds = [blob for slot, blob in slots.items() if slot == 0 or 0x1000 <= slot <= 0x1005]
        identities = [code_directory(blob, executable, offset, slots, bound_external) for blob in cds]
        require(len(set(identities)) == 1, 'CodeDirectories disagree on code identity')
        identifier, team = identities[0]
        der = cms_signer(slots[0x10000][8:], slots[0], temporary)
        fingerprint = hashlib.sha256(der).hexdigest()
        if fingerprint not in certificate_cache:
            certificate_cache[fingerprint] = certificate_details(der, now)
        require(team == certificate_cache[fingerprint]['team'], 'CodeDirectory team differs from signer certificate')
        xml = None
        if 5 in slots:
            require(struct.unpack_from('>I', slots[5])[0] == 0xFADE7171, 'Invalid XML entitlement blob')
            xml = plistlib.loads(slots[5][8:])
            require(isinstance(xml, dict), 'Entitlements are not a dictionary')
        if 7 in slots:
            require(struct.unpack_from('>I', slots[7])[0] == 0xFADE7172 and len(slots[7]) > 8,
                    'Invalid DER entitlement blob')
        if expected:
            require(cpu == 0x0100000C, 'Application executable is not ARM64')
            require(identifier == expected['identifier'], 'Signed code identity differs from bundle identity')
            require(xml == expected['entitlements'], 'Signed XML entitlements differ from concrete profile grants')
            require(7 in slots, 'Missing generated DER entitlements')
            require(fingerprint in expected['certificate_fingerprints'], 'Signer certificate is not granted by profile')
        records.append({'certificate_sha256': fingerprint, 'xml_entitlements': xml,
                        'der_entitlements_present': 7 in slots,
                        'embedded_info_plist_special_slot_verified': embedded_info_used})
    require(len({record['certificate_sha256'] for record in records}) == 1,
            'Mach-O slices use different signing certificates')
    return records


def identifier_grant_matches(grant, identifier):
    """Recognize Apple exact IDs, '*' and a single final-segment wildcard."""
    if not isinstance(grant, str) or not isinstance(identifier, str):
        return False
    if '*' not in grant:
        return grant == identifier
    if grant == '*':
        return bool(identifier)
    return (grant.count('*') == 1 and grant.endswith('.*')
            and identifier.startswith(grant[:-1]) and len(identifier) > len(grant) - 1)


def concrete_entitlements(profile, identifier):
    require(identifier in EXPECTED_IDS, 'Entitlement target is outside the authorized bundle scope')
    entitlements = plistlib.loads(plistlib.dumps(profile['Entitlements']))
    application_grant = entitlements.get('application-identifier')
    require(isinstance(application_grant, str) and '.' in application_grant, 'Missing profile application identifier')
    prefix, bundle_grant = application_grant.split('.', 1)
    require(identifier_grant_matches(bundle_grant, identifier)
            and prefix in profile.get('ApplicationIdentifierPrefix', []),
            'Profile application identity mismatch')
    application_id = prefix + '.' + identifier
    entitlements['application-identifier'] = application_id
    team = entitlements.get('com.apple.developer.team-identifier')
    require(team in profile.get('TeamIdentifier', []) and entitlements.get('get-task-allow') is False,
            'Profile team or Ad Hoc entitlement mismatch')
    groups = entitlements.get('keychain-access-groups')
    if groups is not None:
        require(isinstance(groups, list) and groups, 'Invalid profile keychain grants')
        require(all(isinstance(group, str) for group in groups), 'Invalid profile keychain grant type')
        # Provisioning values are an allowlist, not rights to copy verbatim.
        # Independently derive only this bundle's own group and, if explicitly
        # granted, the common root group used by the Bump compatibility shim.
        require(any(identifier_grant_matches(group, application_id) for group in groups),
                'Profile has no scoped app keychain grant')
        concrete = [application_id]
        common = prefix + '.' + ROOT_ID
        if common != application_id and any(identifier_grant_matches(group, common) for group in groups):
            concrete.append(common)
        entitlements['keychain-access-groups'] = concrete
    def wildcard(value):
        if isinstance(value, str):
            return '*' in value
        if isinstance(value, dict):
            return any(wildcard(item) for item in value.values())
        if isinstance(value, list):
            return any(wildcard(item) for item in value)
        return False
    require(not wildcard(entitlements), 'Wildcard entitlement remained in concrete grants')
    return entitlements


def selected_keychain_group(entitlements):
    application_id = entitlements.get('application-identifier', '')
    require(isinstance(application_id, str) and '.' in application_id, 'Invalid concrete app identity')
    prefix = application_id.split('.', 1)[0]
    groups = entitlements.get('keychain-access-groups')
    require(isinstance(groups, list) and application_id in groups, 'Missing concrete own-keychain right')
    common = prefix + '.' + ROOT_ID
    require(set(groups) <= {application_id, common} and len(groups) == len(set(groups)),
            'Unexpected broad or duplicate keychain right')
    return common if common in groups else application_id


def _verify_main_provenance(original, signed):
    require(original[:4] == signed[:4] == b'\xcf\xfa\xed\xfe',
            'Main provenance requires thin ARM64 Mach-O')
    original_endian, original_cpu, old = commands(original)
    signed_endian, signed_cpu, new = commands(signed)
    require(original_endian == signed_endian == '<' and original_cpu == signed_cpu == 0x100000C,
            'Main architecture changed')
    require(original[:16] == signed[:16] and original[24:32] == signed[24:32],
            'Main Mach-O header changed outside load-command counts')

    def signature(raw_commands):
        signatures = [raw for kind, raw in raw_commands if kind == 0x1D]
        require(len(signatures) == 1 and len(signatures[0]) == 16, 'Expected one main signature command')
        return struct.unpack_from('<II', signatures[0], 8)

    original_signature, original_signature_size = signature(old)
    signed_signature, signed_signature_size = signature(new)
    require(original_signature + original_signature_size <= len(original)
            and signed_signature + signed_signature_size <= len(signed),
            'Main signature region exceeds the file')
    require(147456 <= original_signature <= signed_signature,
            'Signed main truncated original code or data')
    # Independently recognize exactly the reviewed 12-byte registry-key change.
    # A partial patch, any different instruction or any other payload change fails.
    identity_changes = [
        (0x363C98, bytes.fromhex("72d12294"), bytes.fromhex("97feff97")),
        (0x363C9C, bytes.fromhex("080040f9"), bytes.fromhex("e80300aa")),
        (0x363CA0, bytes.fromhex("020d4ba9"), bytes.fromhex("020d41a9")),
    ]
    original_body = original[147456:original_signature]
    signed_body = signed[147456:original_signature]
    identity_applied = original_body != signed_body
    if identity_applied:
        restored = bytearray(signed_body)
        for offset, expected, replacement in identity_changes:
            require(original[offset:offset + 4] == expected and signed[offset:offset + 4] == replacement,
                    'Main executable code or data changed outside exact app recognition patch')
            restored[offset - 147456:offset - 147456 + 4] = expected
        require(bytes(restored) == original_body,
                'Main executable code or data changed outside exact app recognition patch')

    def normalized(raw_commands, injected):
        result, dependencies = [], []
        for kind, raw in raw_commands:
            if kind == 0x1D:
                continue
            if kind in (0xC, 0x80000018, 0x8000001F, 0x20, 0x80000023):
                require(len(raw) >= 24, 'Truncated dylib dependency')
                name = cstring(raw, struct.unpack_from('<I', raw, 8)[0])
                if name == ADAPTER:
                    dependencies.append(name)
                    continue
            if kind == 0x19 and raw[8:24].rstrip(b'\0') == b'__LINKEDIT':
                require(len(raw) >= 72, 'Truncated __LINKEDIT segment')
                raw = bytearray(raw)
                raw[32:40] = b'\0' * 8  # vmsize can grow during signing
                raw[48:56] = b'\0' * 8  # filesize can grow during signing
                raw = bytes(raw)
            result.append((kind, raw))
        require(len(dependencies) == (1 if injected else 0), 'Debug dylib dependency count mismatch')
        return result

    require(normalized(old, False) == normalized(new, True),
            'Unexpected main load-command mutation')
    return {'original_main_code_and_data_unchanged': not identity_applied,
            'original_main_unchanged_except_reviewed_identity_patch': True,
            'app_identity_patch': {'applied': identity_applied, 'bytes_replaced': 12 if identity_applied else 0,
                'instructions': [{'offset': off, 'original': old.hex(), 'replacement': new.hex()}
                                 for off, old, new in identity_changes] if identity_applied else []},
            'first_original_section_offset': 147456,
            'allowed_changes': 'reviewed 12-byte native Bump registry key, load-command injection, signature region and __LINKEDIT signing sizes'}


def _external_slots(archive, names):
    result = {}
    for name in names:
        if not name.endswith('/Info.plist'):
            continue
        bundle = name.rsplit('/', 1)[0]
        if not bundle.endswith(('.app', '.appex', '.framework')):
            continue
        info = plistlib.loads(archive.read(name))
        executable = info.get('CFBundleExecutable') if isinstance(info, dict) else None
        if not executable:
            continue
        require(isinstance(executable, str) and '/' not in executable and '\\' not in executable
                and executable not in ('.', '..'), 'Invalid bundle executable name')
        path = bundle + '/' + executable
        if path in names:
            values = {1: archive.read(name)}
            resource = bundle + '/_CodeSignature/CodeResources'
            if resource in names:
                values[3] = archive.read(resource)
            result[path] = values
    return result


def _require_executable_mode(archive, path):
    require(archive.getinfo(path).external_attr >> 16 & 0o111,
            'Signed Mach-O executable permission is missing')


def _verify_original(archive, original_path):
    require(digest_file(original_path) == ORIGINAL_SHA, 'Original IPA differs from the pinned user input')
    with zipfile.ZipFile(original_path) as original:
        original_info = plistlib.loads(original.read(APP + '/Info.plist'))
        require(original_info.get('CFBundleIdentifier') == 'co.amo.ios.location'
                and original_info.get('CFBundleShortVersionString') == '2.135.0'
                and original_info.get('CFBundleVersion') == '261126153935',
                'Pinned original metadata is inconsistent')
        return _verify_main_provenance(original.read(APP + '/Location'), archive.read(APP + '/Location'))


def verify(ipa, original_path, receipt_path=None):
    ipa, original_path = Path(ipa), Path(original_path)
    now = dt.datetime.now(dt.timezone.utc)
    digest = digest_file(ipa)
    receipt = json.loads(Path(receipt_path).read_text()) if receipt_path else None
    if receipt is not None:
        require(receipt.get('sha256') == digest, 'Signed IPA SHA256 differs from CI receipt')
        require(receipt.get('input_sha256') == ORIGINAL_SHA, 'CI receipt input hash differs from pinned original')
        require(receipt.get('bundle_identifier') == ROOT_ID, 'CI receipt bundle identity mismatch')
        require(receipt.get('provisioned_bundle_count') == 9, 'CI receipt bundle count mismatch')
    certificate_cache, provisioned_devices, profile_ids = {}, set(), set()
    total_macho = total_slices = total_embedded_info = 0
    all_signers, verified_executables, seen_ids = set(), set(), set()
    profiles = []
    with tempfile.TemporaryDirectory(prefix='bump-independent-check-') as directory, zipfile.ZipFile(ipa) as archive:
        temporary = Path(directory)
        names = safe_archive(archive)
        name_set = set(names)
        files = {item.filename for item in archive.infolist() if not item.is_dir()}
        require(all(not any('/'.join(name.split('/')[:i]) in files
                            for i in range(1, len(name.split('/')))) for name in name_set),
                'ZIP path conflicts with a parent file')
        root_infos = [name for name in names if name.startswith('Payload/') and name.count('/') == 2
                      and name.endswith('.app/Info.plist')]
        require(root_infos == [APP + '/Info.plist'], 'Expected the single Bump root application')
        bundle_infos = root_infos + sorted(name for name in names if name.startswith(APP + '/PlugIns/')
                                          and name.count('/') == 4 and name.endswith('.appex/Info.plist'))
        nested_infos = [name for name in names if name.endswith(('.appex/Info.plist', '.app/Info.plist'))]
        require(len(bundle_infos) == 9 and set(bundle_infos) == set(nested_infos),
                'Expected root app and exactly eight extensions')
        external = _external_slots(archive, name_set)
        provenance = _verify_original(archive, original_path)
        for info_path in bundle_infos:
            bundle = info_path.rsplit('/', 1)[0]
            info = plistlib.loads(archive.read(info_path))
            identifier = info.get('CFBundleIdentifier')
            require(identifier in EXPECTED_IDS and identifier not in seen_ids, 'Unexpected or duplicate bundle identity')
            seen_ids.add(identifier)
            require(info.get('CFBundleShortVersionString') == '2.135.0' and info.get('CFBundleVersion') == '261126153935',
                    'Bump bundle version/build mismatch')
            executable = info.get('CFBundleExecutable')
            require(isinstance(executable, str) and executable and '/' not in executable and '\\' not in executable
                    and executable not in ('.', '..'), 'Invalid executable name')
            executable_path = bundle + '/' + executable
            require(executable_path in names and 3 in external.get(executable_path, {}),
                    'Missing executable or signed bundle resource seal')
            _require_executable_mode(archive, executable_path)
            profile_raw = archive.read(bundle + '/embedded.mobileprovision')
            profile = plistlib.loads(run_openssl(['cms', '-verify', '-binary', '-inform', 'DER', '-noverify'], profile_raw))
            require(isinstance(profile, dict), 'Provisioning profile is not a dictionary')
            require(utc(profile.get('CreationDate')) <= now < utc(profile.get('ExpirationDate')),
                    'Provisioning profile is not currently valid')
            profile_ids.add(str(uuid.UUID(profile.get('UUID', ''))))
            require(not profile.get('ProvisionsAllDevices'), 'Unexpected enterprise profile')
            devices = profile.get('ProvisionedDevices')
            require(isinstance(devices, list) and len(devices) == 1 and isinstance(devices[0], str) and devices[0],
                    'Profile must target exactly one device')
            provisioned_devices.add(devices[0])
            certs = profile.get('DeveloperCertificates')
            require(isinstance(certs, list) and certs and all(isinstance(cert, bytes) for cert in certs),
                    'Missing provisioning certificate grants')
            grants = {hashlib.sha256(cert).hexdigest() for cert in certs}
            entitlements = concrete_entitlements(profile, identifier)
            require(info.get('KEYCHAIN_SHARED_GROUP') == selected_keychain_group(entitlements),
                    'Bundle selected keychain group differs from granted concrete group')
            records = verify_macho(archive.read(executable_path), temporary, certificate_cache, now,
                                  expected={'identifier': identifier, 'entitlements': entitlements,
                                            'certificate_fingerprints': grants}, external_slots=external[executable_path])
            signer = records[0]['certificate_sha256']
            require(entitlements['com.apple.developer.team-identifier'] == certificate_cache[signer]['team'],
                    'Profile team differs from signer certificate')
            all_signers.add(signer)
            total_macho += 1
            total_slices += len(records)
            total_embedded_info += sum(record['embedded_info_plist_special_slot_verified'] for record in records)
            verified_executables.add(executable_path)
            profiles.append({'bundle_identifier': identifier,
                             'application_identifier_kind': 'wildcard' if '*' in profile['Entitlements']['application-identifier'] else 'explicit',
                             'entitlement_keys': sorted(entitlements),
                             'xml_entitlements_match_concrete_profile': True})
        require(seen_ids == EXPECTED_IDS and len(provisioned_devices) == 1,
                'Bundles or provisioned device differ across profiles')
        for item in archive.infolist():
            if item.is_dir() or item.filename in verified_executables or item.file_size < 4:
                continue
            with archive.open(item) as stream:
                magic = stream.read(4)
            if magic in MACH_MAGICS:
                _require_executable_mode(archive, item.filename)
                records = verify_macho(archive.read(item), temporary, certificate_cache, now,
                                       external_slots=external.get(item.filename))
                all_signers.update(record['certificate_sha256'] for record in records)
                total_macho += 1
                total_slices += len(records)
                total_embedded_info += sum(record['embedded_info_plist_special_slot_verified'] for record in records)
                verified_executables.add(item.filename)
        require(len(all_signers) == 1, 'Nested code uses a different signing certificate')
        if receipt is not None and 'certificate_sha256' in receipt:
            require(receipt['certificate_sha256'] == next(iter(all_signers)), 'Signer differs from CI receipt')
        adapter_path = APP + '/Frameworks/BumpLocationDebug.dylib'
        require(adapter_path in verified_executables, 'Missing verified location-debug dylib')
    return {'file': ipa.name, 'sha256': digest, 'bytes': ipa.stat().st_size, 'validated_at': iso(now),
            'input_sha256': ORIGINAL_SHA, 'ci_receipt_hash_matched': receipt is not None,
            'independently_verified': {'zip_integrity_and_safe_unique_paths': True,
                                      'bundle_count': 9, 'all_bundle_ids_and_versions_matched': True,
                                      'same_single_provisioned_device': True,
                                      'distinct_profile_count': len(profile_ids),
                                      'profile_cms_signatures_and_expiry': True,
                                      'code_signer_matches_profile_grants': True,
                                      'single_valid_distribution_certificate': True,
                                      'signed_macho_file_count': total_macho, 'signed_macho_slice_count': total_slices,
                                      'cms_signature_and_code_page_hashes': True,
                                      'signature_special_slot_hashes': True,
                                      'embedded_info_plist_special_slots_verified': total_embedded_info,
                                      'executable_modes': True,
                                      'main_provenance': provenance, 'profiles': profiles},
            'limitations': ['Apple CA trust, certificate revocation and macOS codesign are not independently checked on Linux.',
                            'Resource manifests are signature-bound; individual file seals rely on CI codesign verification.',
                            'DER entitlement blobs are signature-bound; XML entitlements are parsed and compared with profiles.',
                            'Device installation, launch, scratch behavior, background updates, notifications and widgets were not tested.']}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ipa', type=Path)
    parser.add_argument('--original', required=True, type=Path)
    parser.add_argument('--receipt', type=Path)
    args = parser.parse_args(argv)
    try:
        result = verify(args.ipa, args.original, args.receipt)
    except (ValueError, KeyError, OSError, struct.error, zipfile.BadZipFile) as error:
        # Some exception messages contain UUIDs or file contents. Emit only the
        # deliberately authored validation errors, never subprocess diagnostics.
        message = str(error) if isinstance(error, VerificationError) else type(error).__name__
        parser.exit(1, 'Independent Bump verification failed: ' + message + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()



