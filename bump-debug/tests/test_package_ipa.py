import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import stat
import struct
import subprocess
import sys
import tempfile
import unittest
import warnings
import zipfile


MODULE_PATH = Path(__file__).resolve().parents[1] / "scripts" / "package_ipa.py"
spec = importlib.util.spec_from_file_location("bump_package_ipa", MODULE_PATH)
pack = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = pack
spec.loader.exec_module(pack)


def dylib_command(name):
    value = name.encode() + b"\0"
    size = (24 + len(value) + 7) & ~7
    return struct.pack("<6I", 0xC, size, 24, 0, 0, 0) + value + b"\0" * (size - 24 - len(value))


def macho(*, library=False, cryptid=0, extra=(), data_offset=512, signature=True):
    segment = struct.pack("<II16s4Q4I", 0x19, 152, b"__TEXT", 0, 1024, 0, 1024, 7, 5, 1, 0)
    section = struct.pack("<16s16s2Q8I", b"__text", b"__TEXT", 0, 64, data_offset, 2, 0, 0, 0, 0, 0, 0)
    commands = [segment + section, struct.pack("<6I", 0x2C, 24, data_offset, 64, cryptid, 0)]
    if signature:
        commands.append(struct.pack("<4I", 0x1D, 16, 768, 64))
    commands.extend(extra)
    table = b"".join(commands)
    result = bytearray(1024)
    result[:32] = struct.pack("<8I", 0xFEEDFACF, 0x100000C, 0, 6 if library else 2, len(commands), len(table), 0, 0)
    result[32 : 32 + len(table)] = table
    result[data_offset : data_offset + 64] = bytes(range(64))
    result[768:832] = b"S" * 64
    return bytes(result)


class MachOTests(unittest.TestCase):
    def test_injection_strips_signature_preserves_offsets_and_payload(self):
        source = macho()
        result, receipt = pack._patch_macho(source, inject=True)
        commands, end = pack._macho_commands(result, 2)
        self.assertEqual(len(result), len(source))
        self.assertNotIn(pack.LC_CODE_SIGNATURE, [kind for kind, _ in commands])
        self.assertEqual([pack._dylib_name(c) for kind, c in commands if kind == 0xC], [pack.LOAD_PATH])
        self.assertEqual(result[end:], source[end:])
        self.assertEqual(result[512:], source[512:])
        self.assertEqual(receipt["signature_commands_removed"], 1)
        self.assertTrue(receipt["payload_offsets_preserved"])

    def test_library_strips_command_without_truncating_payload(self):
        source = macho(library=True)
        result, receipt = pack._patch_macho(source, inject=False)
        commands, end = pack._macho_commands(result, 6)
        old_end = 32 + struct.unpack_from("<I", source, 20)[0]
        self.assertEqual([kind for kind, _ in commands], [0x19, 0x2C])
        self.assertEqual(result[old_end:], source[old_end:])
        self.assertEqual(result[end:old_end], b"\0" * (old_end - end))
        self.assertEqual(receipt["signature_commands_removed"], 1)

    def test_encrypted_main_and_library_rejected(self):
        for library in (False, True):
            with self.subTest(library=library), self.assertRaisesRegex(pack.PackagingError, "Encrypted"):
                pack._patch_macho(macho(library=library, cryptid=1), inject=not library)

    def test_already_injected_main_rejected(self):
        for name in (pack.LOAD_PATH, "@rpath/" + pack.LIBRARY_NAME):
            with self.subTest(name=name), self.assertRaisesRegex(pack.PackagingError, "already loads"):
                pack._patch_macho(macho(extra=(dylib_command(name),)), inject=True)

    def test_nonblank_header_padding_rejected(self):
        data = bytearray(macho())
        end = 32 + struct.unpack_from("<I", data, 20)[0]
        data[end + 4] = 1
        with self.assertRaisesRegex(pack.PackagingError, "not blank"):
            pack._patch_macho(bytes(data), inject=True)

    def test_zero_valued_payload_is_not_treated_as_header_padding(self):
        data = bytearray(macho(data_offset=240))
        data[240:304] = b"\0" * 64
        with self.assertRaisesRegex(pack.PackagingError, "before Mach-O data"):
            pack._patch_macho(bytes(data), inject=True)

    def test_malformed_load_commands_rejected(self):
        base = macho()
        mutations = []
        data = bytearray(base); struct.pack_into("<I", data, 16, 500); mutations.append(bytes(data))
        data = bytearray(base); struct.pack_into("<I", data, 36, 7); mutations.append(bytes(data))
        data = bytearray(base); struct.pack_into("<I", data, 20, 9000); mutations.append(bytes(data))
        data = bytearray(base); struct.pack_into("<I", data, 4, 7); mutations.append(bytes(data))
        mutations.extend([b"", base[:31], b"\xca\xfe\xba\xbe" + base[4:]])
        for index, data in enumerate(mutations):
            with self.subTest(index=index), self.assertRaises(pack.PackagingError):
                pack._patch_macho(data, inject=True)


class ArchiveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source.ipa"
        self.library = self.root / "debug.dylib"
        self.output = self.root / "output.ipa"
        self.library.write_bytes(macho(library=True))
        self.info = {"CFBundleExecutable": "Location", "CFBundleIdentifier": "co.amo.ios.location", "CFBundleShortVersionString": "2.135.0", "CFBundleVersion": "261126153935"}

    def create_archive(self, extra=(), info=None):
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(self.source, "w") as archive:
                archive.comment = b"original-comment"
                archive.writestr(pack.APP_PATH + "/Info.plist", plistlib.dumps(self.info if info is None else info))
                executable = zipfile.ZipInfo(pack.APP_PATH + "/Location")
                executable.create_system = 3
                executable.external_attr = (stat.S_IFREG | 0o755) << 16
                executable.compress_type = zipfile.ZIP_DEFLATED
                archive.writestr(executable, macho())
                archive.writestr(pack.APP_PATH + "/asset.dat", b"unchanged arbitrary payload\x00\xff")
                archive.writestr(pack.APP_PATH + "/_CodeSignature/CodeResources", b"old main signature")
                archive.writestr(pack.APP_PATH + "/embedded.mobileprovision", b"old profile")
                archive.writestr(pack.APP_PATH + "/PlugIns/Test.appex/_CodeSignature/CodeResources", b"old extension signature")
                archive.writestr(pack.APP_PATH + "/PlugIns/Test.appex/embedded.mobileprovision", b"old extension profile")
                for name, content in extra:
                    archive.writestr(name, content)
        return pack._InputContract(pack.sha256_file(self.source))

    def test_packaging_receipt_modes_content_and_stale_metadata(self):
        contract = self.create_archive()
        source_hash = pack.sha256_file(self.source)
        library_hash = pack.sha256_file(self.library)
        receipt = pack._package_ipa(self.source, self.library, self.output, contract=contract)
        self.assertEqual(receipt["sha256"], pack.sha256_file(self.output))
        self.assertEqual(receipt["input_sha256"], source_hash)
        self.assertEqual(receipt["dylib_input_sha256"], library_hash)
        self.assertEqual(receipt["removed_signing_metadata_count"], 4)
        self.assertIn("unsigned", receipt["signature"])
        self.assertEqual(receipt["scratch_function"], "not tested")
        self.assertEqual(pack.sha256_file(self.source), source_hash)
        self.assertEqual(pack.sha256_file(self.library), library_hash)
        with zipfile.ZipFile(self.source) as source, zipfile.ZipFile(self.output) as output:
            self.assertIsNone(output.testzip())
            self.assertEqual(output.comment, source.comment)
            self.assertFalse(any(pack._is_signature_metadata(n) for n in output.namelist()))
            for entry in source.infolist():
                if pack._is_signature_metadata(entry.filename):
                    continue
                if entry.filename != pack.APP_PATH + "/Location":
                    self.assertEqual(output.read(entry.filename), source.read(entry.filename))
                self.assertEqual(output.getinfo(entry.filename).external_attr, entry.external_attr)
            self.assertEqual((output.getinfo(pack.LIBRARY_PATH).external_attr >> 16) & 0o777, 0o755)
            self.assertEqual(hashlib.sha256(output.read(pack.LIBRARY_PATH)).hexdigest(), receipt["dylib_packaged_sha256"])

    def test_public_api_and_cli_cannot_override_pinned_input_hash(self):
        self.create_archive()
        with self.assertRaisesRegex(pack.PackagingError, "pinned Bump input"):
            pack.package_ipa(self.source, self.library, self.output)
        result = subprocess.run([sys.executable, str(MODULE_PATH), str(self.source), str(self.library), str(self.output)], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("pinned Bump input", result.stderr)
        self.assertFalse(self.output.exists())
        result = subprocess.run([sys.executable, str(MODULE_PATH), "--sha256", "0" * 64], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)

    def test_wrong_bundle_version_and_build_rejected_even_with_matching_hash(self):
        for key in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion"):
            info = dict(self.info); info[key] = "incorrect"
            contract = self.create_archive(info=info)
            with self.subTest(key=key), self.assertRaisesRegex(pack.PackagingError, "identity, version or build"):
                pack._package_ipa(self.source, self.library, self.output, contract=contract)
        self.assertFalse(self.output.exists())

    def test_duplicate_traversal_absolute_and_conflicting_paths_rejected(self):
        for path in (pack.APP_PATH + "/asset.dat", "../outside", "/absolute", "Payload/../outside", "Payload/./outside", "Payload//outside", "C:/outside", "Payload\\outside", "Payload"):
            contract = self.create_archive(extra=[(path, b"bad")])
            with self.subTest(path=path), self.assertRaises(pack.PackagingError):
                pack._package_ipa(self.source, self.library, self.output, contract=contract)
        self.assertFalse(self.output.exists())

    def test_symlink_rejected(self):
        link = zipfile.ZipInfo(pack.APP_PATH + "/link")
        link.create_system = 3
        link.external_attr = (stat.S_IFLNK | 0o777) << 16
        contract = self.create_archive(extra=[(link, b"../../outside")])
        with self.assertRaisesRegex(pack.PackagingError, "file type"):
            pack._package_ipa(self.source, self.library, self.output, contract=contract)

    def test_already_packaged_archive_rejected(self):
        contract = self.create_archive(extra=[(pack.LIBRARY_PATH, b"present")])
        with self.assertRaisesRegex(pack.PackagingError, "already contains"):
            pack._package_ipa(self.source, self.library, self.output, contract=contract)

    def test_output_cannot_overwrite_source_or_dylib(self):
        contract = self.create_archive()
        for output in (self.source, self.library):
            with self.subTest(output=output.name), self.assertRaisesRegex(pack.PackagingError, "Output must differ"):
                pack._package_ipa(self.source, self.library, output, contract=contract)


if __name__ == "__main__":
    unittest.main()
