#!/usr/bin/env python3
"""Bump-only Ad Hoc signing in the existing Y3 CI; never export private assets."""

from __future__ import annotations

import argparse
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import struct
import sys
import tempfile
import urllib.parse
import zipfile


INPUT_SHA256 = "0b18338b5db68e39ba1de6f5e45c8c79d2211d25da58dc9d4ffa6783bb41773e"
ROOT_ID = "com.ayato.bumpdebug"
ORIGINAL_ID = "co.amo.ios.location"
SUFFIXES = ("", ".lpse", ".friend-widget", ".nce", ".friend-intent",
            ".on-my-way-live-activity", ".nse", ".imessage-stickers-extension", ".share")
AAD = b"BumpLocationDebugInputV1"
SIGNER_SHA256 = "8dee65652b3b456d2e5569bd1f3f66569e8ba436234351bcbfedb7f93d65cf81"
PROFILE_HELPER_SHA256 = "628459c1f26615a8defa2d671e38630cdfeec409ddf6cac13f417e5e652a1697"
MACHO_MAGICS = frozenset((b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xce", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"))
STAGE = "startup"


class BumpError(RuntimeError):
    """A fixed diagnostic suitable for public CI logs."""


def safe_failure(error):
    if isinstance(error, BumpError):
        return str(error)
    message = str(error)
    if isinstance(error, RuntimeError):
        match = re.search(r"codesign stage=([a-z_]+) reason=([a-z_]+)", message)
        if match:
            return match.group(0)
        match = re.search(r"Apple API GET /v1/(certificates|profiles|devices)(?:/[^ ]+)? failed \(HTTP ([0-9]{3})\)", message)
        if match:
            return "apple_api_get_" + match.group(1) + "_http" + match.group(2)
        known = {
            "Required existing signing assets are missing": "required_existing_assets_missing",
            "Existing Apple distribution certificate is not valid": "existing_distribution_certificate_invalid",
            "Expected exactly the one registered enabled iOS device": "registered_device_count_changed",
            "No existing wildcard Ad Hoc profile proves": "no_compatible_existing_wildcard_profile",
            "Certificate/private-key mismatch": "certificate_private_key_mismatch",
        }
        for needle, code in known.items():
            if needle in message:
                return code
    return type(error).__name__


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def load_signer(directory=None):
    directory = Path(directory) if directory is not None else Path(__file__).resolve().parent
    source = directory / "bereal-resign.py"
    if digest(source) != SIGNER_SHA256 or digest(directory / "prepare-ci-profile.py") != PROFILE_HELPER_SHA256:
        raise BumpError("reviewed_signing_helper_hash_mismatch")
    spec = importlib.util.spec_from_file_location("bump_reviewed_signer", source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.ROOT_ID, module.PREFIX, module.SAFE_SUFFIXES = ROOT_ID, ORIGINAL_ID, SUFFIXES
    module.ORIGINAL_SHA = INPUT_SHA256
    return module


def decode_b64(value, minimum, maximum):
    if not isinstance(value, str) or len(value) > maximum * 2:
        raise BumpError("invalid_encrypted_input")
    try:
        result = base64.b64decode(value, validate=True)
    except (ValueError, TypeError):
        raise BumpError("invalid_encrypted_input") from None
    if not minimum <= len(result) <= maximum:
        raise BumpError("invalid_encrypted_input")
    return result


def validate_input(payload):
    if not isinstance(payload, dict) or set(payload) != {"url", "allowed_hosts", "input_sha256"}:
        raise BumpError("invalid_input_payload")
    if payload["input_sha256"] != INPUT_SHA256:
        raise BumpError("input_hash_contract_mismatch")
    hosts = payload["allowed_hosts"]
    if not isinstance(hosts, list) or len(hosts) != 1 or not isinstance(hosts[0], str) or not re.fullmatch(r"[a-z0-9-]+(?:\.[a-z0-9-]+)*\.icloud-content\.com", hosts[0]):
        raise BumpError("invalid_input_host_scope")
    url = payload["url"]
    if not isinstance(url, str) or not 1 <= len(url) <= 16384 or any(ord(c) < 33 for c in url):
        raise BumpError("invalid_input_url")
    try:
        parsed = urllib.parse.urlsplit(url)
        valid = (parsed.scheme == "https" and parsed.hostname == hosts[0] and
                 parsed.port in (None, 443) and parsed.username is None and parsed.password is None and not parsed.fragment)
    except ValueError:
        valid = False
    if not valid:
        raise BumpError("invalid_input_url")
    return payload


def decrypt_envelope(envelope, private_key_pem):
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import padding, rsa
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    if (not isinstance(envelope, dict) or set(envelope) != {"version", "input_sha256", "wrapped_key", "nonce", "ciphertext"}
            or type(envelope["version"]) is not int or envelope["version"] != 1 or envelope["input_sha256"] != INPUT_SHA256):
        raise BumpError("invalid_encrypted_input")
    wrapped = decode_b64(envelope["wrapped_key"], 256, 1024)
    nonce = decode_b64(envelope["nonce"], 12, 12)
    ciphertext = decode_b64(envelope["ciphertext"], 16, 32768)
    try:
        private_key = serialization.load_pem_private_key(private_key_pem, password=None)
        if not isinstance(private_key, rsa.RSAPrivateKey) or private_key.key_size < 2048:
            raise ValueError("key_type")
        key = private_key.decrypt(wrapped, padding.OAEP(mgf=padding.MGF1(hashes.SHA256()), algorithm=hashes.SHA256(), label=None))
        if len(key) != 32:
            raise ValueError("key_length")
        payload = json.loads(AESGCM(key).decrypt(nonce, ciphertext, AAD))
    except Exception:
        raise BumpError("encrypted_input_authentication_failed") from None
    return validate_input(payload)


def validate_bundles(app):
    app = Path(app)
    bundles = [app] + sorted((app / "PlugIns").glob("*.appex"))
    expected = {ORIGINAL_ID + suffix for suffix in SUFFIXES}
    targets = []
    for bundle in bundles:
        info = plistlib.loads((bundle / "Info.plist").read_bytes())
        old = info.get("CFBundleIdentifier")
        if old not in expected:
            raise BumpError("unexpected_or_duplicate_bundle")
        if bundle == app and (old != ORIGINAL_ID or info.get("CFBundleShortVersionString") != "2.135.0" or info.get("CFBundleVersion") != "261126153935"):
            raise BumpError("unexpected_root_identity_or_version")
        expected.remove(old)
        executable = info.get("CFBundleExecutable")
        if not isinstance(executable, str) or not executable or Path(executable).name != executable or not (bundle / executable).is_file() or (bundle / executable).is_symlink():
            raise BumpError("invalid_bundle_executable")
        targets.append((bundle, info, ROOT_ID + old[len(ORIGINAL_ID):]))
    if expected:
        raise BumpError("missing_expected_bundle")
    return targets


def signature_entitlement_keys(data):
    """Read only entitlement key names; values never enter public diagnostics."""
    if len(data) < 32 or data[:4] != b"\xcf\xfa\xed\xfe":
        raise BumpError("unsupported_original_executable")
    count, size = struct.unpack_from("<II", data, 16)
    end = 32 + size
    if end > len(data):
        raise BumpError("invalid_original_load_commands")
    offset = 32
    signature = None
    for _ in range(count):
        if offset + 8 > end:
            raise BumpError("invalid_original_load_commands")
        cmd, length = struct.unpack_from("<II", data, offset)
        if length < 8 or offset + length > end:
            raise BumpError("invalid_original_load_commands")
        if cmd == 0x1D:
            if length != 16 or signature is not None:
                raise BumpError("invalid_original_signature")
            start, length_sig = struct.unpack_from("<II", data, offset + 8)
            if start + length_sig > len(data):
                raise BumpError("invalid_original_signature")
            signature = data[start:start + length_sig]
        offset += length
    if offset != end or signature is None or len(signature) < 12:
        raise BumpError("missing_original_signature")
    magic, length, entries = struct.unpack_from(">III", signature)
    if magic != 0xFADE0CC0 or length > len(signature) or 12 + 8 * entries > length:
        raise BumpError("invalid_original_signature")
    for i in range(entries):
        slot, start = struct.unpack_from(">II", signature, 12 + i * 8)
        if slot != 5:
            continue
        if start + 8 > length:
            raise BumpError("invalid_original_entitlements")
        magic, size = struct.unpack_from(">II", signature, start)
        if magic != 0xFADE7171 or size < 8 or start + size > length:
            raise BumpError("invalid_original_entitlements")
        value = plistlib.loads(signature[start + 8:start + size])
        if not isinstance(value, dict):
            raise BumpError("invalid_original_entitlements")
        return set(value)
    return set()


def original_entitlement_keys(source):
    result = {}
    with zipfile.ZipFile(source) as archive:
        names = archive.namelist()
        info_names = [name for name in names if name == "Payload/Location.app/Info.plist" or
            (name.startswith("Payload/Location.app/PlugIns/") and name.count("/") == 4 and name.endswith("/Info.plist"))]
        for name in info_names:
            info = plistlib.loads(archive.read(name))
            executable = info.get("CFBundleExecutable", "")
            if not executable or Path(executable).name != executable:
                raise BumpError("invalid_original_executable")
            result[info["CFBundleIdentifier"]] = signature_entitlement_keys(archive.read(name[:-10] + executable))
    if set(result) != {ORIGINAL_ID + suffix for suffix in SUFFIXES}:
        raise BumpError("unexpected_original_bundle_set")
    return result


def remap_references(info, mappings):
    containing_keys = {"WKAppBundleIdentifier", "WKCompanionAppBundleIdentifier", "NSExtensionContainingAppBundleIdentifier"}
    if isinstance(info, dict):
        return {key: mappings.get(value, value) if key in containing_keys and isinstance(value, str)
                else remap_references(value, mappings) if isinstance(value, (dict, list)) else value
                for key, value in info.items()}
    if isinstance(info, list):
        return [remap_references(value, mappings) for value in info]
    return info


def bundle_entitlements(module, profile, identifier):
    """Concretize own and shared keychain scopes only under a proved grant."""
    entitlements = module.existing_wildcard_entitlements(profile, identifier)
    prefix = entitlements["application-identifier"].split(".", 1)[0]
    shared = prefix + "." + ROOT_ID
    grants = profile["Entitlements"].get("keychain-access-groups")
    if not isinstance(grants, list) or not any(isinstance(grant, str) and
            module.apple_identifier_grant_matches(grant, shared) for grant in grants):
        raise BumpError("profile_has_no_scoped_shared_keychain_grant")
    groups = entitlements.get("keychain-access-groups", [])
    if shared not in groups:
        groups.append(shared)
    entitlements["keychain-access-groups"] = groups
    candidate = plistlib.loads(plistlib.dumps(profile))
    candidate["Entitlements"] = entitlements
    if module.concrete_entitlements(candidate, identifier) != entitlements:
        raise BumpError("shared_keychain_concretization_failed")
    return entitlements, shared


class ReadOnlyAPI:
    """Enforce GET-only access even if a reused helper changes unexpectedly."""
    def __init__(self, api):
        self.api = api

    def collection(self, *args, **kwargs):
        return self.api.collection(*args, **kwargs)

    def request(self, method, *args, **kwargs):
        if method != "GET":
            raise BumpError("apple_write_forbidden")
        return self.api.request(method, *args, **kwargs)


def prepare_identity(module, root, need_private_key):
    p12, primary_der, key, asc = module.decode_identity(root, need_private_key=need_private_key)
    api = ReadOnlyAPI(module.RefreshingAppleAPI(asc))
    _, device = module.signing_readiness(api, primary_der)
    alternate = root / "alternate"
    alternate.mkdir(mode=0o700)
    p12, der, _, _ = module.decode_identity(alternate, need_private_key=False,
        certificate_env="DIST_P12_BASE64", password_env="DIST_P12_PASSWORD")
    _, alternate_device = module.signing_readiness(api, der)
    if alternate_device["attributes"]["udid"] != device["attributes"]["udid"]:
        raise BumpError("registered_device_changed")
    raw, profile = module.select_existing_wildcard_profile(api, der, os.environ["APPLE_TEAM_ID"], device)
    return p12, primary_der, key, der, raw, profile


def build_package(module, root, original):
    source = Path("bump-debug").resolve()
    import subprocess
    result = subprocess.run(["bash", "scripts/ci-native.sh"], cwd=source, capture_output=True)
    if result.returncode:
        raise BumpError("native_build_failed")
    library = source / "output/BumpLocationDebug.dylib"
    if not library.is_file():
        raise BumpError("native_library_missing")
    unsigned = root / "unsigned.ipa"
    receipt = json.loads(module.run([sys.executable, str(source / "scripts/package_ipa.py"), str(original), str(library), str(unsigned)]))
    if receipt.get("input_sha256") != INPUT_SHA256:
        raise BumpError("package_input_contract_mismatch")
    payload = root / "payload"
    module.extract(unsigned, payload)
    return payload, receipt


def sign_package(module, root, payload, p12, der, raw, profile, original_keys, package_receipt):
    app = payload / "Payload/Location.app"
    bundles = validate_bundles(app)
    mappings = {info["CFBundleIdentifier"]: identifier for _, info, identifier in bundles}
    targets, removed = [], {}
    for index, (bundle, info, identifier) in enumerate(bundles):
        old = info["CFBundleIdentifier"]
        entitlements, shared_keychain = bundle_entitlements(module, profile, identifier)
        removed[identifier] = sorted(original_keys[old] - entitlements.keys())
        if not isinstance(info.get("KEYCHAIN_SHARED_GROUP"), str) or not re.fullmatch(r"[A-Z0-9]{10}\.co\.amo\.shared-group", info["KEYCHAIN_SHARED_GROUP"]):
            raise BumpError("unexpected_shared_keychain_configuration")
        info["KEYCHAIN_SHARED_GROUP"] = shared_keychain
        info["CFBundleIdentifier"] = identifier
        (bundle / "Info.plist").write_bytes(plistlib.dumps(remap_references(info, mappings)))
        (bundle / info["CFBundleExecutable"]).chmod(0o755)
        module.private(bundle / "embedded.mobileprovision", raw)
        entitlement_path = module.private(root / f"entitlements-{index}.plist", plistlib.dumps(entitlements))
        targets.append((bundle, info, identifier, entitlement_path))
    fingerprint = hashlib.sha1(der).hexdigest().upper()
    keychain = root / "signing.keychain-db"
    with module.signing_keychain_scope(keychain, secrets.token_urlsafe(32), p12, os.environ["DIST_P12_PASSWORD"], fingerprint):
        def sign(path, entitlements=None, stage="sign_macho"):
            args = ["/usr/bin/codesign", "--force", "--sign", fingerprint, "--keychain", str(keychain), "--timestamp=none", "--generate-entitlement-der"]
            if entitlements:
                args += ["--entitlements", str(entitlements)]
            module.run(args + [str(path)], error_stage=stage)
        executables = {bundle / info["CFBundleExecutable"] for bundle, info, _, _ in targets}
        macho_count = len(executables)
        for path in sorted(app.rglob("*"), key=lambda p: len(p.parts), reverse=True):
            if path.is_file() and path not in executables:
                with path.open("rb") as stream:
                    magic = stream.read(4)
                if magic in MACHO_MAGICS:
                    sign(path)
                    macho_count += 1
        for framework in sorted(app.rglob("*.framework"), key=lambda p: len(p.parts), reverse=True):
            sign(framework, stage="sign_framework")
        for bundle, _, _, entitlements in sorted(targets, key=lambda t: len(t[0].parts), reverse=True):
            sign(bundle, entitlements, "sign_root" if bundle == app else "sign_extension")
        module.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], error_stage="verify_deep_root")
        for index, (bundle, _, _, entitlements) in enumerate(targets):
            module.run(["/usr/bin/codesign", "--verify", "--strict", str(bundle)], error_stage="verify_bundle")
            actual = plistlib.loads(module.run(["/usr/bin/codesign", "-d", "--entitlements", ":-", str(bundle)], error_stage="inspect_entitlements"))
            if actual != plistlib.loads(entitlements.read_bytes()):
                raise BumpError("signed_entitlements_mismatch")
            if module.extract_signing_certificate(bundle, root / f"verified-cert-{index}-") != der:
                raise BumpError("signed_certificate_mismatch")
    ipa = root / "Bump-2.135.0-LocationDebug-SIGNED.ipa"
    with zipfile.ZipFile(ipa, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for path in sorted((payload / "Payload").rglob("*")):
            if path.is_file():
                archive.write(path, path.relative_to(payload))
    with zipfile.ZipFile(ipa) as archive:
        if archive.testzip() is not None:
            raise BumpError("signed_archive_integrity_failed")
    verification = {"file": ipa.name, "sha256": digest(ipa), "input_sha256": INPUT_SHA256,
        "source_commit": os.environ["GITHUB_SHA"], "bundle_identifier": ROOT_ID,
        "distribution": "IOS_APP_ADHOC", "provisioned_bundle_count": len(targets),
        "registered_device_count": 1, "signed_macho_count": macho_count,
        "certificate_sha256": hashlib.sha256(der).hexdigest(),
        "profile_selection": "existing_wildcard_read_only", "apple_resources_created_or_modified": False,
        "signature_verification": "codesign deep strict passed; nine bundles matched exact concrete entitlements and approved certificate",
        "original_entitlement_keys_not_granted": removed, "package_receipt": package_receipt,
        "device_installation": "not tested", "device_launch": "not tested", "scratch_behavior": "not tested",
        "location_injection": "implemented; software-simulated CLLocation; real-device execution not tested",
        "keychain_configuration": "KEYCHAIN_SHARED_GROUP mapped to verified profile-granted common app-owned keychain group",
        "extensions_and_shared_groups": "retained and signed; original App Group unavailable; main uses private sandbox fallback; cross-extension App Group sharing unverified"}
    receipt = module.private(root / "verification.json", (json.dumps(verification, indent=2) + "\n").encode())
    delivery = root / "delivery.zip"
    with zipfile.ZipFile(delivery, "w", compression=zipfile.ZIP_STORED) as archive:
        for path in (ipa, receipt):
            archive.write(path, path.name)
    output = Path("bump-output/BumpLocationDebug-signed.cms")
    output.parent.mkdir(exist_ok=True)
    module.run(["openssl", "cms", "-encrypt", "-aes-256-gcm", "-binary", "-in", str(delivery), "-outform", "DER", "-out", str(output), "bump-delivery-recipient.pem"])
    return verification


def main(argv=None):
    global STAGE
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare", action="store_true", help="Read-only signing readiness and public encryption key")
    options = parser.parse_args(argv)
    if os.environ.get("GITHUB_REPOSITORY") != "444yttt/Y3POSClient" or os.environ.get("GITHUB_REF") != "refs/heads/main":
        raise BumpError("authorized_ci_scope_required")
    if not re.fullmatch(r"[0-9a-f]{40}", os.environ.get("GITHUB_SHA", "")):
        raise BumpError("source_commit_missing")
    STAGE = "helper_validation"
    module = load_signer()
    module.configure_openssl()
    module.helper = module.load_helper()
    with tempfile.TemporaryDirectory(prefix="bump-signing-", dir=os.environ["RUNNER_TEMP"]) as directory:
        root = Path(directory)
        STAGE = "identity_and_existing_profiles"
        p12, primary_der, key, der, raw, profile = prepare_identity(module, root, not options.prepare)
        for suffix in SUFFIXES:
            bundle_entitlements(module, profile, ROOT_ID + suffix)
        if options.prepare:
            output = Path("bump-public")
            output.mkdir(exist_ok=True)
            public_key = module.run(["openssl", "x509", "-inform", "DER", "-pubkey", "-noout"], primary_der)
            (output / "signing-public-key.pem").write_bytes(public_key)
            readiness = {"input_certificate_sha256": hashlib.sha256(primary_der).hexdigest(),
                "signing_certificate_sha256": hashlib.sha256(der).hexdigest(),
                "existing_wildcard_bundle_coverage": len(SUFFIXES), "registered_device_count": 1,
                "source_commit": os.environ["GITHUB_SHA"], "apple_resources_created_or_modified": False,
                "signed_ipa_created": False}
            (output / "readiness.json").write_text(json.dumps(readiness, indent=2) + "\n")
            print("Bump signing readiness passed for nine bundles; published public key only. No Apple writes or signing.")
            return
        STAGE = "authenticated_input"
        envelope_path = Path("bump-signing-input.json")
        if envelope_path.stat().st_size > 100000:
            raise BumpError("encrypted_input_too_large")
        payload = decrypt_envelope(json.loads(envelope_path.read_text()), key.read_bytes())
        # A temporary source URL is a bearer credential: mask before any use.
        print("::add-mask::" + payload["url"], flush=True)
        original = root / "original.ipa"
        module.download_url_input(payload["url"], original, payload["allowed_hosts"])
        if digest(original) != INPUT_SHA256:
            raise BumpError("original_input_sha256_mismatch")
        original_keys = original_entitlement_keys(original)
        STAGE = "native_build_and_packaging"
        payload_root, package_receipt = build_package(module, root, original)
        STAGE = "signing_and_verification"
        verification = sign_package(module, root, payload_root, p12, der, raw, profile, original_keys, package_receipt)
        print("Bump signed IPA verified and recipient-encrypted. SHA256: " + verification["sha256"])
        print("Device installation, launch and scratch behavior were not tested. No Apple resources were changed.")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # Do not print arbitrary exception contents; they can contain URLs or private inputs.
        print("Bump signing failed stage=" + STAGE + " reason=" + safe_failure(error), file=sys.stderr)
        sys.exit(1)
