#!/usr/bin/env python3
"""Read-only, bounded declaration-metadata candidates from the exact supplied IPA.

Names/metadata locations are leads, not proof of bonus eligibility, server
policy, instance-field offsets, callable ABI, or safe patch locations.
No original bytes, URLs, credential values, or full binary dumps are emitted.
Python 3.11 standard library only.
"""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import stat
import struct
import sys
import zipfile
import zlib

ORIGINAL_IPA_BYTES = 142120475
ORIGINAL_IPA_SHA256 = "e7d77665740c61f2b0d6eae21cb6052acd2add364db3f6b5fc9ef9198ac31cbc"
ORIGINAL_MAIN_SHA256 = "d64203bfef02feb41680a43224762e8e5be2f9723e6f62924d8d5bfc2d1b2cd6"
SWIFT_SOURCE = "https://github.com/swiftlang/swift/blob/e0a274b4df3d3f223f3116a563bd48152b484fbf/"
ABI_SOURCES = [
    SWIFT_SOURCE + "include/swift/RemoteInspection/Records.h",
    SWIFT_SOURCE + "include/swift/Basic/RelativePointer.h",
    SWIFT_SOURCE + "lib/Demangling/Demangler.cpp",
    SWIFT_SOURCE + "include/swift/ABI/Metadata.h",
    SWIFT_SOURCE + "include/swift/ABI/MetadataValues.h",
    SWIFT_SOURCE + "lib/IRGen/GenReflection.cpp",
]
TERMS = re.compile(r"bonus|additional|remaining|on_?time|is_?late|moment|deadline|can_?post|quota", re.I)
SENSITIVE = re.compile(r"token|secret|password|credential|authorization|bearer|api_?key|access_?key", re.I)
IDENTIFIER = re.compile(r"[A-Za-z_$][A-Za-z0-9_.$]*(?::[A-Za-z0-9_$]*)*\Z")
FRAGMENT = re.compile(r"[A-Za-z0-9_.$]+\Z")
MAX_MAIN = 256 * 1024 * 1024
MAX_SECTION = 32 * 1024 * 1024
MAX_MODELS = 48
MAX_FIELDS = 24
MAX_STRINGS = 96
MAX_SYMBOLS = 96
MAX_JSON = 512 * 1024


class InspectionError(ValueError):
    pass


def need(condition, code):
    if not condition:
        raise InspectionError(code)


def digest_file(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def safe_name(value, fragment=False):
    if not isinstance(value, str) or not 1 <= len(value) <= 240:
        return None
    expression = FRAGMENT if fragment else IDENTIFIER
    if not expression.fullmatch(value) or SENSITIVE.search(value):
        return None
    if not re.search(r"[A-Za-z]", value) or re.fullmatch(r"[0-9A-Fa-f]{20,}", value):
        return None
    return value


def matches(value):
    return sorted({item.group(0).lower() for item in TERMS.finditer(value or "")})


def rank(row):
    terms = row.get("matches", [])
    priority = 0 if any("bonus" in term or "quota" in term or "can" in term for term in terms) else 1
    return priority, row.get("name", row.get("owner_name") or ""), row.get("file_offset", "")


def safe_zip(archive):
    members = archive.infolist()
    need(0 < len(members) <= 100000, "zip_member_count")
    names, total = set(), 0
    for item in members:
        name = item.filename
        path = PurePosixPath(name)
        need(name and len(name) <= 1024 and "\0" not in item.orig_filename and "\\" not in name
             and not path.is_absolute() and ".." not in path.parts
             and "." not in name.rstrip("/").split("/") and "//" not in name, "zip_path")
        need(name not in names, "zip_duplicate_path")
        names.add(name)
        need(not (item.flag_bits & 1), "zip_encrypted_member")
        need(item.compress_type in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED), "zip_compression")
        mode = (item.external_attr >> 16) & 0xFFFF
        need(not stat.S_ISLNK(mode), "zip_symlink")
        need(0 <= item.file_size <= MAX_MAIN, "zip_member_size")
        total += item.file_size
        need(total <= 2 * 1024 * 1024 * 1024, "zip_total_size")
    return names


def bounded_member(archive, name, limit):
    item = archive.getinfo(name)
    need(not item.is_dir() and item.file_size <= limit, "zip_selected_member_size")
    with archive.open(item) as stream:
        result = stream.read(limit + 1)
    need(len(result) == item.file_size and len(result) <= limit, "zip_selected_member_length")
    return result


class MachO:
    def __init__(self, data):
        need(isinstance(data, bytes) and 32 <= len(data) <= MAX_MAIN, "macho_size")
        self.data, self.segments, self.sections = data, [], []
        self.symtab, self.unresolved = None, 0
        magic, cpu, subtype, filetype, count, size, _, _ = struct.unpack_from("<8I", data)
        need((magic, cpu, subtype, filetype) == (0xFEEDFACF, 0x0100000C, 0, 2), "macho_arm64_executable")
        need(0 < count <= 8192 and 8 * count <= size <= 16 * 1024 * 1024
             and 32 + size <= len(data), "macho_command_table")
        cursor, end, cryptids = 32, 32 + size, []
        for _ in range(count):
            need(cursor + 8 <= end, "macho_command_header")
            command, length = struct.unpack_from("<II", data, cursor)
            need(length >= 8 and length % 8 == 0 and cursor + length <= end, "macho_command_size")
            if command == 0x19:
                need(length >= 72, "macho_segment_header")
                segname, vm, vmsize, fileoff, filesize, _, _, nsects, _ = struct.unpack_from("<16s4Q4I", data, cursor + 8)
                need(nsects <= 4096 and length == 72 + nsects * 80, "macho_section_table")
                need(fileoff + filesize <= len(data) and filesize <= vmsize, "macho_segment_bounds")
                segment = {"name": self.fixed_name(segname), "vm": vm, "vmsize": vmsize,
                           "offset": fileoff, "size": filesize}
                self.segments.append(segment)
                for index in range(nsects):
                    raw = struct.unpack_from("<16s16sQQ8I", data, cursor + 72 + index * 80)
                    section = {"name": self.fixed_name(raw[0]), "segment": self.fixed_name(raw[1]),
                               "vm": raw[2], "size": raw[3], "offset": raw[4], "flags": raw[8]}
                    need(section["segment"] == segment["name"]
                         and vm <= section["vm"] <= vm + vmsize
                         and section["vm"] + section["size"] <= vm + vmsize, "macho_section_vm")
                    section["backed"] = section["flags"] & 0xFF not in (1, 0xC, 0x12)
                    if section["backed"] and section["size"]:
                        need(fileoff <= section["offset"]
                             and section["offset"] + section["size"] <= fileoff + filesize, "macho_section_file")
                    self.sections.append(section)
                    need(len(self.sections) <= 16384, "macho_section_count")
            elif command in (0x21, 0x2C):
                need(length >= (24 if command == 0x2C else 20), "macho_encryption_header")
                cryptids.append(struct.unpack_from("<I", data, cursor + 16)[0])
            elif command == 0x2:
                need(length == 24 and self.symtab is None, "macho_symtab_header")
                self.symtab = struct.unpack_from("<4I", data, cursor + 8)
            cursor += length
        need(cursor == end and cryptids == [0], "macho_cryptid_zero")
        text = [segment for segment in self.segments if segment["name"] == "__TEXT" and segment["offset"] == 0]
        need(len(text) == 1, "macho_text_segment")
        self.base = text[0]["vm"]
        for section in self.sections:
            if section["name"] in ("__swift5_fieldmd", "__swift5_reflstr", "__cstring", "__objc_methname", "__swift5_typeref"):
                need(section["backed"] and section["size"] <= MAX_SECTION, "macho_metadata_section_bounds")

    @staticmethod
    def fixed_name(value):
        try:
            name = value.split(b"\0", 1)[0].decode("ascii")
        except UnicodeDecodeError:
            raise InspectionError("macho_section_name") from None
        need(bool(re.fullmatch(r"[A-Za-z0-9_.$]+", name)), "macho_section_name")
        return name

    def mapped(self, vm, length=1):
        for section in self.sections:
            if section["backed"] and section["vm"] <= vm and vm + length <= section["vm"] + section["size"]:
                return section["offset"] + vm - section["vm"], section
        return None

    def location(self, fileoff, vm=None):
        result = {"file_offset": hex(fileoff)}
        if vm is not None:
            result["image_offset"] = hex(vm - self.base)
        return result

    def rel_target(self, vm):
        mapped = self.mapped(vm, 4)
        if not mapped:
            self.unresolved += 1
            return None
        displacement = struct.unpack_from("<i", self.data, mapped[0])[0]
        return vm + displacement if displacement else None

    def plain_string(self, vm, limit=512):
        mapped = self.mapped(vm)
        if not mapped:
            self.unresolved += 1
            return None
        offset, section = mapped
        end = min(section["offset"] + section["size"], offset + limit)
        stop = self.data.find(b"\0", offset, end)
        if stop < 0:
            self.unresolved += 1
            return None
        try:
            return self.data[offset:stop].decode("utf-8")
        except UnicodeDecodeError:
            self.unresolved += 1
            return None

    def context_name(self, vm, seen=()):
        if vm in seen or len(seen) >= 8:
            self.unresolved += 1
            return None
        mapped = self.mapped(vm, 12)
        if not mapped or mapped[1]["name"] not in ("__const", "__data"):
            self.unresolved += 1
            return None
        flags, parent = struct.unpack_from("<Ii", self.data, mapped[0])
        kind = flags & 0x1F
        if kind not in (0, 16, 17, 18):
            return None
        target = self.rel_target(vm + 8)  # Name is direct; never clear its low bit.
        name = safe_name(self.plain_string(target)) if target is not None else None
        if not name:
            return None
        if parent and not (parent & 1):  # Parent alone is relative-indirectable.
            qualifier = self.context_name(vm + 4 + parent, seen + (vm,))
            if qualifier and len(qualifier + "." + name) <= 240:
                name = qualifier + "." + name
        return name

    def type_hints(self, vm):
        """Bounded symbolic-name scanner, not a general Swift demangler."""
        if vm is None:
            return []
        mapped = self.mapped(vm)
        if not mapped or mapped[1]["name"] not in ("__swift5_typeref", "__swift5_reflstr", "__const"):
            self.unresolved += 1
            return []
        offset, section = mapped
        end = min(section["offset"] + section["size"], offset + 512)
        cursor, fragment, hints = offset, bytearray(), []
        terminated = False
        while cursor < end:
            byte = self.data[cursor]
            if byte == 0:
                terminated = True
                break
            if 1 <= byte <= 0x1F:
                if fragment:
                    hint = safe_name(fragment.decode("ascii", "ignore"), fragment=True)
                    if hint:
                        hints.append(hint)
                    fragment.clear()
                payload = 4 if byte <= 0x17 else 8
                if cursor + 1 + payload > end:
                    self.unresolved += 1
                    return []
                if byte == 1:
                    displacement = struct.unpack_from("<i", self.data, cursor + 1)[0]
                    # Swift's base is the first payload byte, NOT the marker.
                    context = self.context_name(section["vm"] + cursor + 1 - section["offset"] + displacement)
                    if context:
                        hints.append(context)
                else:
                    self.unresolved += 1
                cursor += 1 + payload
            elif byte == 0xFF:  # Compiler alignment padding in mangled names.
                cursor += 1
            elif 0x20 <= byte <= 0x7E:
                fragment.append(byte)
                cursor += 1
            else:
                self.unresolved += 1
                return []
        if not terminated:
            self.unresolved += 1
            return []
        if fragment:
            hint = safe_name(fragment.decode("ascii"), fragment=True)
            if hint:
                hints.append(hint)
        return list(dict.fromkeys(hints))[:4]

    def field_models(self):
        candidates, descriptors, fields = [], 0, 0
        for section in self.sections:
            if section["name"] != "__swift5_fieldmd":
                continue
            cursor, end = section["offset"], section["offset"] + section["size"]
            while cursor < end:
                if end - cursor < 16:
                    need(not any(self.data[cursor:end]), "swift_field_header_truncated")
                    break
                type_rel, super_rel, kind, stride, count = struct.unpack_from("<iiHHI", self.data, cursor)
                if stride == 0 and count == 0 and type_rel == 0 and super_rel == 0 and kind == 0:
                    need(not any(self.data[cursor:end]), "swift_field_padding")
                    break
                need(kind <= 8 and stride == 12, "swift_field_record_layout")
                need(count <= 100000 and cursor + 16 + count * 12 <= end, "swift_field_record_bounds")
                descriptors += 1
                fields += count
                need(descriptors <= 250000 and fields <= 2000000, "swift_field_count")
                vm = section["vm"] + cursor - section["offset"]
                owners = self.type_hints(vm + type_rel if type_rel else None)
                owner = next((hint for hint in owners if "." in hint), owners[0] if owners else None)
                owner_matches = matches(" ".join(owners))
                related, field_matches = [], []
                for index in range(count):
                    record_offset = cursor + 16 + index * 12
                    flags, type_delta, name_delta = struct.unpack_from("<Iii", self.data, record_offset)
                    record_vm = section["vm"] + record_offset - section["offset"]
                    # Type/name rel32 each use their own field address; zero is nil.
                    name = safe_name(self.plain_string(record_vm + 8 + name_delta)) if name_delta else None
                    if not name:
                        continue
                    found = matches(name)
                    row = {"name": name, "matches": found, "flags": flags,
                           "field_record_file_offset": hex(record_offset),
                           "type_hints": self.type_hints(record_vm + 4 + type_delta if type_delta else None)}
                    related.append(row)
                    field_matches.extend(found)
                if owner_matches or field_matches:
                    related.sort(key=lambda row: (not bool(row["matches"]), row["name"]))
                    candidates.append({**self.location(cursor, vm), "owner_name": owner,
                                       "owner_type_hints": owners, "kind": kind,
                                       "declared_field_count": count,
                                       "matches": sorted(set(owner_matches + field_matches)),
                                       "related_fields": related[:MAX_FIELDS],
                                       "omitted_related_fields": max(0, len(related) - MAX_FIELDS)})
                cursor += 16 + count * 12
        candidates.sort(key=rank)
        return candidates[:MAX_MODELS], {"descriptors": descriptors, "fields": fields,
                                        "omitted_matching_models": max(0, len(candidates) - MAX_MODELS)}

    def strings(self):
        rows, total = [], 0
        for section in self.sections:
            if section["name"] not in ("__swift5_reflstr", "__cstring", "__objc_methname"):
                continue
            cursor, end = section["offset"], section["offset"] + section["size"]
            while cursor < end:
                stop = self.data.find(b"\0", cursor, end)
                if stop < 0:
                    break
                if 1 <= stop - cursor <= 240:
                    try:
                        name = safe_name(self.data[cursor:stop].decode("utf-8"))
                    except UnicodeDecodeError:
                        name = None
                    found = matches(name)
                    if name and found:
                        total += 1
                        if len(rows) < 4096:
                            rows.append({**self.location(cursor, section["vm"] + cursor - section["offset"]),
                                         "section": section["name"], "name": name, "matches": found})
                cursor = stop + 1
        rows.sort(key=rank)
        return rows[:MAX_STRINGS], max(0, total - MAX_STRINGS)

    def symbols(self):
        if self.symtab is None:
            return [], 0
        symoff, count, stroff, strsize = self.symtab
        need(count <= 2000000 and symoff + count * 16 <= len(self.data)
             and stroff + strsize <= len(self.data), "macho_symtab_bounds")
        rows, total = [], 0
        for index in range(count):
            strx, kind, sect, _, value = struct.unpack_from("<IBBHQ", self.data, symoff + index * 16)
            if kind & 0xE0 or (kind & 0x0E) != 0x0E:
                continue
            need(0 < sect <= len(self.sections) and strx < strsize, "macho_symbol_reference")
            offset = stroff + strx
            stop = self.data.find(b"\0", offset, min(stroff + strsize, offset + 241))
            if stop < 0:
                continue
            try:
                name = safe_name(self.data[offset:stop].decode("utf-8"))
            except UnicodeDecodeError:
                name = None
            found = matches(name)
            if not name or not found:
                continue
            section = self.sections[sect - 1]
            need(section["vm"] <= value <= section["vm"] + section["size"], "macho_symbol_value")
            total += 1
            if len(rows) < 4096:
                mapped = self.mapped(value)
                rows.append({"name": name, "matches": found, "image_offset": hex(value - self.base),
                             "file_offset": hex(mapped[0]) if mapped else None,
                             "nlist_file_offset": hex(symoff + index * 16)})
        rows.sort(key=rank)
        return rows[:MAX_SYMBOLS], max(0, total - MAX_SYMBOLS)


def inspect_macho(data):
    image = MachO(data)
    models, counts = image.field_models()
    strings, omitted_strings = image.strings()
    symbols, omitted_symbols = image.symbols()
    return {"format": "ARM64 MH_EXECUTE; one cryptid-zero command",
            "models": models, "string_candidates": strings, "symbol_candidates": symbols,
            "counts": {**counts, "omitted_matching_strings": omitted_strings,
                       "omitted_matching_symbols": omitted_symbols,
                       "unresolved_or_filtered_type_references": image.unresolved}}


def inspect_ipa(path):
    path = Path(path)
    need(path.is_file() and not path.is_symlink(), "ipa_regular_file")
    need(path.stat().st_size == ORIGINAL_IPA_BYTES, "ipa_size_mismatch")
    need(digest_file(path) == ORIGINAL_IPA_SHA256, "ipa_sha256_mismatch")
    with zipfile.ZipFile(path) as archive:
        names = safe_zip(archive)
        root_info = "Payload/BeReal.app/Info.plist"
        need(root_info in names and sorted(name for name in names
             if name.startswith("Payload/") and name.count("/") == 2 and name.endswith(".app/Info.plist")) == [root_info],
             "ipa_root_application")
        import plistlib
        info = plistlib.loads(bounded_member(archive, root_info, 4 * 1024 * 1024))
        need((info.get("CFBundleIdentifier"), info.get("CFBundleShortVersionString"),
              info.get("CFBundleVersion"), info.get("CFBundleExecutable")) ==
             ("AlexisBarreyat.BeReal", "4.93.0", "23026", "BeReal"), "ipa_main_identity")
        main = bounded_member(archive, "Payload/BeReal.app/BeReal", MAX_MAIN)
    need(hashlib.sha256(main).hexdigest() == ORIGINAL_MAIN_SHA256, "main_sha256_mismatch")
    return {"schema_version": 1, "purpose": "read_only_bonus_eligibility_metadata_candidates",
            "input_sha256": ORIGINAL_IPA_SHA256, "input_bytes": ORIGINAL_IPA_BYTES,
            "main_sha256": ORIGINAL_MAIN_SHA256,
            "abi_source_commit": "e0a274b4df3d3f223f3116a563bd48152b484fbf",
            "abi_source_files": [url[len(SWIFT_SOURCE):] for url in ABI_SOURCES],
            "scope": [
                "Only declaration names, sanitized mangled-name/context hints and static metadata locations.",
                "Candidates are not proof of bonus eligibility, on-time status, server policy or a repair.",
                "Field-record offsets are metadata locations, NOT instance field offsets or verified callable ABI.",
                "No general Swift demangler; indirect/accessor symbolic references remain unresolved.",
                "Names suggesting credentials, URLs, non-identifiers and excessive output are suppressed.",
                "No raw IPA/main bytes, credential values, user data or network requests are emitted.",
            ], "metadata": inspect_macho(main)}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ipa", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    try:
        need(args.output is None or args.output.resolve() != args.ipa.resolve(), "output_overwrites_input")
        report = inspect_ipa(args.ipa)
        encoded = (json.dumps(report, indent=2, ensure_ascii=True) + "\n").encode()
        need(len(encoded) <= MAX_JSON, "report_size_limit")
        if args.output:
            need(not args.output.is_symlink(), "output_symlink")
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_bytes(encoded)
            print(json.dumps({"status": "metadata_candidates_only", "model_count": len(report["metadata"]["models"]),
                              "string_count": len(report["metadata"]["string_candidates"]),
                              "symbol_count": len(report["metadata"]["symbol_candidates"])}))
        else:
            sys.stdout.write(encoded.decode())
        return 0
    except (InspectionError, OSError, ValueError, struct.error, KeyError, zipfile.BadZipFile, RuntimeError, EOFError, zlib.error) as error:
        code = str(error) if isinstance(error, InspectionError) else "malformed_or_unreadable_input"
        print(json.dumps({"status": "rejected", "reason": code}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
