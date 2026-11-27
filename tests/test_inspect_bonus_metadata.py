"""Synthetic bounds/relative-pointer/symbolic-name/ZIP tests; stdlib only."""
import contextlib
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
from unittest.mock import patch
import zipfile

SPEC = importlib.util.spec_from_file_location(
    "inspect_bonus_metadata", Path(__file__).resolve().parents[1] / "scripts/inspect_bonus_metadata.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
BASE = 0x100000000


def fixture(strings=None):
    data = bytearray(0x8000)
    strings = strings or b"bonusEligible\0https://invalid.example/bonus?token=private\0bonusTokenValue\0"
    methods = b"canPostBonus:\0remainingPosts\0"
    sections = [
        ("__swift5_fieldmd", 0x1000, 40), ("__swift5_reflstr", 0x2000, 1024),
        ("__cstring", 0x3000, len(strings)), ("__objc_methname", 0x4000, len(methods)),
        ("__swift5_typeref", 0x5000, 48), ("__const", 0x6000, 64),
    ]
    command_size = 72 + len(sections) * 80
    segment = struct.pack("<II16s4Q4I", 0x19, command_size, b"__TEXT",
                          BASE, len(data), 0, len(data), 7, 5, len(sections), 0)
    for name, offset, length in sections:
        segment += struct.pack("<16s16sQQ8I", name.encode(), b"__TEXT",
                               BASE + offset, length, offset, 2, 0, 0, 0, 0, 0, 0)
    names = b"\0_$s7Fixture16BonusEligibilityV8canPostSbv\0"
    encryption = struct.pack("<6I", 0x2C, 24, 0, 0, 0, 0)
    symtab = struct.pack("<6I", 2, 24, 0x7000, 1, 0x7100, len(names))
    commands = segment + encryption + symtab
    struct.pack_into("<8I", data, 0, 0xFEEDFACF, 0x0100000C, 0, 2, 3, len(commands), 0, 0)
    data[32:32 + len(commands)] = commands
    struct.pack_into("<iiHHI", data, 0x1000, 0x5000 - 0x1000, 0, 0, 12, 2)
    for offset, name_offset in ((0x1010, 0x2050), (0x101C, 0x2060)):
        struct.pack_into("<Iii", data, offset, 2, 0x5010 - (offset + 4), name_offset - (offset + 8))
    for offset, value in ((0x2000, b"BonusEligibility\0"), (0x2020, b"Fixture\0"),
                          (0x2050, b"canPostBonus\0"), (0x2060, b"momentID\0")):
        data[offset:offset + len(value)] = value
    data[0x3000:0x3000 + len(strings)] = strings
    data[0x4000:0x4000 + len(methods)] = methods
    # Internal NUL bytes in the signed rel32 payload must not terminate this name.
    data[0x5000:0x5006] = b"\x01" + struct.pack("<i", 0x6000 - 0x5001) + b"\0"
    data[0x5010:0x5013] = b"Sb\0"
    struct.pack_into("<Iii", data, 0x6000, 17, 0x6020 - 0x6004, 0x2000 - 0x6008)
    struct.pack_into("<Iii", data, 0x6020, 0, 0, 0x2020 - 0x6028)
    struct.pack_into("<IBBHQ", data, 0x7000, 1, 0x0F, 1, 0, BASE + 0x1000)
    data[0x7100:0x7100 + len(names)] = names
    return bytes(data)


def ipa_bytes(main, extra=None, identity=None):
    stream = io.BytesIO()
    info = {"CFBundleIdentifier": "AlexisBarreyat.BeReal", "CFBundleShortVersionString": "4.93.0",
            "CFBundleVersion": "23026", "CFBundleExecutable": "BeReal"}
    if identity:
        info.update(identity)
    with zipfile.ZipFile(stream, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("Payload/BeReal.app/Info.plist", plistlib.dumps(info))
        archive.writestr("Payload/BeReal.app/BeReal", main)
        if extra:
            archive.writestr(extra, b"synthetic")
    return stream.getvalue()


class BonusMetadataTests(unittest.TestCase):
    def test_resolves_signed_relative_fields_and_symbolic_context_payload_base(self):
        result = MODULE.inspect_macho(fixture())
        model = result["models"][0]
        self.assertEqual(model["owner_name"], "Fixture.BonusEligibility")
        self.assertEqual(model["file_offset"], "0x1000")
        self.assertEqual(model["image_offset"], "0x1000")
        self.assertEqual({field["name"] for field in model["related_fields"]}, {"canPostBonus", "momentID"})
        self.assertEqual(model["related_fields"][0]["type_hints"], ["Sb"])
        self.assertEqual(result["symbol_candidates"][0]["file_offset"], "0x1000")

    def test_does_not_emit_urls_credential_like_names_or_original_bytes(self):
        encoded = json.dumps(MODULE.inspect_macho(fixture()))
        self.assertIn("bonusEligible", encoded)
        for forbidden in ("https://", "invalid.example", "private", "bonusTokenValue", "0fff"):
            self.assertNotIn(forbidden, encoded)

    def test_null_and_out_of_range_field_references_are_not_dereferenced(self):
        data = bytearray(fixture())
        struct.pack_into("<ii", data, 0x1014, 0, 0)
        result = MODULE.inspect_macho(bytes(data))
        self.assertEqual([field["name"] for field in result["models"][0]["related_fields"]], ["momentID"])
        struct.pack_into("<i", data, 0x1024, 0x7FFFFFFF)
        result = MODULE.inspect_macho(bytes(data))
        self.assertEqual(result["models"][0]["related_fields"], [])

    def test_indirect_and_truncated_symbolic_references_remain_unresolved(self):
        data = bytearray(fixture())
        data[0x5000] = 2
        result = MODULE.inspect_macho(bytes(data))
        self.assertIsNone(result["models"][0]["owner_name"])
        self.assertGreater(result["counts"]["unresolved_or_filtered_type_references"], 0)
        image = MODULE.MachO(fixture())
        self.assertEqual(image.type_hints(BASE + 0x5000 + 47), [])
        data[0x502F] = 1
        self.assertEqual(MODULE.MachO(bytes(data)).type_hints(BASE + 0x502F), [])

    def test_rejects_truncated_headers_bad_record_stride_and_field_count(self):
        for kind in ("commands", "stride", "fields"):
            data = bytearray(fixture())
            if kind == "commands":
                struct.pack_into("<I", data, 20, 0xFFFFFFFF)
            elif kind == "stride":
                struct.pack_into("<H", data, 0x100A, 16)
            else:
                struct.pack_into("<I", data, 0x100C, 100001)
            with self.subTest(kind=kind), self.assertRaises(MODULE.InspectionError):
                MODULE.inspect_macho(bytes(data))

    def test_rejects_encrypted_or_wrong_architecture_and_bad_symtab(self):
        for kind in ("cryptid", "cpu", "symbol"):
            data = bytearray(fixture())
            if kind == "cpu":
                struct.pack_into("<I", data, 4, 7)
            elif kind == "cryptid":
                struct.pack_into("<I", data, 32 + (72 + 6 * 80) + 16, 1)
            else:
                struct.pack_into("<I", data, 32 + (72 + 6 * 80) + 24 + 8, 0x7FFFFFF0)
            with self.subTest(kind=kind), self.assertRaises(MODULE.InspectionError):
                MODULE.inspect_macho(bytes(data))

    def test_output_candidate_count_is_bounded(self):
        data = fixture(b"".join(("bonusField%d" % n).encode() + b"\0" for n in range(180)))
        result = MODULE.inspect_macho(data)
        self.assertEqual(len(result["string_candidates"]), MODULE.MAX_STRINGS)
        self.assertGreater(result["counts"]["omitted_matching_strings"], 0)

    def test_exact_input_pin_identity_safe_zip_and_cli_guard(self):
        main = fixture()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.ipa"
            for extra, identity, expected in (
                (None, None, None),
                ("../bonus", None, "zip_path"),
                (None, {"CFBundleVersion": "wrong"}, "ipa_main_identity"),
            ):
                data = ipa_bytes(main, extra, identity)
                path.write_bytes(data)
                with patch.multiple(MODULE, ORIGINAL_IPA_BYTES=len(data),
                                    ORIGINAL_IPA_SHA256=hashlib.sha256(data).hexdigest(),
                                    ORIGINAL_MAIN_SHA256=hashlib.sha256(main).hexdigest()):
                    if expected:
                        with self.assertRaisesRegex(MODULE.InspectionError, expected):
                            MODULE.inspect_ipa(path)
                    else:
                        report = MODULE.inspect_ipa(path)
                        self.assertEqual(len(report["metadata"]["models"]), 1)
                        with contextlib.redirect_stderr(io.StringIO()):
                            self.assertEqual(MODULE.main([str(path), "--output", str(path)]), 1)
                        self.assertEqual(path.read_bytes(), data)
                with self.assertRaisesRegex(MODULE.InspectionError, "ipa_size_mismatch"):
                    MODULE.inspect_ipa(path)

    def test_sha256_and_main_pin_cannot_be_bypassed_by_valid_zip(self):
        main = fixture()
        data = ipa_bytes(main)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.ipa"
            path.write_bytes(data)
            with patch.multiple(MODULE, ORIGINAL_IPA_BYTES=len(data),
                                ORIGINAL_IPA_SHA256="0" * 64):
                with self.assertRaisesRegex(MODULE.InspectionError, "ipa_sha256_mismatch"):
                    MODULE.inspect_ipa(path)
            with patch.multiple(MODULE, ORIGINAL_IPA_BYTES=len(data),
                                ORIGINAL_IPA_SHA256=hashlib.sha256(data).hexdigest(),
                                ORIGINAL_MAIN_SHA256="0" * 64):
                with self.assertRaisesRegex(MODULE.InspectionError, "main_sha256_mismatch"):
                    MODULE.inspect_ipa(path)


if __name__ == "__main__":
    unittest.main()
