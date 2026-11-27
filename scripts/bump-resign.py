#!/usr/bin/env python3
"""Bump-only Ad Hoc signing in the existing Y3 CI; never export private assets."""

from __future__ import annotations

import argparse
import base64
import datetime
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
import uuid
import zipfile


INPUT_SHA256 = "0b18338b5db68e39ba1de6f5e45c8c79d2211d25da58dc9d4ffa6783bb41773e"
ROOT_ID = "com.ayato.bumpdebug"
ORIGINAL_ID = "co.amo.ios.location"
SUFFIXES = ("", ".lpse", ".friend-widget", ".nce", ".friend-intent",
            ".on-my-way-live-activity", ".nse", ".imessage-stickers-extension", ".share")
AAD = b"BumpLocationDebugInputV1"
SIGNER_SHA256 = "38ca0dcdc3bb2586f3e105d453036890fc6445db209e628ddd40300aeadf9104"
PROFILE_HELPER_SHA256 = "628459c1f26615a8defa2d671e38630cdfeec409ddf6cac13f417e5e652a1697"
MACHO_MAGICS = frozenset((b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xce", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"))
STAGE = "startup"
AUTHORIZED_REPOSITORIES = frozenset(("444yttt/Y3POSClient", "444yttt/Y3FloorGuide"))


class BumpError(RuntimeError):
    """A fixed diagnostic suitable for public CI logs."""


def validate_ci_scope(repository, ref, source_commit):
    if repository not in AUTHORIZED_REPOSITORIES or ref != "refs/heads/main":
        raise BumpError("authorized_ci_scope_required")
    if not isinstance(source_commit, str) or not re.fullmatch(r"[0-9a-f]{40}", source_commit):
        raise BumpError("source_commit_missing")


def safe_failure(error):
    if isinstance(error, BumpError):
        return str(error)
    message = str(error)
    if isinstance(error, RuntimeError):
        match = re.search(r"codesign stage=([a-z_]+) reason=([a-z_]+)", message)
        if match:
            return match.group(0)
        match = re.search(r"Apple API (GET|POST) /v1/(certificates|profiles|devices|bundleIds)(?:/[^ ]+)? failed \(HTTP ([0-9]{3})\)", message)
        if match:
            return "apple_api_" + match.group(1).lower() + "_" + match.group(2) + "_http" + match.group(3)
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
    if identifier not in {ROOT_ID + suffix for suffix in SUFFIXES}:
        raise BumpError("unapproved_bundle_scope")
    grant = profile["Entitlements"].get("application-identifier", "")
    if not isinstance(grant, str) or "." not in grant:
        raise BumpError("invalid_profile_identity")
    entitlements = (module.existing_wildcard_entitlements(profile, identifier) if "*" in grant
                    else module.concrete_entitlements(profile, identifier))
    prefix = entitlements["application-identifier"].split(".", 1)[0]
    shared = prefix + "." + ROOT_ID
    grants = profile["Entitlements"].get("keychain-access-groups")
    if not isinstance(grants, list) or not grants:
        raise BumpError("profile_has_no_scoped_keychain_grant")
    if not any(isinstance(grant, str) and module.apple_identifier_grant_matches(grant, shared) for grant in grants):
        shared = entitlements["application-identifier"]
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


def inventory_time(value):
    try:
        if isinstance(value, datetime.datetime):
            result = value
        elif isinstance(value, str):
            result = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
        else:
            return None
        return result.replace(tzinfo=datetime.timezone.utc) if result.tzinfo is None else result.astimezone(datetime.timezone.utc)
    except (ValueError, TypeError, OverflowError):
        return None


def inventory_grant_matches(grant, identifier):
    return isinstance(grant, str) and (grant == "*" or grant == identifier or
        (grant.endswith(".*") and identifier.startswith(grant[:-1])))


def inventory_certificate_evidence(certificates, identities, team, certificate_catalog, now):
    """Compare public keys without exporting certificates, subjects or fingerprints."""
    from cryptography import x509
    from cryptography.hazmat.primitives import serialization
    from cryptography.x509.oid import NameOID
    def public_key(der):
        return x509.load_der_x509_certificate(der).public_key().public_bytes(
            serialization.Encoding.DER, serialization.PublicFormat.SubjectPublicKeyInfo)
    keys = {}
    for role, der in identities.items():
        try:
            keys[role] = public_key(der)
        except (ValueError, TypeError):
            continue
    active_certificates = []
    for resource in certificate_catalog or []:
        attributes = resource.get("attributes", {}) if isinstance(resource, dict) else {}
        expiry = inventory_time(attributes.get("expirationDate"))
        if attributes.get("certificateType") not in ("IOS_DISTRIBUTION", "DISTRIBUTION") or expiry is None or expiry <= now:
            continue
        try:
            active_certificates.append(base64.b64decode("".join(attributes.get("certificateContent", "").split()), validate=True))
        except (ValueError, TypeError, AttributeError):
            continue
    result = []
    for index, der in enumerate(certificates if isinstance(certificates, list) else []):
        record = {"certificate_index": index, "matching_existing_key_roles": [], "currently_valid": False,
            "matches_active_apple_distribution_certificate": False, "same_team": False}
        try:
            leaf = x509.load_der_x509_certificate(der)
            spki = public_key(der)
            record["matching_existing_key_roles"] = sorted({role if role in ("existing_primary", "existing_alternate") else "other_existing_identity"
                for role, key in keys.items() if key == spki})
            record["currently_valid"] = leaf.not_valid_before_utc <= now < leaf.not_valid_after_utc
            record["same_team"] = any(attribute.value == team for attribute in leaf.subject.get_attributes_for_oid(NameOID.ORGANIZATIONAL_UNIT_NAME))
            record["matches_active_apple_distribution_certificate"] = der in active_certificates
        except (ValueError, TypeError):
            pass
        result.append(record)
    return result


def analyze_inventory_profile(profile, identities, team, udid, metadata=None, certificate_catalog=None):
    """Analyze authenticated profile contents without exporting identifiers or values."""
    if not isinstance(profile, dict) or not isinstance(profile.get("Entitlements"), dict):
        raise BumpError("invalid_inventory_profile")
    entitlements = profile["Entitlements"]
    application_id = entitlements.get("application-identifier")
    match = re.fullmatch(r"([A-Z0-9]{10})\.(\*|[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*(?:\.\*)?)", application_id) if isinstance(application_id, str) else None
    prefix, grant = match.groups() if match else (None, None)
    prefixes, teams = profile.get("ApplicationIdentifierPrefix"), profile.get("TeamIdentifier")
    prefix_consistent = prefix is not None and isinstance(prefixes, list) and prefix in prefixes
    team_matches = isinstance(teams, list) and team in teams and entitlements.get("com.apple.developer.team-identifier") == team
    developer_certificates = profile.get("DeveloperCertificates", [])
    roles = [role for role, certificate in identities.items() if isinstance(developer_certificates, list) and certificate in developer_certificates]
    matching_roles = sorted({role if role in ("existing_primary", "existing_alternate") else "other_existing_identity" for role in roles})
    devices = profile.get("ProvisionedDevices")
    device_match = isinstance(devices, list) and devices == [udid] and not profile.get("ProvisionsAllDevices")
    now = datetime.datetime.now(datetime.timezone.utc)
    expiration = inventory_time(profile.get("ExpirationDate"))
    creation = inventory_time(profile.get("CreationDate"))
    current_validity = expiration is not None and expiration > now and ("CreationDate" not in profile or (creation is not None and creation <= now))
    profile_type = (metadata or {}).get("profileType")
    if not isinstance(profile_type, str):
        profile_type = ("IOS_APP_DEVELOPMENT" if entitlements.get("get-task-allow") is True else
            "IOS_APP_INHOUSE" if profile.get("ProvisionsAllDevices") else
            "IOS_APP_ADHOC" if isinstance(devices, list) and devices else
            "IOS_APP_STORE" if entitlements.get("get-task-allow") is False and devices is None else "UNCLASSIFIED")
    metadata_matches = True
    try:
        profile_uuid = str(uuid.UUID(profile.get("UUID", "")))
    except (ValueError, TypeError, AttributeError):
        profile_uuid = None
        metadata_matches = False
    if metadata is not None:
        metadata_expiry = inventory_time(metadata.get("expirationDate"))
        current_validity = bool(current_validity and metadata_expiry is not None and metadata_expiry > now)
        try:
            metadata_matches = bool(profile_uuid and str(uuid.UUID(metadata.get("uuid", ""))) == profile_uuid)
        except (ValueError, TypeError, AttributeError):
            metadata_matches = False
    state_active = metadata is None or metadata.get("profileState") == "ACTIVE"
    keychain_scopes = []
    keychain_grants = entitlements.get("keychain-access-groups")
    valid_keychain_grants = isinstance(keychain_grants, list) and bool(keychain_grants)
    if isinstance(keychain_grants, list):
        for value in keychain_grants:
            if value == "com.apple.token":
                keychain_scopes.append({"scope": "com.apple.token", "kind": "system", "application_prefix_matches": False})
                continue
            keychain_match = re.fullmatch(r"([A-Z0-9]{10})\.(\*|[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*(?:\.\*)?)", value) if isinstance(value, str) else None
            if keychain_match:
                grant_prefix, keychain_scope = keychain_match.groups()
                keychain_scopes.append({"scope": keychain_scope, "kind": "application", "application_prefix_matches": prefix is not None and grant_prefix == prefix})
            else:
                valid_keychain_grants = False
                keychain_scopes.append({"scope": "<invalid>", "kind": "invalid", "application_prefix_matches": False})
    usable = bool(profile_type == "IOS_APP_ADHOC" and state_active and current_validity and metadata_matches and
        matching_roles and device_match and team_matches and prefix_consistent and entitlements.get("get-task-allow") is False)
    certificate_evidence = inventory_certificate_evidence(developer_certificates, identities, team, certificate_catalog, now)
    usable_existing_key = bool(profile_type == "IOS_APP_ADHOC" and state_active and current_validity and metadata_matches and
        device_match and team_matches and prefix_consistent and entitlements.get("get-task-allow") is False and any(
            item["matching_existing_key_roles"] and item["currently_valid"] and item["same_team"] and
            item["matches_active_apple_distribution_certificate"] for item in certificate_evidence))
    candidates = []
    if usable and valid_keychain_grants and grant is not None:
        candidate = ROOT_ID if grant == "*" else grant[:-2] + ".bumpdebug" if grant.endswith(".*") else None
        if candidate and all(inventory_grant_matches(grant, candidate + suffix) and
                any(inventory_grant_matches(keychain_grant, prefix + "." + candidate + suffix) for keychain_grant in keychain_grants)
                for suffix in SUFFIXES):
            candidates.append(candidate)
    return {"profile_type": profile_type if profile_type in {"IOS_APP_ADHOC", "IOS_APP_STORE", "IOS_APP_STORE_CONNECT", "IOS_APP_DEVELOPMENT", "IOS_APP_INHOUSE"} else "OTHER",
        "application_identifier_grant": grant,
        "application_identifier_kind": "wildcard" if grant and "*" in grant else "explicit" if grant else "invalid",
        "certificate_matches_existing_identity": bool(matching_roles), "matching_identity_roles": matching_roles,
        "registered_device_set_matches": bool(device_match), "registered_device_included": isinstance(devices, list) and udid in devices,
        "provisioned_device_count": len(devices) if isinstance(devices, list) else 0,
        "current_validity": bool(current_validity), "team_matches_existing_identity": bool(team_matches),
        "application_prefix_consistent": bool(prefix_consistent), "profile_metadata_matches": bool(metadata_matches),
        "usable_ad_hoc_distribution": usable, "keychain_grant_scopes": keychain_scopes,
        "profile_certificates": certificate_evidence, "potentially_usable_with_existing_key": usable_existing_key,
        "compatible_isolated_debug_roots": candidates}


def inspect_inventory_cms(module, raw, identities, team, udid, metadata=None, certificate_catalog=None):
    if not isinstance(raw, bytes) or not 1 <= len(raw) <= 10 * 1024 * 1024:
        return {"cms_signature_valid": False, "inspection_error": "invalid_profile_content"}
    try:
        decoded = module.run(["openssl", "cms", "-verify", "-inform", "DER", "-noverify"], raw)
        profile = plistlib.loads(decoded)
        report = analyze_inventory_profile(profile, identities, team, udid, metadata, certificate_catalog)
        report["cms_signature_valid"] = True
        return report
    except Exception as error:
        return {"cms_signature_valid": False, "inspection_error": safe_failure(error)}


def inventory_existing(module, root):
    """Read all existing profile scopes; encrypt details, publish only safe counts."""
    _, primary_der, _, asc = module.decode_identity(root, need_private_key=False)
    api = ReadOnlyAPI(module.RefreshingAppleAPI(asc))
    _, device = module.signing_readiness(api, primary_der)
    identities = {"existing_primary": primary_der}
    alternate_status = "not_configured"
    alternate_certificate, alternate_password = bool(os.environ.get("DIST_P12_BASE64")), bool(os.environ.get("DIST_P12_PASSWORD"))
    if alternate_certificate != alternate_password:
        alternate_status = "incomplete_configuration"
    elif alternate_certificate:
        alternate = root / "inventory-alternate"
        alternate.mkdir(mode=0o700)
        try:
            _, alternate_der, _, _ = module.decode_identity(alternate, need_private_key=False,
                certificate_env="DIST_P12_BASE64", password_env="DIST_P12_PASSWORD")
            _, alternate_device = module.signing_readiness(api, alternate_der)
            if alternate_device["attributes"]["udid"] != device["attributes"]["udid"]:
                raise BumpError("registered_device_changed")
            identities["existing_alternate"] = alternate_der
            alternate_status = "validated"
        except Exception as error:
            alternate_status = safe_failure(error)
    output = Path("bump-public")
    output.mkdir(exist_ok=True)
    public_key = module.run(["openssl", "x509", "-inform", "DER", "-pubkey", "-noout"], primary_der)
    (output / "signing-public-key.pem").write_bytes(public_key)
    profiles, inventory_errors = [], []
    counts = {"api_profile_count": 0, "active_ios_adhoc_count": 0, "appstore_profile_count": 0,
        "other_profile_count": 0, "inactive_ios_adhoc_count": 0}
    try:
        resources = api.collection("/v1/profiles", {"fields[profiles]": "uuid,profileType,profileState,profileContent,expirationDate"})
    except Exception as error:
        resources = []
        inventory_errors.append({"stage": "list_existing_profiles", "reason": safe_failure(error)})
    counts["api_profile_count"] = len(resources)
    try:
        certificate_catalog = api.collection("/v1/certificates")
    except Exception as error:
        certificate_catalog = []
        inventory_errors.append({"stage": "list_existing_certificates", "reason": safe_failure(error)})
    for index, resource in enumerate(resources):
        attributes = resource.get("attributes", {})
        profile_type = attributes.get("profileType")
        if profile_type in ("IOS_APP_STORE", "IOS_APP_STORE_CONNECT", "MAC_APP_STORE", "TVOS_APP_STORE", "MAC_CATALYST_APP_STORE"):
            counts["appstore_profile_count"] += 1
            continue
        if profile_type != "IOS_APP_ADHOC":
            counts["other_profile_count"] += 1
            continue
        if attributes.get("profileState") != "ACTIVE":
            counts["inactive_ios_adhoc_count"] += 1
            continue
        counts["active_ios_adhoc_count"] += 1
        try:
            if not attributes.get("profileContent"):
                resource = api.request("GET", "/v1/profiles/" + resource_id(resource.get("id")))["data"]
                attributes = resource.get("attributes", {})
            raw = module.helper.decode_base64(attributes.get("profileContent", ""))
            record = inspect_inventory_cms(module, raw, identities, os.environ["APPLE_TEAM_ID"], device["attributes"]["udid"], attributes, certificate_catalog)
        except Exception as error:
            record = {"cms_signature_valid": False, "inspection_error": safe_failure(error)}
        profiles.append({"source": "apple_api", "profile_index": index, **record})
    embedded_status = {"present": bool(os.environ.get("BUILD_PROVISION_PROFILE_BASE64"))}
    if embedded_status["present"]:
        try:
            raw = module.helper.decode_base64(os.environ["BUILD_PROVISION_PROFILE_BASE64"])
            embedded = inspect_inventory_cms(module, raw, identities, os.environ["APPLE_TEAM_ID"], device["attributes"]["udid"], certificate_catalog=certificate_catalog)
            embedded_status["profile_type"] = embedded.get("profile_type", "UNCLASSIFIED")
            embedded_status["cms_signature_valid"] = embedded.get("cms_signature_valid", False)
            if embedded.get("profile_type") == "IOS_APP_STORE":
                embedded_status["classification_only"] = True
            else:
                profiles.append({"source": "ci_embedded_profile", **embedded})
        except Exception as error:
            embedded_status["inspection_error"] = safe_failure(error)
    error_count = len(inventory_errors) + sum("inspection_error" in record for record in profiles) + int("inspection_error" in embedded_status)
    summary = {"mode": "read_only_existing_profile_inventory", **counts,
        "existing_identity_count": len(identities), "embedded_profile_present": embedded_status["present"],
        "compatible_isolated_namespace_profile_count": sum(bool(record.get("compatible_isolated_debug_roots")) for record in profiles),
        "inspection_error_count": error_count, "inventory_complete": error_count == 0,
        "apple_resources_created_or_modified": False, "signed_ipa_created": False,
        "source_commit": os.environ["GITHUB_SHA"]}
    report = {"summary": summary, "alternate_identity_status": alternate_status, "profiles": profiles,
        "ci_embedded_profile": embedded_status, "inventory_errors": inventory_errors,
        "validation_limits": ["CMS signatures checked; Apple CA chain and revocation not checked",
            "Candidate roots prove nine-bundle application/keychain namespace coverage only; signing behavior unchanged",
            "Potential existing-key reuse requires a current same-team leaf exactly present in the active Apple distribution certificate catalog; namespace acceptance unchanged",
            "No raw profile, certificate subject, team prefix or registered-device identifier is exported"]}
    plaintext = module.private(root / "inventory.json", (json.dumps(report, indent=2) + "\n").encode())
    encrypted = Path("bump-output/BumpLocationDebug-profile-inventory.cms")
    encrypted.parent.mkdir(exist_ok=True)
    module.run(["openssl", "cms", "-encrypt", "-aes-256-gcm", "-binary", "-in", str(plaintext), "-outform", "DER", "-out", str(encrypted), "bump-delivery-recipient.pem"])
    (output / "inventory-summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print("Read-only profile inventory encrypted. Active iOS Ad Hoc profiles: " + str(counts["active_ios_adhoc_count"]) +
        "; candidate namespace profiles: " + str(summary["compatible_isolated_namespace_profile_count"]) +
        "; inspection errors: " + str(error_count) + ". No Apple resources changed.")
    return report


def resource_id(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9-]{1,128}", value):
        raise BumpError("invalid_apple_resource_identifier")
    return value


def registration_name(identifier):
    if identifier not in {ROOT_ID + suffix for suffix in SUFFIXES}:
        raise BumpError("unapproved_bundle_scope")
    return "BumpLocationDebug " + (identifier[len(ROOT_ID):].lstrip(".") or "app")


def profile_name(identifier):
    return registration_name(identifier).replace(" ", "-AdHoc-", 1)


def validate_registration(resource, identifier):
    if identifier not in {ROOT_ID + suffix for suffix in SUFFIXES}:
        raise BumpError("unapproved_bundle_scope")
    if (not isinstance(resource, dict) or resource.get("type") != "bundleIds" or
            resource.get("attributes", {}).get("identifier") != identifier or
            resource.get("attributes", {}).get("platform") not in ("IOS", "UNIVERSAL")):
        raise BumpError("unexpected_bundle_registration")
    return resource_id(resource.get("id"))


class ScopedProvisioningAPI(ReadOnlyAPI):
    """Only exact Bump app registrations/profiles may be created in explicit mode."""
    def __init__(self, api, certificate_id, device_id):
        super().__init__(api)
        self.certificate_id, self.device_id = resource_id(certificate_id), resource_id(device_id)
        self.registrations = {}
        self.posted_bundles, self.posted_profiles = set(), set()

    def accept_registration(self, resource, identifier):
        bundle_id = validate_registration(resource, identifier)
        if bundle_id in self.registrations and self.registrations[bundle_id] != identifier:
            raise BumpError("ambiguous_bundle_registration")
        if any(existing_id != bundle_id and existing_identifier == identifier for existing_id, existing_identifier in self.registrations.items()):
            raise BumpError("ambiguous_bundle_registration")
        self.registrations[bundle_id] = identifier

    def request(self, method, path, body=None):
        if method == "GET":
            return self.api.request(method, path, body)
        if method != "POST" or path not in ("/v1/bundleIds", "/v1/profiles"):
            raise BumpError("apple_write_outside_bump_scope")
        if not isinstance(body, dict) or set(body) != {"data"} or not isinstance(body["data"], dict):
            raise BumpError("invalid_scoped_apple_write")
        data = body["data"]
        if path == "/v1/bundleIds":
            if set(data) != {"type", "attributes"} or data["type"] != "bundleIds" or not isinstance(data["attributes"], dict):
                raise BumpError("invalid_scoped_bundle_write")
            attributes = data["attributes"]
            identifier = attributes.get("identifier")
            if attributes != {"identifier": identifier, "name": registration_name(identifier), "platform": "IOS"}:
                raise BumpError("invalid_scoped_bundle_write")
            if identifier in self.posted_bundles or identifier in self.registrations.values():
                raise BumpError("duplicate_scoped_bundle_write")
            self.posted_bundles.add(identifier)
        else:
            if set(data) != {"type", "attributes", "relationships"} or data["type"] != "profiles":
                raise BumpError("invalid_scoped_profile_write")
            relationships = data["relationships"]
            if not isinstance(relationships, dict) or set(relationships) != {"bundleId", "certificates", "devices"}:
                raise BumpError("invalid_scoped_profile_relationships")
            bundle_data = relationships.get("bundleId", {}).get("data", {})
            if not isinstance(bundle_data, dict) or set(bundle_data) != {"type", "id"} or bundle_data["type"] != "bundleIds":
                raise BumpError("invalid_scoped_profile_relationships")
            bundle_id = bundle_data["id"]
            identifier = self.registrations.get(bundle_id)
            if identifier is None:
                raise BumpError("unvalidated_profile_bundle_registration")
            expected_relationships = {"bundleId": {"data": {"type": "bundleIds", "id": bundle_id}},
                "certificates": {"data": [{"type": "certificates", "id": self.certificate_id}]},
                "devices": {"data": [{"type": "devices", "id": self.device_id}]}}
            if (relationships != expected_relationships or
                    data["attributes"] != {"name": profile_name(identifier), "profileType": "IOS_APP_ADHOC"}):
                raise BumpError("invalid_scoped_profile_write")
            if bundle_id in self.posted_profiles:
                raise BumpError("duplicate_scoped_profile_write")
            self.posted_profiles.add(bundle_id)
        return self.api.request(method, path, body)


def exact_profile(module, api, certificate, der, team, identifier, device, create=False):
    if identifier not in {ROOT_ID + suffix for suffix in SUFFIXES}:
        raise BumpError("unapproved_bundle_scope")
    if create and not isinstance(api, ScopedProvisioningAPI):
        raise BumpError("explicit_scoped_provisioning_required")
    registrations = api.collection("/v1/bundleIds", {"filter[identifier]": identifier})
    matches = [item for item in registrations if item.get("attributes", {}).get("identifier") == identifier]
    if len(matches) > 1:
        raise BumpError("ambiguous_bundle_registration")
    created_bundle = not matches
    if not matches:
        if not create:
            raise BumpError("missing_scoped_bundle_registration")
        bundle = api.request("POST", "/v1/bundleIds", {"data": {"type": "bundleIds", "attributes": {
            "name": registration_name(identifier), "identifier": identifier, "platform": "IOS"}}})["data"]
    else:
        bundle = matches[0]
    bundle_id = validate_registration(bundle, identifier)
    if isinstance(api, ScopedProvisioningAPI):
        api.accept_registration(bundle, identifier)
    candidates = api.collection("/v1/bundleIds/" + bundle_id + "/profiles", {
        "fields[profiles]": "name,uuid,profileType,profileState,profileContent,expirationDate"})
    candidates = [item for item in candidates if item.get("attributes", {}).get("profileType") == "IOS_APP_ADHOC" and item.get("attributes", {}).get("profileState") == "ACTIVE"]
    candidates.sort(key=lambda item: item.get("attributes", {}).get("expirationDate", ""), reverse=True)
    for candidate in candidates:
        if not candidate["attributes"].get("profileContent"):
            candidate = api.request("GET", "/v1/profiles/" + resource_id(candidate.get("id")))["data"]
        try:
            raw, profile = module.validate_profile(candidate, der, team, identifier, device["attributes"]["udid"])
            return (raw, profile), {"created_bundle_count": int(created_bundle), "created_profile_count": 0, "reused_profile_count": 1}
        except (RuntimeError, KeyError, ValueError, TypeError):
            continue
    if not create:
        raise BumpError("no_compatible_existing_exact_profile")
    created = api.request("POST", "/v1/profiles", {"data": {"type": "profiles", "attributes": {
        "name": profile_name(identifier), "profileType": "IOS_APP_ADHOC"}, "relationships": {
        "bundleId": {"data": {"type": "bundleIds", "id": bundle_id}},
        "certificates": {"data": [{"type": "certificates", "id": certificate["id"]}]},
        "devices": {"data": [{"type": "devices", "id": device["id"]}]}}}})["data"]
    if not created.get("attributes", {}).get("profileContent"):
        created = api.request("GET", "/v1/profiles/" + resource_id(created.get("id")))["data"]
    raw, profile = module.validate_profile(created, der, team, identifier, device["attributes"]["udid"])
    return (raw, profile), {"created_bundle_count": int(created_bundle), "created_profile_count": 1, "reused_profile_count": 0}


def prepare_identity(module, root, need_private_key, create_profiles=False):
    alternate_certificate = bool(os.environ.get("DIST_P12_BASE64"))
    alternate_password = bool(os.environ.get("DIST_P12_PASSWORD"))
    if alternate_certificate != alternate_password:
        raise BumpError("incomplete_alternate_signing_assets")
    p12, primary_der, key, asc = module.decode_identity(root, need_private_key=need_private_key)
    underlying_api = module.RefreshingAppleAPI(asc)
    api = ReadOnlyAPI(underlying_api)
    certificate, device = module.signing_readiness(api, primary_der)
    der, password_env, identity_role = primary_der, "P12_PASSWORD", "existing_primary"
    if alternate_certificate:
        alternate = root / "alternate"
        alternate.mkdir(mode=0o700)
        p12, der, _, _ = module.decode_identity(alternate, need_private_key=False,
            certificate_env="DIST_P12_BASE64", password_env="DIST_P12_PASSWORD")
        certificate, alternate_device = module.signing_readiness(api, der)
        if alternate_device["attributes"]["udid"] != device["attributes"]["udid"]:
            raise BumpError("registered_device_changed")
        password_env, identity_role = "DIST_P12_PASSWORD", "existing_alternate"
    statistics = {"created_bundle_count": 0, "created_profile_count": 0, "reused_profile_count": 0}
    try:
        raw, profile = module.select_existing_wildcard_profile(api, der, os.environ["APPLE_TEAM_ID"], device)
        profiles = {ROOT_ID + suffix: (raw, profile) for suffix in SUFFIXES}
        selection = "existing_wildcard_read_only"
        statistics["reused_profile_count"] = 1
    except RuntimeError as error:
        if not str(error).startswith("No existing wildcard Ad Hoc profile proves"):
            raise
        if create_profiles:
            api = ScopedProvisioningAPI(underlying_api, certificate["id"], device["id"])
        profiles = {}
        for suffix in SUFFIXES:
            identifier = ROOT_ID + suffix
            pair, changes = exact_profile(module, api, certificate, der, os.environ["APPLE_TEAM_ID"], identifier, device, create_profiles)
            profiles[identifier] = pair
            for name, value in changes.items():
                statistics[name] += value
        selection = "exact_scoped_profiles"
    return {"p12": p12, "primary_der": primary_der, "key": key, "der": der, "profiles": profiles,
        "password_env": password_env, "identity_role": identity_role, "profile_selection": selection, "statistics": statistics}


def wildcard_registration(resource):
    """An existing iOS/all-platform wildcard must authorize every fixed Bump ID."""
    if not isinstance(resource, dict) or resource.get("type") != "bundleIds":
        raise BumpError("invalid_existing_wildcard_registration")
    attributes = resource.get("attributes", {})
    grant = attributes.get("identifier")
    if (attributes.get("platform") not in ("IOS", "UNIVERSAL") or not isinstance(grant, str) or
            not re.fullmatch(r"\*|[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*\.\*", grant) or
            not all(inventory_grant_matches(grant, ROOT_ID + suffix) for suffix in SUFFIXES)):
        raise BumpError("existing_wildcard_does_not_cover_bump")
    return resource_id(resource.get("id")), grant


class ExistingWildcardProfileAPI(ReadOnlyAPI):
    """One profile creation bound to a validated existing wildcard and assets."""
    def __init__(self, api, certificate_id, device_id, registration):
        super().__init__(api)
        self.bundle_id, _ = wildcard_registration(registration)
        self.certificate_id, self.device_id = resource_id(certificate_id), resource_id(device_id)
        self.posted = False

    def request(self, method, path, body=None):
        if method == "GET":
            return self.api.request(method, path, body)
        expected = {"data": {"type": "profiles", "attributes": {
            "name": "BumpLocationDebug-ExistingWildcard-AdHoc", "profileType": "IOS_APP_ADHOC"},
            "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": self.bundle_id}},
                "certificates": {"data": [{"type": "certificates", "id": self.certificate_id}]},
                "devices": {"data": [{"type": "devices", "id": self.device_id}]}}}}
        if method != "POST" or path != "/v1/profiles" or body != expected:
            raise BumpError("existing_wildcard_profile_write_outside_scope")
        if self.posted:
            raise BumpError("duplicate_existing_wildcard_profile_write")
        self.posted = True
        return self.api.request(method, path, body)


def existing_wildcard_proof(module, registration, resource, team, udid):
    """Prove current official grant/device scope independently of its old key."""
    _, grant = wildcard_registration(registration)
    attributes = resource.get("attributes", {})
    if attributes.get("profileType") != "IOS_APP_ADHOC" or attributes.get("profileState") != "ACTIVE":
        raise BumpError("existing_wildcard_profile_not_active_adhoc")
    raw = module.helper.decode_base64(attributes.get("profileContent", ""))
    if not 1 <= len(raw) <= 10 * 1024 * 1024:
        raise BumpError("invalid_existing_wildcard_profile_content")
    profile = plistlib.loads(module.run(["openssl", "cms", "-verify", "-inform", "DER", "-noverify"], raw))
    proof = analyze_inventory_profile(profile, {}, team, udid, attributes)
    if (proof["application_identifier_grant"] != grant or not all(proof[key] for key in (
            "registered_device_set_matches", "current_validity", "team_matches_existing_identity",
            "application_prefix_consistent", "profile_metadata_matches")) or
            profile["Entitlements"].get("get-task-allow") is not False):
        raise BumpError("existing_wildcard_profile_grant_proof_failed")
    for suffix in SUFFIXES:
        module.existing_wildcard_entitlements(profile, ROOT_ID + suffix)
    return raw, profile


def prepare_existing_wildcard(module, root):
    """Explicitly reuse/reissue one profile for an already registered wildcard."""
    _, der, _, asc = module.decode_identity(root, need_private_key=False)
    underlying = module.RefreshingAppleAPI(asc)
    api = ReadOnlyAPI(underlying)
    certificate, device = module.signing_readiness(api, der)
    team, udid = os.environ["APPLE_TEAM_ID"], device["attributes"]["udid"]
    registrations = api.collection("/v1/bundleIds", {"fields[bundleIds]": "identifier,platform"})
    compatible = []
    for resource in registrations:
        try:
            wildcard_registration(resource)
            compatible.append(resource)
        except BumpError:
            continue
    if len(compatible) != 1:
        raise BumpError("existing_wildcard_registration_not_unique" if compatible else "existing_wildcard_registration_missing")
    registration = compatible[0]
    bundle_id, _ = wildcard_registration(registration)
    candidates = api.collection("/v1/bundleIds/" + bundle_id + "/profiles", {
        "fields[profiles]": "uuid,profileType,profileState,profileContent,expirationDate"})
    candidates = [item for item in candidates if item.get("attributes", {}).get("profileType") == "IOS_APP_ADHOC" and item.get("attributes", {}).get("profileState") == "ACTIVE"]
    expected_identifiers = {ROOT_ID + suffix for suffix in SUFFIXES}
    has_existing_grant_proof, matching_profile = False, False
    for candidate in candidates:
        # A failed read is never treated as permission to create a duplicate.
        if not candidate["attributes"].get("profileContent"):
            candidate = api.request("GET", "/v1/profiles/" + resource_id(candidate.get("id")))["data"]
        try:
            existing_wildcard_proof(module, registration, candidate, team, udid)
            has_existing_grant_proof = True
        except (RuntimeError, ValueError, TypeError, KeyError):
            continue
        try:
            compatibility = module.probe_profile_compatibility(candidate, der, team, udid)
            if compatibility["application_identifier_kind"] == "wildcard" and set(compatibility["compatible_scoped_identifiers"]) == expected_identifiers:
                matching_profile = True
                break
        except (RuntimeError, ValueError, TypeError, KeyError):
            continue
    if not has_existing_grant_proof:
        raise BumpError("no_current_existing_wildcard_profile_grant_proof")
    if not matching_profile:
        scoped = ExistingWildcardProfileAPI(underlying, certificate["id"], device["id"], registration)
        created = scoped.request("POST", "/v1/profiles", {"data": {"type": "profiles", "attributes": {
            "name": "BumpLocationDebug-ExistingWildcard-AdHoc", "profileType": "IOS_APP_ADHOC"},
            "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": bundle_id}},
                "certificates": {"data": [{"type": "certificates", "id": certificate["id"]}]},
                "devices": {"data": [{"type": "devices", "id": device["id"]}]}}}})["data"]
        if not created.get("attributes", {}).get("profileContent"):
            created = scoped.request("GET", "/v1/profiles/" + resource_id(created.get("id")))["data"]
        existing_wildcard_proof(module, registration, created, team, udid)
        compatibility = module.probe_profile_compatibility(created, der, team, udid)
        if compatibility["application_identifier_kind"] != "wildcard" or set(compatibility["compatible_scoped_identifiers"]) != expected_identifiers:
            raise BumpError("created_existing_wildcard_profile_scope_mismatch")
    output = Path("bump-public")
    output.mkdir(exist_ok=True)
    (output / "signing-public-key.pem").write_bytes(module.run(["openssl", "x509", "-inform", "DER", "-pubkey", "-noout"], der))
    receipt = {"source_commit": os.environ["GITHUB_SHA"], "input_certificate_sha256": hashlib.sha256(der).hexdigest(),
        "signing_certificate_sha256": hashlib.sha256(der).hexdigest(), "signing_identity_role": "existing_primary",
        "profile_selection": "existing_wildcard_registration_profile", "validated_bundle_coverage": len(SUFFIXES),
        "registered_device_count": 1, "created_bundle_count": 0, "created_profile_count": 0 if matching_profile else 1,
        "reused_profile_count": 1 if matching_profile else 0, "existing_bundle_registration_unchanged": True,
        "apple_resources_created_or_modified": not matching_profile, "signed_ipa_created": False}
    (output / "readiness.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print("Existing wildcard registration validated. Created Ad Hoc profiles: " + str(receipt["created_profile_count"]) +
        "; reused profiles: " + str(receipt["reused_profile_count"]) + ". No bundle, certificate, device or capability changes.")
    return receipt


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


def sign_package(module, root, payload, identity, original_keys, package_receipt):
    app = payload / "Payload/Location.app"
    bundles = validate_bundles(app)
    mappings = {info["CFBundleIdentifier"]: identifier for _, info, identifier in bundles}
    targets, removed, keychain_groups = [], {}, {}
    for index, (bundle, info, identifier) in enumerate(bundles):
        old = info["CFBundleIdentifier"]
        raw, profile = identity["profiles"][identifier]
        entitlements, shared_keychain = bundle_entitlements(module, profile, identifier)
        keychain_groups[identifier] = shared_keychain
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
    der = identity["der"]
    fingerprint = hashlib.sha1(der).hexdigest().upper()
    keychain = root / "signing.keychain-db"
    with module.signing_keychain_scope(keychain, secrets.token_urlsafe(32), identity["p12"], os.environ[identity["password_env"]], fingerprint):
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
        "profile_selection": identity["profile_selection"], "apple_resources_created_or_modified": False,
        "signing_identity_role": identity["identity_role"],
        "signature_verification": "codesign deep strict passed; nine bundles matched exact concrete entitlements and approved certificate",
        "original_entitlement_keys_not_granted": removed, "package_receipt": package_receipt,
        "device_installation": "not tested", "device_launch": "not tested", "scratch_behavior": "not tested",
        "location_injection": "implemented; software-simulated CLLocation; real-device execution not tested",
        "keychain_configuration": "KEYCHAIN_SHARED_GROUP mapped only to profile-granted app-owned keychain groups",
        "common_keychain_group_across_extensions": len(set(keychain_groups.values())) == 1,
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
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--prepare", action="store_true", help="Read-only signing readiness and public encryption key")
    modes.add_argument("--prepare-profiles", action="store_true", help="Create/reuse only the nine scoped Bump registrations and Ad Hoc profiles")
    modes.add_argument("--inventory-existing", action="store_true", help="Read-only encrypted inventory of existing profiles, independent of the Bump namespace")
    modes.add_argument("--prepare-existing-wildcard", action="store_true", help="Reuse an existing wildcard registration and create at most one scoped Ad Hoc profile")
    options = parser.parse_args(argv)
    validate_ci_scope(os.environ.get("GITHUB_REPOSITORY"), os.environ.get("GITHUB_REF"), os.environ.get("GITHUB_SHA"))
    STAGE = "helper_validation"
    module = load_signer()
    module.configure_openssl()
    module.helper = module.load_helper()
    with tempfile.TemporaryDirectory(prefix="bump-signing-", dir=os.environ["RUNNER_TEMP"]) as directory:
        root = Path(directory)
        if options.inventory_existing:
            STAGE = "read_only_existing_profile_inventory"
            inventory_existing(module, root)
            return
        if options.prepare_existing_wildcard:
            STAGE = "existing_wildcard_profile_preparation"
            prepare_existing_wildcard(module, root)
            return
        STAGE = "identity_and_existing_profiles"
        preparing = options.prepare or options.prepare_profiles
        identity = prepare_identity(module, root, not preparing, create_profiles=options.prepare_profiles)
        for suffix in SUFFIXES:
            identifier = ROOT_ID + suffix
            bundle_entitlements(module, identity["profiles"][identifier][1], identifier)
        if preparing:
            output = Path("bump-public")
            output.mkdir(exist_ok=True)
            public_key = module.run(["openssl", "x509", "-inform", "DER", "-pubkey", "-noout"], identity["primary_der"])
            (output / "signing-public-key.pem").write_bytes(public_key)
            changes = identity["statistics"]
            readiness = {"input_certificate_sha256": hashlib.sha256(identity["primary_der"]).hexdigest(),
                "signing_certificate_sha256": hashlib.sha256(identity["der"]).hexdigest(),
                "validated_bundle_coverage": len(SUFFIXES), "registered_device_count": 1,
                "signing_identity_role": identity["identity_role"], "profile_selection": identity["profile_selection"],
                "source_commit": os.environ["GITHUB_SHA"], "apple_resources_created_or_modified": bool(changes["created_bundle_count"] or changes["created_profile_count"]),
                **changes,
                "signed_ipa_created": False}
            (output / "readiness.json").write_text(json.dumps(readiness, indent=2) + "\n")
            print("Bump signing readiness passed for nine bundles; published public key only. Created registrations: " + str(changes["created_bundle_count"]) + "; created profiles: " + str(changes["created_profile_count"]) + ". No signing performed.")
            return
        STAGE = "authenticated_input"
        envelope_path = Path("bump-signing-input.json")
        if envelope_path.stat().st_size > 100000:
            raise BumpError("encrypted_input_too_large")
        payload = decrypt_envelope(json.loads(envelope_path.read_text()), identity["key"].read_bytes())
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
        verification = sign_package(module, root, payload_root, identity, original_keys, package_receipt)
        print("Bump signed IPA verified and recipient-encrypted. SHA256: " + verification["sha256"])
        print("Device installation, launch and scratch behavior were not tested. No Apple resources were changed.")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # Do not print arbitrary exception contents; they can contain URLs or private inputs.
        print("Bump signing failed stage=" + STAGE + " reason=" + safe_failure(error), file=sys.stderr)
        sys.exit(1)
