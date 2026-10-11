#!/usr/bin/env python3
"""Deliver only encrypted identifying metadata for the existing signing cert."""

from __future__ import annotations

import base64
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile


AGE_VERSION = "1.3.2"
AGE_PLATFORM = "linux-amd64"
AGE_ARCHIVE_SHA256 = "cbe24006683f8eb669266162894b9a522a1af52f2665fbc63a4bb032ed26ac10"
CLIENT_BUNDLE_ID = "com.ayato.y3posclient"
UTC = dt.timezone.utc


class MetadataError(Exception):
    pass


def require(condition: bool, message: str) -> None:
    if not condition:
        raise MetadataError(message)


def run(command: list[str], *, data: bytes | None = None,
        environment: dict[str, str] | None = None, timeout: int = 60) -> bytes:
    try:
        result = subprocess.run(command, input=data, capture_output=True,
                                env=environment, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise MetadataError("A required certificate or encryption tool could not run.") from error
    require(result.returncode == 0, "A certificate or encryption command failed; private tool output was withheld.")
    return result.stdout


def archive_matches(path: Path) -> bool:
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 64 * 1024 * 1024:
        return False
    return hashlib.sha256(path.read_bytes()).hexdigest() == AGE_ARCHIVE_SHA256


def age_binary(runner: Path, task: Path) -> Path:
    require(sys.platform == "linux" and os.uname().machine == "x86_64",
            "This metadata workflow requires the standard Ubuntu amd64 runner.")
    cache = runner / "y3pos-age" / AGE_VERSION / AGE_PLATFORM
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / "age.tar.gz"
    if not archive_matches(archive):
        require(not archive.is_symlink(), "The public age cache must not be a symlink.")
        download = task / "age.tar.gz"
        url = f"https://github.com/FiloSottile/age/releases/download/v{AGE_VERSION}/age-v{AGE_VERSION}-{AGE_PLATFORM}.tar.gz"
        run(["curl", "--fail", "--silent", "--show-error", "--location",
             "--proto", "=https", "--proto-redir", "=https",
             "--connect-timeout", "20", "--max-time", "120", url, "-o", str(download)], timeout=125)
        require(archive_matches(download), "The official age release failed its pinned SHA-256 check.")
        os.replace(download, archive)
    require(archive_matches(archive), "The cached age release failed its pinned SHA-256 check.")
    binary = task / "age"
    with tarfile.open(archive, "r:gz") as source:
        member = source.getmember("age/age")
        require(member.isfile() and 0 < member.size <= 64 * 1024 * 1024,
                "The pinned archive contains an invalid age binary.")
        content = source.extractfile(member)
        require(content is not None, "The pinned archive has no age binary.")
        with content, binary.open("xb") as destination:
            shutil.copyfileobj(content, destination)
    binary.chmod(0o700)
    version = run([str(binary), "--version"]).decode("ascii").strip()
    require(version in (AGE_VERSION, "v" + AGE_VERSION), "The pinned age binary has an unexpected version.")
    return binary


def certificate_metadata(p12: Path, team: str, password: str) -> dict:
    environment = {name: value for name, value in os.environ.items()
                   if name not in ("BUILD_CERTIFICATE_BASE64", "P12_PASSWORD")}
    environment["Y3_METADATA_P12_PASSWORD"] = password
    command = ["openssl", "pkcs12", "-in", str(p12), "-nokeys", "-clcerts",
               "-passin", "env:Y3_METADATA_P12_PASSWORD"]
    try:
        pem = run(command, environment=environment)
    except MetadataError:
        # Existing exports can use older PBE algorithms; no private key is exported.
        pem = run([*command, "-legacy"], environment=environment)
    certificates = re.findall(br"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", pem, re.S)
    require(len(certificates) == 1, "The existing P12 must contain exactly one leaf certificate.")
    certificate = certificates[0]
    der = run(["openssl", "x509", "-inform", "PEM", "-outform", "DER"], data=certificate)
    fields = run(["openssl", "x509", "-inform", "DER", "-noout", "-subject",
                  "-nameopt", "RFC2253", "-serial", "-startdate", "-enddate"], data=der).decode("ascii")
    require(re.search(r"(?:^|[,\s])OU=" + re.escape(team) + r"(?:,|\s|$)", fields) is not None,
            "The existing signing certificate belongs to a different Apple team.")
    values = dict(line.split("=", 1) for line in fields.splitlines() if "=" in line)
    serial = values.get("serial", "").upper()
    require(re.fullmatch(r"[0-9A-F]+", serial) is not None,
            "The existing signing certificate has an invalid serial number.")
    start = dt.datetime.strptime(values["notBefore"], "%b %d %H:%M:%S %Y %Z").replace(tzinfo=UTC)
    expiry = dt.datetime.strptime(values["notAfter"], "%b %d %H:%M:%S %Y %Z").replace(tzinfo=UTC)
    require(start <= dt.datetime.now(UTC) < expiry, "The existing signing certificate is not currently valid.")
    return {
        "metadata_version": 1,
        "bundle_identifier": CLIENT_BUNDLE_ID,
        "team_identifier": team,
        "certificate_sha1": hashlib.sha1(der).hexdigest().upper(),
        "serial_number_hex": serial,
        "not_before_utc": start.isoformat().replace("+00:00", "Z"),
        "expires_at_utc": expiry.isoformat().replace("+00:00", "Z"),
    }


def main() -> None:
    require(len(sys.argv) == 1, "This CI helper accepts no command-line secrets or options.")
    repository = Path(__file__).resolve().parent.parent
    project = repository / "Y3Client.xcodeproj" / "project.pbxproj"
    require(not project.is_symlink() and project.is_file(), "The reviewed client project is missing or invalid.")
    source_bundles = re.findall(r"\bPRODUCT_BUNDLE_IDENTIFIER\s*=\s*([^;]+);", project.read_text(encoding="utf-8"))
    require(len(source_bundles) == 2 and all(value.strip().strip('"') == CLIENT_BUNDLE_ID for value in source_bundles),
            "The checked-out client does not have the approved bundle identifier in both configurations.")
    runner = Path(os.environ.get("RUNNER_TEMP", ""))
    require(runner.is_absolute() and runner.is_dir(), "RUNNER_TEMP must be an existing absolute temporary directory.")
    for name in ("BUILD_CERTIFICATE_BASE64", "P12_PASSWORD", "APPLE_TEAM_ID"):
        require(bool(os.environ.get(name)), "Required Actions Secret is unavailable: " + name + ".")
    team = os.environ["APPLE_TEAM_ID"]
    require(re.fullmatch(r"[A-Z0-9]{10}", team) is not None, "APPLE_TEAM_ID is invalid.")
    recipient_path = Path(os.environ.get("DELIVERY_RECIPIENT_FILE", "delivery-recipient.txt"))
    require(recipient_path.resolve() == repository / "delivery-recipient.txt"
            and not recipient_path.is_symlink() and recipient_path.is_file() and recipient_path.stat().st_size <= 256,
            "The delivery recipient must be a small regular public-key file.")
    recipient = recipient_path.read_text(encoding="ascii").strip()
    require(re.fullmatch(r"age1[qpzry9x8gf2tvdw0s3jn54khce6mua7l]{58}", recipient) is not None,
            "The delivery recipient must be one public age key.")
    encoded = os.environ.pop("BUILD_CERTIFICATE_BASE64")
    password = os.environ.pop("P12_PASSWORD")
    try:
        p12_bytes = base64.b64decode("".join(encoded.split()), validate=True)
    except ValueError as error:
        raise MetadataError("The P12 Secret has invalid Base64 encoding.") from error
    require(0 < len(p12_bytes) <= 16 * 1024 * 1024, "The P12 Secret has an invalid size.")
    with tempfile.TemporaryDirectory(prefix="y3pos-signing-metadata-", dir=runner) as temporary:
        task = Path(temporary)
        p12 = task / "certificate.p12"
        p12.write_bytes(p12_bytes)
        p12.chmod(0o600)
        metadata = certificate_metadata(p12, team, password)
        p12.unlink()
        password = ""
        p12_bytes = b""
        encoded = ""
        plaintext = task / "signing-metadata.json"
        plaintext.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
        plaintext.chmod(0o600)
        binary = age_binary(runner, task)
        ciphertext = task / "signing-metadata.json.age"
        run([str(binary), "--encrypt", "--recipient", recipient, "--output", str(ciphertext), str(plaintext)])
        require(ciphertext.is_file() and ciphertext.stat().st_size > 22,
                "Encrypted signing metadata was not produced.")
        with ciphertext.open("rb") as source:
            require(source.read(22) == b"age-encryption.org/v1\n", "Encrypted signing metadata has an invalid age header.")
        output = runner / "y3pos-metadata-encrypted-delivery"
        require(not output.is_symlink(), "The encrypted metadata output directory must not be a symlink.")
        output.mkdir(exist_ok=True)
        destination = output / "signing-metadata.json.age"
        os.link(ciphertext, destination)  # A pre-existing output is never replaced.
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output_file:
            output_file.write(f"encrypted_path={destination}\n")
    print("Existing signing certificate metadata encrypted for the recipient.")


def interrupted(_signal: int, _frame: object) -> None:
    raise MetadataError("Signing metadata delivery was interrupted.")


if __name__ == "__main__":
    os.umask(0o077)
    for interrupt in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(interrupt, interrupted)
    try:
        main()
    except (MetadataError, OSError, ValueError, KeyError, UnicodeError, tarfile.TarError):
        # Do not expose native stderr, certificate names, or Secret contents.
        error = sys.exc_info()[1]
        message = str(error) if isinstance(error, MetadataError) else "A private metadata file or certificate structure could not be processed."
        print("Signing metadata delivery failed: " + message, file=sys.stderr)
        sys.exit(1)
