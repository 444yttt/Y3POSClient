#!/usr/bin/env python3
"""Recover only the authorized original via a public iCloud share.

Protocol source:
https://github.com/xxanqw/icloud-resolver/blob/076a4927fb3387a285b40a713963b84dd8458e23/src/icloud_resolver/__init__.py
Apple read-only records/resolve specification:
https://developer.apple.com/library/archive/documentation/DataManagement/Conceptual/CloudKitWebServicesReference/FetchingRecordInformation.html

No Apple login, cookies, developer API, private key, raw response logging, or raw
IPA artifact. TLS verification is mandatory. Plain input is deleted on every exit.
"""
import base64
import hashlib
import hmac
import json
import os
import plistlib
import secrets
import shutil
import ssl
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

EXPECTED_BYTES = 142120475
EXPECTED_SHA = "e7d77665740c61f2b0d6eae21cb6052acd2add364db3f6b5fc9ef9198ac31cbc"
INPUT_SOURCE = "1f749cd1b2433d2a32694d5c91849d22f84f429f"
CERTIFICATE_SHA = "ffa75cd0e6ab13c541756f2eeb7768a685cae584bc50e653e63396b3c9a7e4d4"
SHARE_ID = "05bTViiMeB6EVAiiZVTBmLCgg"
RESOLVE = "https://ckdatabasews.icloud.com/database/1/com.apple.cloudkit/production/public/records/resolve"
PUBLIC = Path("bereal-recovery-public")
ENCRYPTED = Path("bereal-recovery-encrypted")
PUBLIC_KEY = Path("recovery/signing-primary-public.pem")


class RecoveryError(Exception):
    def __init__(self, code, status=None):
        self.code = code
        self.status = status


def allowed_url(url):
    value = urllib.parse.urlsplit(url)
    host = (value.hostname or "").lower()
    if value.scheme != "https" or value.username or value.password or value.port not in (None, 443):
        raise RecoveryError("unapproved_https_origin")
    if not any(host == suffix or host.endswith("." + suffix)
               for suffix in ("icloud.com", "icloud-content.com", "apple.com")):
        raise RecoveryError("unapproved_https_origin")


class SafeRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, new_url):
        allowed_url(new_url)
        return super().redirect_request(request, fp, code, message, headers, new_url)


CLIENT = urllib.request.build_opener(
    urllib.request.HTTPSHandler(context=ssl.create_default_context()), SafeRedirect()
)


def open_request(request):
    allowed_url(request.full_url)
    try:
        return CLIENT.open(request, timeout=90)
    except urllib.error.HTTPError as exc:
        raise RecoveryError("http_error", exc.code) from None
    except (urllib.error.URLError, OSError):
        raise RecoveryError("network_or_tls_error") from None


def digest_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run_private(arguments, data=None):
    # Never propagate CalledProcessError or stderr: arguments can contain AES keys.
    try:
        result = subprocess.run(arguments, input=data, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, check=False)
    except OSError:
        raise RecoveryError("encryption_tool_unavailable") from None
    if result.returncode != 0:
        raise RecoveryError("encryption_tool_failed")
    return result.stdout


def resolve_public_file(report):
    request = urllib.request.Request(
        RESOLVE, data=json.dumps({"shortGUIDs": [{"value": SHARE_ID}]}).encode(),
        headers={"Content-Type": "application/json", "Accept": "application/json"},
        method="POST",
    )
    with open_request(request) as response:
        payload = response.read(2 * 1024 * 1024 + 1)
        report["resolve_http_status"] = response.status
    if len(payload) > 2 * 1024 * 1024:
        raise RecoveryError("metadata_too_large")
    data = json.loads(payload)
    results = data.get("results")
    if not isinstance(results, list) or len(results) != 1:
        raise RecoveryError("public_file_not_resolved")
    item = results[0]
    known_errors = {"NOT_FOUND", "UNKNOWN_ITEM", "PERMISSION_FAILURE", "AUTHENTICATION_REQUIRED",
                    "ACCESS_DENIED", "BAD_REQUEST", "SHARE_NOT_FOUND"}
    code = item.get("serverErrorCode")
    if code in known_errors:
        report["public_service_error_code"] = code
    fields = item.get("rootRecord", {}).get("fields", {})
    asset = fields.get("fileContent", {}).get("value", {})
    download = asset.get("downloadURL")
    if not isinstance(download, str) or not download:
        raise RecoveryError("public_file_download_unavailable")
    allowed_url(download)
    report["public_file_resolved"] = True
    # The signed URL and the complete response remain in process memory only.
    return download


def fetch_exact_original(url, target, report):
    request = urllib.request.Request(url, headers={"Accept-Encoding": "identity"})
    digest = hashlib.sha256()
    size = 0
    with open_request(request) as response, target.open("xb") as output:
        report["download_http_status"] = response.status
        while True:
            chunk = response.read(1024 * 1024)
            if not chunk:
                break
            size += len(chunk)
            if size > EXPECTED_BYTES:
                raise RecoveryError("original_size_exceeded")
            output.write(chunk)
            digest.update(chunk)
    report["downloaded_bytes"] = size
    report["sha256"] = digest.hexdigest()
    if size != EXPECTED_BYTES or digest.hexdigest() != EXPECTED_SHA:
        raise RecoveryError("original_size_or_sha256_mismatch")
    report["exact_original_verified"] = True
    with zipfile.ZipFile(target) as archive:
        info = archive.getinfo("Payload/BeReal.app/Info.plist")
        if info.file_size > 2 * 1024 * 1024:
            raise RecoveryError("invalid_original_metadata")
        plist = plistlib.loads(archive.read(info))
    identity = {key: plist.get(key) for key in
                ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion", "MinimumOSVersion")}
    if identity["CFBundleIdentifier"] != "AlexisBarreyat.BeReal":
        raise RecoveryError("original_identity_mismatch")
    if identity["CFBundleShortVersionString"] != "4.93.0" or str(identity["CFBundleVersion"]) != "23026":
        raise RecoveryError("original_version_mismatch")
    report["verified_app_metadata"] = identity


def encrypt_exact_original(original, report):
    ENCRYPTED.mkdir(exist_ok=True)
    encrypted = ENCRYPTED / "input-encrypted.bin"
    keys, iv = secrets.token_bytes(64), secrets.token_bytes(16)
    spki = run_private(["openssl", "pkey", "-pubin", "-in", str(PUBLIC_KEY),
                        "-outform", "DER"])
    report["encryption_public_spki_sha256"] = hashlib.sha256(spki).hexdigest()
    wrapped = run_private(
        ["openssl", "pkeyutl", "-encrypt", "-pubin", "-inkey", str(PUBLIC_KEY),
         "-pkeyopt", "rsa_padding_mode:oaep", "-pkeyopt", "rsa_oaep_md:sha256",
         "-pkeyopt", "rsa_mgf1_md:sha256"], keys
    )
    run_private(["openssl", "enc", "-aes-256-cbc", "-K", keys[:32].hex(),
                 "-iv", iv.hex(), "-in", str(original), "-out", str(encrypted)])
    authenticator = hmac.new(keys[32:], b"BeReal493EncryptedInputV1" + iv, hashlib.sha256)
    with encrypted.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            authenticator.update(chunk)
    encode = lambda value: base64.b64encode(value).decode("ascii")
    metadata = {
        "version": 3, "mode": "encrypted-local-file", "input_sha256": EXPECTED_SHA,
        "source_commit": INPUT_SOURCE, "encrypted_file": encrypted.name,
        "encrypted_bytes": encrypted.stat().st_size, "encrypted_sha256": digest_file(encrypted),
        "certificate_sha256": CERTIFICATE_SHA,
        "wrapped_keys": encode(wrapped), "iv": encode(iv), "hmac": encode(authenticator.digest()),
    }
    metadata_temp = ENCRYPTED / "metadata.tmp"
    metadata_temp.write_text(json.dumps(metadata, indent=2) + "\n")
    metadata_temp.replace(ENCRYPTED / "input-metadata.json")
    report["encrypted_input_prepared"] = True
    report["encrypted_bytes"] = metadata["encrypted_bytes"]
    report["encrypted_sha256"] = metadata["encrypted_sha256"]
    report["encryption_private_key_used_or_exported"] = False



def inspect_bonus_candidates(original, report):
    """Optional, bounded declaration-only parser; failure cannot hide recovery."""
    PUBLIC.mkdir(exist_ok=True)
    target = PUBLIC / "bonus-metadata.json"
    try:
        result = subprocess.run(
            [sys.executable, "scripts/inspect_bonus_metadata.py", str(original),
             "--output", str(target)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False, timeout=180,
        )
        if result.returncode != 0 or not target.is_file() or target.stat().st_size > 512 * 1024:
            raise RecoveryError("bonus_metadata_parser_unavailable")
        parsed = json.loads(target.read_text())
        if parsed.get("input_sha256") != EXPECTED_SHA:
            raise RecoveryError("bonus_metadata_input_mismatch")
        metadata = parsed["metadata"]
        report["bonus_metadata_status"] = "declaration_candidates_only"
        report["bonus_metadata_source_commit"] = "a5b4aa3c9b46adb233b3d6abfea545699f5c1366"
        report["bonus_metadata_sha256"] = digest_file(target)
        report["bonus_model_count"] = len(metadata["models"])
        report["bonus_string_count"] = len(metadata["string_candidates"])
        report["bonus_symbol_count"] = len(metadata["symbol_candidates"])
    except Exception:
        target.unlink(missing_ok=True)
        report["bonus_metadata_status"] = "unavailable; input recovery status unaffected"


def main():
    os.umask(0o077)
    report = {
        "purpose": "authorized_public_share_original_recovery",
        "expected_bytes": EXPECTED_BYTES, "expected_sha256": EXPECTED_SHA,
        "public_file_resolved": False, "exact_original_verified": False,
        "encrypted_input_prepared": False, "raw_input_uploaded": False,
        "apple_login_or_developer_write_performed": False,
    }
    code = 1
    temporary_root = None
    try:
        with tempfile.TemporaryDirectory(prefix="bereal-original-", dir=os.environ.get("RUNNER_TEMP")) as temporary:
            temporary_root = Path(temporary)
            original = temporary_root / "original.ipa"
            download = resolve_public_file(report)
            fetch_exact_original(download, original, report)
            report["status"] = "exact_original_recovered"
            code = 0
            # Optional persistence must not hide a successful source-file probe.
            try:
                encrypt_exact_original(original, report)
            except Exception:
                shutil.rmtree(ENCRYPTED, ignore_errors=True)
                report["encryption_status"] = "unavailable; exact-source probe still succeeded"
            inspect_bonus_candidates(original, report)
    except RecoveryError as exc:
        report["status"] = "recovery_unavailable"
        report["failure_kind"] = exc.code
        if exc.status is not None:
            report["http_status"] = exc.status
    except Exception as exc:
        report["status"] = "recovery_unavailable"
        report["failure_kind"] = "unexpected_recovery_error"
        report["exception_type"] = type(exc).__name__
    finally:
        report["temporary_plain_input_removed"] = temporary_root is None or not temporary_root.exists()
        PUBLIC.mkdir(exist_ok=True)
        (PUBLIC / "recovery.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, sort_keys=True))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
