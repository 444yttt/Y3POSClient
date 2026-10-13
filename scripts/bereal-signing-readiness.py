#!/usr/bin/env python3
"""Read-only signing readiness check; secret values and device identifiers never enter logs."""
import base64
import hashlib
import importlib.util
import os
from pathlib import Path
import re
import ssl
import subprocess
import sys
import tempfile

spec = importlib.util.spec_from_file_location("existing_profile_helper", Path(__file__).with_name("prepare-ci-profile.py"))
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)

def main():
    required = ["BUILD_CERTIFICATE_BASE64", "P12_PASSWORD", "APPLE_TEAM_ID", "ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_PRIVATE_KEY"]
    missing = [name for name in required if not os.environ.get(name)]
    if missing:
        print("Missing configured signing assets: " + ", ".join(missing))
        return 1
    with tempfile.TemporaryDirectory(prefix="bereal-signing-probe-", dir=os.environ.get("RUNNER_TEMP")) as folder:
        root = Path(folder)
        p12 = root / "identity.p12"
        p12.write_bytes(base64.b64decode("".join(os.environ["BUILD_CERTIFICATE_BASE64"].split()), validate=True))
        p12.chmod(0o600)
        key = root / "AuthKey.p8"
        key.write_text(os.environ["ASC_PRIVATE_KEY"].replace("\\n", "\n").strip() + "\n")
        key.chmod(0o600)
        arguments = ["openssl", "pkcs12", "-in", str(p12), "-passin", "env:P12_PASSWORD", "-clcerts", "-nokeys"]
        decoded = subprocess.run(arguments, capture_output=True)
        if decoded.returncode:
            decoded = subprocess.run(arguments + ["-legacy"], capture_output=True)
        if decoded.returncode:
            print("Existing certificate could not be decoded with its configured password.")
            return 1
        certificates = re.findall(br"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", decoded.stdout, re.S)
        if len(certificates) != 1:
            print("Expected exactly one signing certificate in the existing P12.")
            return 1
        der = ssl.PEM_cert_to_DER_cert(certificates[0].decode())
        token = helper.make_jwt(os.environ["ASC_KEY_ID"], os.environ["ASC_ISSUER_ID"], key)
        api = helper.AppleAPI(token)
        match = None
        for certificate in api.collection("/v1/certificates"):
            attrs = certificate.get("attributes", {})
            content = attrs.get("certificateContent")
            if content and hashlib.sha256(helper.decode_base64(content)).digest() == hashlib.sha256(der).digest():
                if attrs.get("certificateType") not in ("IOS_DISTRIBUTION", "DISTRIBUTION") or not helper.is_future(attrs.get("expirationDate")):
                    print("Existing signing certificate is not an unexpired iOS distribution certificate.")
                    return 1
                match = certificate
        if match is None:
            print("Existing certificate is unavailable in the configured Apple team.")
            return 1
        print("Existing distribution certificate validated against Apple.")
        devices = api.collection("/v1/devices", {"filter[platform]": "IOS", "filter[status]": "ENABLED"})
        print("Enabled registered iOS device count: " + str(len(devices)))
        bundles = api.collection("/v1/bundleIds", {"filter[platform]": "IOS", "filter[identifier]": "com.ayato.bereal493"})
        print("Dedicated bundle registration exists: " + str(bool(bundles)))
        if not devices:
            print("A device UDID must be registered before an installable Ad Hoc profile can be created.")
            return 1
        print("Signing identity and device access are ready for Ad Hoc provisioning.")
        return 0

if __name__ == "__main__":
    try:
        sys.exit(main())
    except helper.SigningError as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
    except Exception:
        print("Signing readiness check failed; private diagnostics were not emitted.", file=sys.stderr)
        sys.exit(1)
