#!/usr/bin/env python3
"""GET-only Apple access/profile diagnostics; publish counters, never identities.

This does not broaden the signing policy or create any Apple resource. A profile
with extra registered devices is reported separately from an exact-device-only
profile so that a previous strict rejection can be explained without silently
changing the production signer.
"""
import base64
import collections
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import ssl
import tempfile
import urllib.parse
import uuid


def load_signer():
    spec = importlib.util.spec_from_file_location(
        "bereal_signer", Path(__file__).with_name("bereal-resign.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ReadOnlyAPI:
    """Enforce GET even if a subsequently changed imported helper is used."""
    def __init__(self, delegate):
        self.delegate = delegate

    def request(self, method, path, body=None):
        if method != "GET" or body is not None:
            raise RuntimeError("Apple resource mutation is disabled in diagnostics")
        return self.delegate.request("GET", path)

    def collection(self, path, filters=None):
        next_url = path + "?" + urllib.parse.urlencode({"limit": "200", **(filters or {})})
        result, seen = [], set()
        while next_url:
            if next_url in seen or len(seen) >= 100:
                raise RuntimeError("Invalid Apple collection pagination")
            seen.add(next_url)
            response = self.request("GET", next_url)
            if not isinstance(response.get("data"), list):
                raise RuntimeError("Invalid Apple collection response")
            result.extend(response["data"])
            next_url = response.get("links", {}).get("next")
        return result


def safe_failure(exc):
    # Do not forward Apple descriptions, paths, names, credentials or IDs.
    message = str(exc)
    status = re.search(r"\(HTTP ([1-5][0-9]{2})\)", message)
    return {"http_status": int(status.group(1)) if status else None,
            "forbidden": bool(status and status.group(1) == "403"),
            "unauthorized": bool(status and status.group(1) == "401")}


def inspect_alternate_certificate(signer, root, api):
    """Read the second authorized CI P12 certificate without exporting its key."""
    encoded = os.environ.get("BEREAL_ALT_CERTIFICATE_BASE64", "")
    alternate_password = os.environ.get("BEREAL_ALT_P12_PASSWORD", "")
    result = {"configured": bool(encoded), "certificate_decode_valid": False,
              "certificate_team_valid": False, "certificate_expiry_valid": False,
              "api_distribution_certificate_validated": False,
              "private_key_exported": False,
              "alternate_password_configured": bool(alternate_password),
              "primary_password_fallback_used": bool(encoded and not alternate_password)}
    if not encoded:
        return None, result
    try:
        p12 = signer.private(root / "alternate-identity.p12", base64.b64decode(
            "".join(encoded.split()), validate=True))
        previous_password = os.environ.get("P12_PASSWORD")
        try:
            # read_pkcs12 uses an environment variable, never a password argument.
            if alternate_password:
                os.environ["P12_PASSWORD"] = alternate_password
            pem = signer.read_pkcs12(p12, ["-clcerts", "-nokeys"])
        finally:
            if previous_password is None:
                os.environ.pop("P12_PASSWORD", None)
            else:
                os.environ["P12_PASSWORD"] = previous_password
        certificates = re.findall(br"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", pem, re.S)
        if len(certificates) != 1:
            raise RuntimeError("Expected one alternate identity certificate")
        der = ssl.PEM_cert_to_DER_cert(certificates[0].decode())
        result["certificate_decode_valid"] = True
        result["certificate_sha256"] = hashlib.sha256(der).hexdigest()
        subject = signer.run(["openssl", "x509", "-inform", "DER", "-noout",
                              "-subject", "-nameopt", "RFC2253"], der).decode()
        result["certificate_team_valid"] = os.environ["APPLE_TEAM_ID"] in re.findall(
            r"(?:^|,)OU=([A-Z0-9]{10})(?=,|$)", re.sub(r"^subject\s*=\s*", "", subject.strip()))
        try:
            signer.run(["openssl", "x509", "-inform", "DER", "-noout", "-checkend", "0"], der)
            result["certificate_expiry_valid"] = True
        except RuntimeError:
            pass
        matches = []
        for certificate in api.collection("/v1/certificates"):
            attributes = certificate.get("attributes", {})
            if not attributes.get("certificateContent"):
                continue
            try:
                matches_identity = signer.helper.decode_base64(attributes["certificateContent"]) == der
            except (ValueError, TypeError):
                continue
            if matches_identity:
                matches.append(certificate)
        result["matching_apple_certificate_count"] = len(matches)
        result["api_distribution_certificate_validated"] = (
            len(matches) == 1
            and matches[0].get("attributes", {}).get("certificateType") in ("IOS_DISTRIBUTION", "DISTRIBUTION")
            and signer.helper.is_future(matches[0].get("attributes", {}).get("expirationDate")))
        valid = all(result[name] for name in ("certificate_decode_valid", "certificate_team_valid",
                    "certificate_expiry_valid", "api_distribution_certificate_validated"))
        return der if valid else None, result
    except Exception as exc:
        result["safe_failure"] = safe_failure(exc)
        return None, result


def profile_analysis(signer, resource, der, team, udid):
    attributes = resource.get("attributes", {})
    raw = signer.helper.decode_base64(attributes.get("profileContent", ""))
    if not raw or len(raw) > 10 * 1024 * 1024:
        raise RuntimeError("Invalid profile content")
    profile = plistlib.loads(signer.run(
        ["openssl", "cms", "-verify", "-inform", "DER", "-noverify"], raw))
    if not isinstance(profile, dict):
        raise RuntimeError("Invalid profile plist")
    grants = profile.get("Entitlements", {})
    if not isinstance(grants, dict):
        raise RuntimeError("Invalid profile entitlements")

    # Determine identity scope first. Never return or print the original grant.
    application_id = grants.get("application-identifier", "")
    identity_valid = isinstance(application_id, str) and "." in application_id
    prefix, identifier_grant = application_id.split(".", 1) if identity_valid else ("", "")
    targets = [signer.ROOT_ID + suffix for suffix in signer.SAFE_SUFFIXES]
    granted_targets = [target for target in targets
                       if signer.apple_identifier_grant_matches(identifier_grant, target)]
    scoped = bool(granted_targets)

    devices = profile.get("ProvisionedDevices", [])
    devices_valid = isinstance(devices, list) and all(isinstance(d, str) for d in devices)
    try:
        canonical_uuid = str(uuid.UUID(profile.get("UUID", "")))
        uuid_matches = attributes.get("uuid", "").lower() == canonical_uuid
    except (ValueError, AttributeError, TypeError):
        uuid_matches = False
    checks = {
        "identity_structure_valid": identity_valid,
        "target_identifier_grant_present": scoped,
        "certificate_matches": der in profile.get("DeveloperCertificates", []),
        "team_matches": (team in profile.get("TeamIdentifier", [])
                         and grants.get("com.apple.developer.team-identifier") == team),
        "application_prefix_matches": bool(prefix and prefix in profile.get("ApplicationIdentifierPrefix", [])),
        "profile_expiry_valid": signer.helper.is_future(profile.get("ExpirationDate")),
        "metadata_expiry_valid": signer.helper.is_future(attributes.get("expirationDate")),
        "current_device_included": devices_valid and udid in devices,
        "only_current_device": devices_valid and devices == [udid],
        "all_devices_provisioning_disabled": not bool(profile.get("ProvisionsAllDevices")),
        "debugging_disabled": grants.get("get-task-allow") is False,
        "uuid_matches_metadata": uuid_matches,
    }
    concrete_targets = []
    for target in granted_targets:
        candidate = plistlib.loads(plistlib.dumps(profile))
        entitlements = candidate["Entitlements"]
        concrete_application_id = prefix + "." + target
        entitlements["application-identifier"] = concrete_application_id
        if "keychain-access-groups" in entitlements:
            keychain_grants = entitlements["keychain-access-groups"]
            if (not isinstance(keychain_grants, list)
                    or not any(signer.apple_identifier_grant_matches(grant, concrete_application_id)
                               for grant in keychain_grants)):
                continue
            entitlements["keychain-access-groups"] = [concrete_application_id]
        try:
            signer.concrete_entitlements(candidate, target)
        except (RuntimeError, KeyError, TypeError, ValueError):
            continue
        concrete_targets.append(target)
    checks["concrete_scoped_entitlements_available"] = bool(concrete_targets)
    standard = all(value for name, value in checks.items()
                   if name not in ("only_current_device", "concrete_scoped_entitlements_available"))
    return {"checks": checks,
            "wildcard_grant": "*" in identifier_grant,
            "grant_targets": granted_targets,
            "concrete_targets": concrete_targets,
            "compatible_with_current_device_included": standard and bool(concrete_targets),
            "compatible_with_current_device_only": standard and bool(concrete_targets) and checks["only_current_device"]}


def diagnose(signer, api, der, device, include_registration_checks=True):
    targets = [signer.ROOT_ID + suffix for suffix in signer.SAFE_SUFFIXES]
    receipt = {
        "mode": "read_only_apple_access_diagnostics", "schema_version": 1,
        "distribution_certificate_validated": True,
        "certificate_sha256": hashlib.sha256(der).hexdigest(),
        "registered_enabled_ios_device_count": 1,
        "apple_resources_created_or_modified": False, "signed_ipa_created": False,
        "post_permission_verified": False,
        "profile_cms_check": "embedded-signature integrity; Apple certificate-chain trust not evaluated by this diagnostic",
        "device_installation": "not tested", "posting": "not tested",
    }
    # Successful GET does not prove permission to POST. Check only the five
    # requested IDs and publish only whether each exact registration exists.
    scoped_bundle_checks = []
    for target in targets if include_registration_checks else []:
        check = {"target_bundle_identifier": target}
        try:
            registrations = api.collection("/v1/bundleIds", {
                "filter[platform]": "IOS", "filter[identifier]": target,
                "fields[bundleIds]": "identifier,platform"})
            check.update(read_allowed=True, exact_registration_count=sum(
                item.get("attributes", {}).get("identifier") == target
                and item.get("attributes", {}).get("platform") == "IOS"
                for item in registrations))
        except Exception as exc:
            check.update(read_allowed=False, failure=safe_failure(exc))
        scoped_bundle_checks.append(check)
    receipt["scoped_bundle_registration_checks"] = scoped_bundle_checks

    resources = api.collection("/v1/profiles", {
        "fields[profiles]": "uuid,profileType,profileState,profileContent,expirationDate"})
    receipt["profile_catalog_read_allowed"] = True
    receipt["catalog_profile_count"] = len(resources)
    distributions = collections.Counter()
    passed, failed, scoped_passed, scoped_failed = [collections.Counter() for _ in range(4)]
    grant_coverage, wildcard_coverage, included_coverage, exact_coverage = [collections.Counter() for _ in range(4)]
    counts = collections.Counter()
    for resource in resources:
        attributes = resource.get("attributes", {})
        distribution = attributes.get("profileType", "")
        if isinstance(distribution, str) and re.fullmatch(r"[A-Z_]{1,60}", distribution):
            distributions[distribution] += 1
        if distribution != "IOS_APP_ADHOC" or attributes.get("profileState") != "ACTIVE":
            continue
        counts["active_ios_adhoc_profile_count"] += 1
        try:
            if not attributes.get("profileContent"):
                resource = api.request("GET", "/v1/profiles/" + resource["id"])["data"]
            result = profile_analysis(signer, resource, der, os.environ["APPLE_TEAM_ID"], device["attributes"]["udid"])
        except Exception:
            # Do not expose untrusted error strings or profile identifiers.
            counts["profile_cms_or_structure_rejection_count"] += 1
            continue
        counts["cms_decoded_profile_count"] += 1
        scoped = result["checks"]["target_identifier_grant_present"]
        counts["scoped_profile_count" if scoped else "unrelated_identifier_profile_count"] += 1
        if result["wildcard_grant"]:
            counts["wildcard_grant_profile_count"] += 1
        for name, value in result["checks"].items():
            (passed if value else failed)[name] += 1
            if scoped:
                (scoped_passed if value else scoped_failed)[name] += 1
        grant_coverage.update(result["grant_targets"])
        if result["wildcard_grant"]:
            wildcard_coverage.update(result["grant_targets"])
        if result["compatible_with_current_device_included"]:
            counts["compatible_current_device_included_profile_count"] += 1
            included_coverage.update(result["concrete_targets"])
        if result["compatible_with_current_device_only"]:
            counts["compatible_current_device_only_profile_count"] += 1
            exact_coverage.update(result["concrete_targets"])
            if result["wildcard_grant"] and len(result["concrete_targets"]) == len(targets):
                counts["compatible_current_device_only_wildcard_all_targets_profile_count"] += 1
    receipt["catalog_distribution_types"] = dict(distributions)
    for name in ("active_ios_adhoc_profile_count", "profile_cms_or_structure_rejection_count",
                 "cms_decoded_profile_count", "scoped_profile_count", "unrelated_identifier_profile_count",
                 "wildcard_grant_profile_count", "compatible_current_device_included_profile_count",
                 "compatible_current_device_only_profile_count",
                 "compatible_current_device_only_wildcard_all_targets_profile_count"):
        receipt[name] = counts[name]
    receipt["decoded_profile_check_pass_counts"] = dict(sorted(passed.items()))
    receipt["decoded_profile_check_failure_counts"] = dict(sorted(failed.items()))
    receipt["scoped_profile_check_pass_counts"] = dict(sorted(scoped_passed.items()))
    receipt["scoped_profile_check_failure_counts"] = dict(sorted(scoped_failed.items()))
    receipt["target_coverage"] = [{
        "target_bundle_identifier": target,
        "identity_grant_profile_count": grant_coverage[target],
        "wildcard_grant_profile_count": wildcard_coverage[target],
        "compatible_current_device_included_profile_count": included_coverage[target],
        "compatible_current_device_only_profile_count": exact_coverage[target],
    } for target in targets]
    receipt["all_targets_covered_with_current_device_included"] = all(included_coverage[t] > 0 for t in targets)
    receipt["all_targets_covered_with_current_device_only"] = all(exact_coverage[t] > 0 for t in targets)
    return receipt


def main():
    if os.environ.get("GITHUB_REPOSITORY") != "444yttt/Y3POSClient" or os.environ.get("GITHUB_REF") != "refs/heads/main":
        raise RuntimeError("Diagnostics may only use authorized Y3POSClient main CI")
    signer = load_signer()
    signer.configure_openssl()
    signer.helper = signer.load_helper()
    with tempfile.TemporaryDirectory(prefix="bereal-read-only-diagnostics-") as temporary:
        _, der, unused_key, asc = signer.decode_identity(Path(temporary), need_private_key=False)
        if unused_key is not None:
            raise RuntimeError("Diagnostic unexpectedly extracted a signing private key")
        api = ReadOnlyAPI(signer.RefreshingAppleAPI(asc))
        _, device = signer.signing_readiness(api, der)
        receipt = diagnose(signer, api, der, device)
        alternate_der, alternate = inspect_alternate_certificate(signer, Path(temporary), api)
        alternate["same_certificate_as_primary"] = (
            alternate.get("certificate_sha256") == hashlib.sha256(der).hexdigest()) if alternate.get("certificate_sha256") else False
        if alternate_der is not None:
            alternate["profile_compatibility"] = diagnose(
                signer, api, alternate_der, device, include_registration_checks=False)
            alternate["fits_existing_wildcard_profile_for_all_five_targets_and_only_current_device"] = (
                alternate["profile_compatibility"]["compatible_current_device_only_wildcard_all_targets_profile_count"] > 0)
        else:
            alternate["fits_existing_wildcard_profile_for_all_five_targets_and_only_current_device"] = False
        receipt["alternate_identity"] = alternate
        receipt["schema_version"] = 2
    output = Path("bereal-public")
    output.mkdir(exist_ok=True)
    (output / "apple-access-diagnostics.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print("Read-only Apple diagnostics completed; current-device coverage: "
          + str(sum(item["compatible_current_device_included_profile_count"] > 0
                    for item in receipt["target_coverage"])) + "/5.")
    print("Published only scoped target identifiers and aggregate checks. No Apple resources were modified.")


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print("Read-only Apple diagnostic could not complete: " + json.dumps(safe_failure(exc), sort_keys=True))
        raise SystemExit(1)
