#!/usr/bin/env python3
"""Package the pinned Bump input with a location-debug dylib; never sign it."""

from __future__ import annotations

import argparse
import copy
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import shutil
import stat
import struct
import tempfile
import zipfile


INPUT_SHA256 = "0b18338b5db68e39ba1de6f5e45c8c79d2211d25da58dc9d4ffa6783bb41773e"
APP_PATH = "Payload/Location.app"
LIBRARY_NAME = "BumpLocationDebug.dylib"
LIBRARY_PATH = APP_PATH + "/Frameworks/" + LIBRARY_NAME
LOAD_PATH = "@executable_path/Frameworks/" + LIBRARY_NAME
LC_CODE_SIGNATURE = 0x1D
LC_SEGMENT_64 = 0x19
DYLIB_COMMANDS = {0xC, 0xD, 0x80000018, 0x8000001F, 0x20, 0x80000023}
LINKEDIT_COMMANDS = {0x1D, 0x1E, 0x26, 0x29, 0x2B, 0x2E, 0x80000033, 0x80000034, 0x36}


class PackagingError(ValueError):
    """Input is outside the explicitly supported packaging contract."""


@dataclass(frozen=True)
class _InputContract:
    """Internal test seam. The command line always uses PINNED_INPUT."""

    sha256: str
    app_path: str = APP_PATH
    bundle_identifier: str = "co.amo.ios.location"
    version: str = "2.135.0"
    build: str = "261126153935"


PINNED_INPUT = _InputContract(INPUT_SHA256)


def sha256_file(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def _macho_commands(data: bytes, expected_type: int):
    if len(data) < 32 or data[:4] != b"\xcf\xfa\xed\xfe":
        raise PackagingError("Expected a thin little-endian 64-bit Mach-O")
    _, cpu, _, filetype, count, size, _, _ = struct.unpack_from("<8I", data)
    if cpu != 0x100000C or filetype != expected_type:
        raise PackagingError("Expected ARM64 Mach-O with the required file type")
    end = 32 + size
    if end > len(data) or count > size // 8:
        raise PackagingError("Invalid Mach-O load-command bounds")
    commands = []
    offset = 32
    for _ in range(count):
        if offset + 8 > end:
            raise PackagingError("Truncated Mach-O load command")
        command, length = struct.unpack_from("<II", data, offset)
        if length < 8 or length % 8 or offset + length > end:
            raise PackagingError("Invalid Mach-O load-command size")
        commands.append((command, data[offset : offset + length]))
        offset += length
    if offset != end:
        raise PackagingError("Mach-O command count and size disagree")
    return commands, end


def _dylib_name(command: bytes) -> str:
    if len(command) < 24:
        raise PackagingError("Truncated dylib command")
    offset = struct.unpack_from("<I", command, 8)[0]
    if offset < 24 or offset >= len(command):
        raise PackagingError("Invalid dylib command name offset")
    raw = command[offset:]
    if b"\0" not in raw:
        raise PackagingError("Unterminated dylib command name")
    try:
        return raw.split(b"\0", 1)[0].decode("utf-8")
    except UnicodeDecodeError as error:
        raise PackagingError("Invalid dylib command name") from error


def _file_regions(commands, data_length: int):
    """Bound header padding by file-backed sections and link-edit data."""
    regions = []

    def add(offset, size):
        if not size:
            return
        if offset < 0 or offset + size > data_length:
            raise PackagingError("Mach-O file-backed data exceeds the file")
        regions.append(offset)

    for kind, command in commands:
        if kind == LC_SEGMENT_64:
            if len(command) < 72:
                raise PackagingError("Truncated segment command")
            fileoff, filesize = struct.unpack_from("<QQ", command, 40)
            if fileoff:
                add(fileoff, filesize)
            elif filesize > data_length:
                raise PackagingError("Mach-O segment exceeds the file")
            count = struct.unpack_from("<I", command, 64)[0]
            if 72 + count * 80 > len(command):
                raise PackagingError("Truncated segment sections")
            for index in range(count):
                start = 72 + index * 80
                size = struct.unpack_from("<Q", command, start + 40)[0]
                offset = struct.unpack_from("<I", command, start + 48)[0]
                flags = struct.unpack_from("<I", command, start + 64)[0]
                if flags & 0xFF not in (1, 0xC, 0x12):
                    add(offset, size)
        elif kind in LINKEDIT_COMMANDS:
            if len(command) < 16:
                raise PackagingError("Truncated link-edit command")
            add(*struct.unpack_from("<II", command, 8))
        elif kind == 2:  # LC_SYMTAB
            if len(command) < 24:
                raise PackagingError("Truncated symbol-table command")
            symoff, count, stroff, strsize = struct.unpack_from("<4I", command, 8)
            add(symoff, count * 16)
            add(stroff, strsize)
        elif kind in (0x22, 0x80000022):  # LC_DYLD_INFO[_ONLY]
            if len(command) < 48:
                raise PackagingError("Truncated dyld-info command")
            for offset in range(8, 48, 8):
                add(*struct.unpack_from("<II", command, offset))
        elif kind in (0x21, 0x2C):  # LC_ENCRYPTION_INFO[_64]
            if len(command) < (24 if kind == 0x2C else 20):
                raise PackagingError("Truncated encryption command")
            offset, size, cryptid = struct.unpack_from("<III", command, 8)
            if cryptid:
                raise PackagingError("Encrypted Mach-O cannot be packaged")
            add(offset, size)
        elif kind == 0x31:  # LC_NOTE
            if len(command) < 40:
                raise PackagingError("Truncated note command")
            add(*struct.unpack_from("<QQ", command, 24))
    return regions


def _patch_macho(data: bytes, *, inject: bool):
    commands, old_end = _macho_commands(data, 2 if inject else 6)
    regions = _file_regions(commands, len(data))
    for kind, command in commands:
        if kind in DYLIB_COMMANDS:
            name = _dylib_name(command)
            if inject and PurePosixPath(name).name == LIBRARY_NAME:
                raise PackagingError("The main executable already loads the debug dylib")
    retained = [command for kind, command in commands if kind != LC_CODE_SIGNATURE]
    removed = sum(kind == LC_CODE_SIGNATURE for kind, _ in commands)
    if inject:
        encoded = LOAD_PATH.encode() + b"\0"
        length = (24 + len(encoded) + 7) & ~7
        retained.append(struct.pack("<6I", 0xC, length, 24, 0, 0, 0) + encoded + b"\0" * (length - 24 - len(encoded)))
    table = b"".join(retained)
    new_end = 32 + len(table)
    if inject and (not regions or new_end > min(regions)):
        raise PackagingError("Insufficient verified header padding before Mach-O data")
    if new_end > old_end and any(data[old_end:new_end]):
        raise PackagingError("Mach-O header padding is not blank")
    if new_end > len(data):
        raise PackagingError("Mach-O header exceeds the file")
    output = bytearray(data)
    struct.pack_into("<II", output, 16, len(retained), len(table))
    output[32 : max(old_end, new_end)] = table + b"\0" * max(0, old_end - new_end)
    # The file-backed payload and all its original offsets remain intact.
    if output[max(old_end, new_end) :] != data[max(old_end, new_end) :]:
        raise AssertionError("Mach-O payload unexpectedly changed")
    return bytes(output), {
        "signature_commands_removed": removed,
        "old_load_command_end": old_end,
        "new_load_command_end": new_end,
        "payload_offsets_preserved": True,
    }


# GalaxyApps.current in the exact supplied 2.135.0 ARM64 image. Select the
# native Bump entry as the comparison key instead of cached installer URL data.
# The original registry search, value copying and failure path remain intact.
APP_IDENTITY_PATCHES = (
    (0x363C98, bytes.fromhex("72d12294"), bytes.fromhex("97feff97")),
    (0x363C9C, bytes.fromhex("080040f9"), bytes.fromhex("e80300aa")),
    (0x363CA0, bytes.fromhex("020d4ba9"), bytes.fromhex("020d41a9")),
)
REGISTRY_LOOKUP_SHA256 = "6485765d7ed1b01eb5b52d27f148efd3cd4a123b13321312dbf08372cffdee25"
BUMP_GETTER_SHA256 = "488065f35b4d2541d766a2904571e19507aaea7c43b9ae6f27be0a38dfbf327f"


def _patch_app_identity(data: bytes):
    commands, _ = _macho_commands(data, 2)
    uuids = [raw[8:24] for kind, raw in commands if kind == 0x1B and len(raw) == 24]
    if uuids != [bytes.fromhex("ea3612276ee13979b8df242f24fe47dc")]:
        raise PackagingError("App recognition patch requires the pinned executable UUID")
    if (hashlib.sha256(data[0x363C38:0x363D40]).hexdigest() != REGISTRY_LOOKUP_SHA256 or
            hashlib.sha256(data[0x3636F4:0x363720]).hexdigest() != BUMP_GETTER_SHA256):
        raise PackagingError("App recognition code does not match the reviewed ARM64 functions")
    result = bytearray(data)
    changes = []
    for offset, expected, replacement in APP_IDENTITY_PATCHES:
        if data[offset:offset + 4] != expected:
            raise PackagingError("App recognition instruction mismatch")
        result[offset:offset + 4] = replacement
        changes.append({"offset": offset, "original": expected.hex(), "replacement": replacement.hex()})
    return bytes(result), {"kind": "native_bump_registry_key", "instructions": changes,
                           "bytes_replaced": 12, "native_search_and_failure_path_preserved": True}


def _validate_archive(entries):
    seen = set()
    files = set()
    for entry in entries:
        name = entry.filename
        if name != entry.orig_filename or "\0" in name or "\\" in name or name.startswith("/"):
            raise PackagingError("Unsafe ZIP entry path")
        parts = name.rstrip("/").split("/")
        if any(part in ("", ".", "..") for part in parts) or ":" in parts[0]:
            raise PackagingError("Unsafe ZIP entry path")
        canonical = "/".join(parts)
        if canonical in seen:
            raise PackagingError("Duplicate ZIP entry path")
        seen.add(canonical)
        mode = entry.external_attr >> 16
        if stat.S_ISLNK(mode) or stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR):
            raise PackagingError("Unsupported ZIP entry file type")
        if entry.flag_bits & 1:
            raise PackagingError("Encrypted ZIP entries are unsupported")
        if not entry.is_dir():
            files.add(canonical)
    for name in seen:
        if any("/".join(name.split("/")[:i]) in files for i in range(1, len(name.split("/")))):
            raise PackagingError("ZIP entry conflicts with a parent file")


def _is_signature_metadata(name: str) -> bool:
    parts = PurePosixPath(name).parts
    return "_CodeSignature" in parts or bool(parts and parts[-1] == "embedded.mobileprovision")


def _package_ipa(source: Path, library: Path, output: Path, *, contract: _InputContract):
    """Internal packaging implementation; tests supply their own synthetic contract."""
    source, library, output = map(Path, (source, library, output))
    if output.resolve() in (source.resolve(), library.resolve()):
        raise PackagingError("Output must differ from both input files")
    input_hash = sha256_file(source)
    if input_hash != contract.sha256:
        raise PackagingError("Input IPA SHA256 does not match the pinned Bump input")
    library_bytes = library.read_bytes()
    patched_library, library_patch = _patch_macho(library_bytes, inject=False)
    library_path = contract.app_path + "/Frameworks/" + LIBRARY_NAME
    temporary = None
    try:
        with zipfile.ZipFile(source) as archive:
            entries = archive.infolist()
            _validate_archive(entries)
            names = {entry.filename for entry in entries}
            if library_path in names:
                raise PackagingError("The archive already contains the debug dylib")
            root_apps = {n.split("/")[1] for n in names if n.startswith("Payload/") and len(n.split("/")) > 2 and n.split("/")[1].endswith(".app")}
            if root_apps != {contract.app_path.split("/")[1]}:
                raise PackagingError("Unexpected root application bundle")
            info_name = contract.app_path + "/Info.plist"
            try:
                info = plistlib.loads(archive.read(info_name))
            except (KeyError, plistlib.InvalidFileException, ValueError) as error:
                raise PackagingError("Missing or invalid Bump Info.plist") from error
            expected = {"CFBundleIdentifier": contract.bundle_identifier, "CFBundleShortVersionString": contract.version, "CFBundleVersion": contract.build}
            if not isinstance(info, dict) or any(info.get(k) != v for k, v in expected.items()):
                raise PackagingError("Bump bundle identity, version or build does not match")
            executable = info.get("CFBundleExecutable")
            if not isinstance(executable, str) or not executable or "/" in executable or "\\" in executable or executable in (".", ".."):
                raise PackagingError("Invalid root executable name")
            main_name = contract.app_path + "/" + executable
            try:
                main_bytes = archive.read(main_name)
            except KeyError as error:
                raise PackagingError("Missing root executable") from error
            patched_main, main_patch = _patch_macho(main_bytes, inject=True)
            if contract == PINNED_INPUT:
                patched_main, recognition = _patch_app_identity(patched_main)
                main_patch["app_recognition"] = recognition
            output.parent.mkdir(parents=True, exist_ok=True)
            with tempfile.NamedTemporaryFile(prefix=".bump-package-", suffix=".ipa", dir=output.parent, delete=False) as stream:
                temporary = Path(stream.name)
            removed = []
            with zipfile.ZipFile(temporary, "w", allowZip64=True) as target:
                target.comment = archive.comment
                for entry in entries:
                    if _is_signature_metadata(entry.filename):
                        removed.append(entry.filename)
                        continue
                    metadata = copy.copy(entry)
                    if entry.filename == main_name:
                        target.writestr(metadata, patched_main)
                    else:
                        with archive.open(entry) as reader, target.open(metadata, "w", force_zip64=entry.file_size >= zipfile.ZIP64_LIMIT) as writer:
                            shutil.copyfileobj(reader, writer, length=1024 * 1024)
                metadata = zipfile.ZipInfo(library_path, date_time=(2026, 1, 1, 0, 0, 0))
                metadata.create_system = 3
                metadata.external_attr = (stat.S_IFREG | 0o755) << 16
                metadata.compress_type = zipfile.ZIP_DEFLATED
                target.writestr(metadata, patched_library)
            with zipfile.ZipFile(temporary) as verification:
                if verification.testzip() is not None:
                    raise PackagingError("Output archive CRC verification failed")
                if any(_is_signature_metadata(n) for n in verification.namelist()):
                    raise PackagingError("Output retained stale signing metadata")
            digest = sha256_file(temporary)
            os.replace(temporary, output)
            temporary = None
        return {
            "schema_version": 1,
            "file": output.name,
            "sha256": digest,
            "bytes": output.stat().st_size,
            "input_sha256": input_hash,
            "input_bytes": source.stat().st_size,
            "bundle_identifier": contract.bundle_identifier,
            "version": contract.version,
            "build": contract.build,
            "dylib_load_path": LOAD_PATH,
            "dylib_input_sha256": hashlib.sha256(library_bytes).hexdigest(),
            "dylib_packaged_sha256": hashlib.sha256(patched_library).hexdigest(),
            "main_patch": main_patch,
            "dylib_patch": library_patch,
            "removed_signing_metadata_count": len(removed),
            "signature": "unsigned; requires complete nested-code re-signing",
            "runtime_validation": "not performed",
            "device_installation": "not tested",
            "scratch_function": "not tested",
        }
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def package_ipa(source: Path, library: Path, output: Path):
    """Only the exact user-provided Bump input is accepted by the public API."""
    return _package_ipa(source, library, output, contract=PINNED_INPUT)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("dylib", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args(argv)
    try:
        receipt = package_ipa(args.source, args.dylib, args.output)
    except (PackagingError, OSError, zipfile.BadZipFile, RuntimeError) as error:
        parser.exit(1, f"Bump packaging failed: {error}\n")
    print(json.dumps(receipt, indent=2))


if __name__ == "__main__":
    main()
