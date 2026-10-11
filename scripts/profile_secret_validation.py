"""Validate an iOS App Store profile before storing its secret value.

This module never prints. Sensitive inputs and native command output stay in
memory, and no private key is extracted from the supplied PKCS#12 archive.
CMS integrity is checked with the embedded signer certificate; `-noverify`
intentionally does not establish an Apple certificate-chain trust anchor.
"""

from __future__ import annotations

import base64
import datetime as dt
import hashlib
import os
import plistlib
import re
import subprocess
import uuid
from xml.parsers.expat import ExpatError


__all__ = ["ProfileValidationError", "validate_profile"]
MAX_PROFILE_BYTES = 24_000
MAX_PROFILE_BASE64_BYTES = 32_000
MAX_P12_BYTES = 16 * 1024 * 1024
PASSWORD_VARIABLE = "Y3_PROFILE_VALIDATE_P12_PASSWORD"
UTC = dt.timezone.utc
MONTHS = {name: number for number, name in enumerate(
    ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"), 1
)}


class ProfileValidationError(Exception):
    """A fixed-message validation failure that contains no input values."""


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise ProfileValidationError(message)


def _openssl(arguments: list[str], data: bytes, password: str | None = None) -> subprocess.CompletedProcess:
    environment = os.environ.copy()
    environment["LC_ALL"] = "C"
    environment.pop(PASSWORD_VARIABLE, None)
    if password is not None:
        environment[PASSWORD_VARIABLE] = password
    try:
        return subprocess.run(
            ["/usr/bin/openssl", *arguments],
            input=data,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            timeout=20,
            check=False,
        )
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        raise ProfileValidationError("Required cryptographic validation could not run.") from None
    finally:
        environment.pop(PASSWORD_VARIABLE, None)


def _checked(arguments: list[str], data: bytes, message: str) -> bytes:
    result = _openssl(arguments, data)
    _require(result.returncode == 0, message)
    return result.stdout


def _certificate_date(value: str) -> dt.datetime:
    # OpenSSL emits English month names regardless of the Python caller's locale.
    match = re.fullmatch(r"([A-Z][a-z]{2}) +([0-9]{1,2}) ([0-9]{2}):([0-9]{2}):([0-9]{2}) ([0-9]{4}) GMT", value)
    _require(match is not None, "Signing certificate validity is invalid.")
    try:
        month, day, hour, minute, second, year = match.groups()
        return dt.datetime(int(year), MONTHS[month], int(day), int(hour), int(minute), int(second), tzinfo=UTC)
    except (ValueError, KeyError) as error:
        raise ProfileValidationError("Signing certificate validity is invalid.") from None


def _leaf_certificate(p12_bytes: bytes, password: str, expected_team: str, expected_sha1: str, now: dt.datetime) -> bytes:
    arguments = ["pkcs12", "-nokeys", "-clcerts", "-passin", "env:" + PASSWORD_VARIABLE]
    result = _openssl(arguments, p12_bytes, password)
    if result.returncode != 0:
        # OpenSSL 3 needs its legacy provider for older Apple-exported P12 ciphers.
        result = _openssl([*arguments, "-legacy"], p12_bytes, password)
    _require(result.returncode == 0, "PKCS#12 certificate extraction failed.")
    certificates = re.findall(
        rb"-----BEGIN CERTIFICATE-----\s+[A-Za-z0-9+/=\r\n]+-----END CERTIFICATE-----",
        result.stdout,
    )
    _require(
        len(certificates) == 1
        and result.stdout.count(b"-----BEGIN CERTIFICATE-----") == 1
        and result.stdout.count(b"-----END CERTIFICATE-----") == 1,
        "PKCS#12 must contain exactly one client certificate.",
    )
    der = _checked(["x509", "-inform", "PEM", "-outform", "DER"], certificates[0], "Extracted certificate is invalid.")
    _require(0 < len(der) <= 1024 * 1024, "Extracted certificate size is invalid.")
    _require(hashlib.sha1(der).hexdigest().upper() == expected_sha1, "Signing certificate does not match the expected identity.")
    subject = _checked(
        ["x509", "-inform", "DER", "-noout", "-subject", "-nameopt", "sep_multiline,utf8,esc_ctrl,esc_msb"],
        der,
        "Signing certificate subject validation failed.",
    )
    try:
        organizational_units = re.findall(r"^\s*OU\s*=\s*(.*?)\s*$", subject.decode("ascii"), re.MULTILINE)
    except UnicodeError as error:
        raise ProfileValidationError("Signing certificate subject validation failed.") from None
    _require(organizational_units == [expected_team], "Signing certificate belongs to a different or ambiguous Team.")
    constraints = _checked(
        ["x509", "-inform", "DER", "-noout", "-ext", "basicConstraints"],
        der,
        "Signing certificate leaf validation failed.",
    )
    _require(b"CA:TRUE" not in constraints, "Signing certificate is a CA certificate rather than a leaf.")
    if constraints.strip():
        _require(b"CA:FALSE" in constraints, "Signing certificate leaf constraints are invalid.")
    dates = _checked(
        ["x509", "-inform", "DER", "-noout", "-startdate", "-enddate"],
        der,
        "Signing certificate validity inspection failed.",
    )
    try:
        lines = dict(line.split("=", 1) for line in dates.decode("ascii").splitlines())
        _require(set(lines) == {"notBefore", "notAfter"}, "Signing certificate validity is invalid.")
        starts = _certificate_date(lines["notBefore"])
        expires = _certificate_date(lines["notAfter"])
    except (UnicodeError, ValueError, KeyError) as error:
        raise ProfileValidationError("Signing certificate validity is invalid.") from None
    _require(starts <= now < expires, "Signing certificate is not currently valid.")
    return der


def _date(value: object) -> dt.datetime:
    _require(type(value) is dt.datetime, "Provisioning profile dates are invalid.")
    try:
        return value.replace(tzinfo=UTC) if value.tzinfo is None else value.astimezone(UTC)
    except (ValueError, OverflowError) as error:
        raise ProfileValidationError("Provisioning profile dates are invalid.") from None


def _profile_payload(profile_bytes: bytes) -> dict:
    payload = _checked(
        ["cms", "-verify", "-inform", "DER", "-noverify", "-binary"],
        profile_bytes,
        "Provisioning profile CMS signature verification failed.",
    )
    _require(0 < len(payload) <= MAX_PROFILE_BYTES, "Provisioning profile payload size is invalid.")
    try:
        parsed = plistlib.loads(payload)
    except (ValueError, TypeError, OverflowError, RecursionError, plistlib.InvalidFileException, ExpatError) as error:
        raise ProfileValidationError("Provisioning profile payload is not a valid property list.") from None
    _require(type(parsed) is dict, "Provisioning profile payload must be a dictionary.")
    return parsed


def validate_profile(
    profile_bytes: bytes,
    p12_bytes: bytes,
    password: str,
    expected_team: str,
    expected_bundle: str,
    expected_certificate_sha1: str,
) -> dict:
    """Return the validated profile UUID, CMS SHA256, and leaf SHA1.

    These are protected signing identifiers; never log them unencrypted.
    Errors use fixed messages. Sensitive input bytes are not logged, written
    to files, or included in the return value.
    """
    _require(type(profile_bytes) is bytes and 0 < len(profile_bytes) <= MAX_PROFILE_BYTES,
             "Provisioning profile is empty, invalid, or exceeds the secret transport limit.")
    _require(len(base64.b64encode(profile_bytes)) <= MAX_PROFILE_BASE64_BYTES,
             "Provisioning profile exceeds the encoded secret transport limit.")
    _require(type(p12_bytes) is bytes and 0 < len(p12_bytes) <= MAX_P12_BYTES,
             "PKCS#12 input is empty, invalid, or too large.")
    _require(type(password) is str and len(password) <= 8192 and "\x00" not in password,
             "PKCS#12 password input is invalid.")
    _require(type(expected_team) is str and re.fullmatch(r"[A-Z0-9]{10}", expected_team) is not None,
             "Expected Team identifier is invalid.")
    _require(type(expected_bundle) is str and len(expected_bundle) <= 255
             and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9][A-Za-z0-9-]*)+", expected_bundle) is not None,
             "Expected Bundle identifier is invalid.")
    _require(type(expected_certificate_sha1) is str and re.fullmatch(r"[A-Fa-f0-9]{40}", expected_certificate_sha1) is not None,
             "Expected certificate fingerprint is invalid.")
    expected_sha1 = expected_certificate_sha1.upper()
    now = dt.datetime.now(UTC)
    try:
        certificate = _leaf_certificate(p12_bytes, password, expected_team, expected_sha1, now)
        profile = _profile_payload(profile_bytes)
        _require(profile.get("TeamIdentifier") == [expected_team], "Provisioning profile belongs to a different or ambiguous Team.")
        platforms = profile.get("Platform")
        _require(type(platforms) is list and platforms
                 and all(type(platform) is str and platform in {"iOS", "xrOS", "visionOS"} for platform in platforms)
                 and "iOS" in platforms and len(set(platforms)) == len(platforms),
                 "Provisioning profile platform list is invalid or not an iOS-family profile.")
        expiry = _date(profile.get("ExpirationDate"))
        _require(expiry > now, "Provisioning profile has expired.")
        if "CreationDate" in profile:
            created = _date(profile["CreationDate"])
            _require(created <= now + dt.timedelta(minutes=5) and created < expiry, "Provisioning profile creation date is invalid.")
        prefixes = profile.get("ApplicationIdentifierPrefix")
        _require(type(prefixes) is list and len(prefixes) == 1 and type(prefixes[0]) is str
                 and re.fullmatch(r"[A-Za-z0-9]{1,64}", prefixes[0]) is not None,
                 "Provisioning profile application identifier prefix is invalid or ambiguous.")
        entitlements = profile.get("Entitlements")
        _require(type(entitlements) is dict, "Provisioning profile entitlements are missing.")
        _require(entitlements.get("com.apple.developer.team-identifier") == expected_team,
                 "Provisioning profile entitlement Team does not match the expected Team.")
        _require(entitlements.get("application-identifier") == prefixes[0] + "." + expected_bundle,
                 "Provisioning profile does not grant the exact requested application identifier.")
        _require(entitlements.get("get-task-allow") is False, "Provisioning profile allows debugging or has invalid debugging entitlements.")
        _require(entitlements.get("beta-reports-active") is True, "Provisioning profile is not an App Store distribution profile.")
        _require("ProvisionedDevices" not in profile, "Provisioning profile is device-restricted rather than App Store distribution.")
        _require(profile.get("ProvisionsAllDevices", False) is False, "Provisioning profile grants all-device provisioning.")
        certificates = profile.get("DeveloperCertificates")
        _require(type(certificates) is list and certificates and all(type(c) is bytes and c for c in certificates),
                 "Provisioning profile allowed certificates are invalid.")
        _require(certificate in certificates, "Provisioning profile does not allow the exact signing certificate.")
        profile_uuid = profile.get("UUID")
        _require(type(profile_uuid) is str and re.fullmatch(
            r"[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}", profile_uuid
        ) is not None, "Provisioning profile UUID is invalid.")
        canonical_uuid = str(uuid.UUID(profile_uuid)).upper()
        _require(uuid.UUID(canonical_uuid).int != 0, "Provisioning profile UUID is invalid.")
        return {
            "profile_uuid": canonical_uuid,
            "profile_sha256": hashlib.sha256(profile_bytes).hexdigest(),
            "certificate_sha1": expected_sha1,
        }
    except ProfileValidationError:
        raise
    except (ValueError, TypeError, OverflowError, RecursionError, KeyError, AttributeError, OSError) as error:
        raise ProfileValidationError("Provisioning profile validation could not complete.") from None
