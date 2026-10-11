#!/usr/bin/env python3
"""One-shot encrypted registration of this client's fixed provisioning Secret."""
from __future__ import annotations

import argparse
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import subprocess
import sys
import tarfile
import time
import urllib.error
import urllib.parse
import urllib.request

from profile_secret_validation import ProfileValidationError, validate_profile


REPOSITORY = "444yttt/Y3POSClient"
REPOSITORY_ID = 1414170689
OWNER_ID = 267067583
BUNDLE_ID = "com.ayato.y3posclient"
SECRET_NAME = "BUILD_PROVISION_PROFILE_BASE64"
PARENT_WORKFLOW = ".github/workflows/profile-secret.yml"
REPLY_WORKFLOW = ".github/workflows/profile-secret-reply.yml"
APP_ID = 15368
MAX_ENCODED = 48_000
MAX_CIPHERTEXT = 36_000
MAX_PROFILE_ENCODED = 32_000
BOUND_FIELDS = ("protocol", "repository", "repository_id", "parent_run_id", "parent_run_attempt",
                "source_sha", "recipient", "handoff_nonce", "expires_at", "reply_workflow",
                "bundle_identifier", "secret_name")
NO_REDIRECT = urllib.request.build_opener(type("NoRedirect", (urllib.request.HTTPRedirectHandler,), {
    "redirect_request": lambda *args, **kwargs: None})())


class BridgeError(Exception):
    pass


class PendingReply(Exception):
    pass


def require(condition, message):
    if not condition:
        raise BridgeError(message)


def state_path():
    runner = Path(os.environ.get("RUNNER_TEMP", ""))
    require(runner.is_absolute() and runner.is_dir(), "An absolute hosted-runner temporary directory is required.")
    return runner / "y3pos-profile-secret-bridge"


def cleanup():
    state = state_path()
    if state.is_symlink():
        state.unlink()
    elif state.exists():
        shutil.rmtree(state)


def protected_write(path, content):
    require(not path.exists() and not path.is_symlink(), "A protected temporary output already exists.")
    with path.open("xb") as destination:
        destination.write(content if isinstance(content, bytes) else content.encode())
    path.chmod(0o600)


def native(command, data=None, env=None, timeout=45):
    try:
        result = subprocess.run(command, input=data, env=env, capture_output=True, timeout=timeout, check=False)
    except (OSError, subprocess.TimeoutExpired):
        raise BridgeError("A required private transport operation could not run.") from None
    require(result.returncode == 0, "A required private transport operation failed; private output was withheld.")
    return result.stdout


def api(path, token, method="GET", body=None, with_headers=False):
    require(path.startswith("/") and not path.startswith("//"), "The canonical GitHub API path is invalid.")
    request = urllib.request.Request("https://api.github.com" + path, method=method,
        data=None if body is None else json.dumps(body).encode(), headers={
            "Authorization": "Bearer " + token, "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28", "Content-Type": "application/json"})
    try:
        with NO_REDIRECT.open(request, timeout=30) as response:
            data = response.read(1024 * 1024 + 1)
            require(len(data) <= 1024 * 1024, "A canonical GitHub response exceeded its size bound.")
            value = json.loads(data) if data else None
            return (value, response.headers) if with_headers else value
    except urllib.error.HTTPError as error:
        raise BridgeError(f"Canonical GitHub API access failed (HTTP {error.code}); no private response was logged.") from None
    except (urllib.error.URLError, TimeoutError, ValueError):
        raise BridgeError("The canonical GitHub API request could not be completed.") from None


def check_token():
    token = os.environ.get("Y3_PROFILE_CHECK_TOKEN", "")
    require(bool(token), "The step requires its bounded GitHub Checks credential.")
    return token


def guard():
    require(os.environ.get("GITHUB_REPOSITORY") == REPOSITORY
            and os.environ.get("GITHUB_EVENT_NAME") == "workflow_dispatch"
            and os.environ.get("GITHUB_REF") == "refs/heads/main", "Only the approved manual main workflow is permitted.")
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    repo = event.get("repository", {})
    require(repo.get("full_name") == REPOSITORY and repo.get("id") == REPOSITORY_ID
            and repo.get("private") is False and repo.get("owner", {}).get("id") == OWNER_ID,
            "The source must be the approved dedicated public client repository.")
    sha = os.environ.get("GITHUB_SHA", "")
    require(re.fullmatch(r"[0-9a-f]{40}", sha) and os.environ.get("Y3_PROFILE_SOURCE_SHA") == sha,
            "The exact reviewed source SHA must be explicitly pinned.")
    require(native(["git", "rev-parse", "HEAD"]).decode().strip() == sha,
            "The checkout differs from the dispatched source commit.")
    project = Path("Y3Client.xcodeproj/project.pbxproj")
    require(project.is_file() and not project.is_symlink(), "The reviewed client project is missing.")
    bundles = re.findall(r"\bPRODUCT_BUNDLE_IDENTIFIER\s*=\s*([^;]+);", project.read_text())
    require(len(bundles) == 2 and all(value.strip().strip('"') == BUNDLE_ID for value in bundles),
            "The project bundle identifier differs from the approved client.")


def verify_run(run, workflow, run_id, attempt, sha, active=False):
    require(isinstance(run, dict) and str(run.get("id")) == run_id
            and run.get("path") == workflow and run.get("head_sha") == sha
            and run.get("head_branch") == "main" and run.get("event") == "workflow_dispatch"
            and str(run.get("run_attempt")) == attempt
            and run.get("repository", {}).get("id") == REPOSITORY_ID
            and run.get("repository", {}).get("full_name") == REPOSITORY
            and run.get("actor", {}).get("login") == "444yttt" and run.get("actor", {}).get("id") == OWNER_ID,
            "The native workflow provenance does not match the exact owner-approved run.")
    if active:
        require(run.get("status") == "in_progress", "The parent authorization run is no longer active.")


def tools(state):
    spec = importlib.util.spec_from_file_location("y3_metadata_age", Path(__file__).with_name("ci-signing-metadata.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    try:
        binary = module.age_binary(state.parent, state)
        archive = state.parent / "y3pos-age" / module.AGE_VERSION / module.AGE_PLATFORM / "age.tar.gz"
        require(module.archive_matches(archive), "The age archive failed its pinned digest.")
        keygen = state / "age-keygen"
        with tarfile.open(archive, "r:gz") as source:
            member = source.getmember("age/age-keygen")
            require(member.isfile() and 0 < member.size <= 64 * 1024 * 1024, "The pinned age key generator is invalid.")
            content = source.extractfile(member)
            require(content is not None, "The pinned archive has no age key generator.")
            with content, keygen.open("xb") as destination:
                shutil.copyfileobj(content, destination)
        keygen.chmod(0o700)
        return binary, keygen
    except module.MetadataError:
        raise BridgeError("The pinned official age transport could not be prepared.") from None


def create_check(name, title, encrypted, token):
    require(isinstance(encrypted, bytes) and 0 < len(encrypted) <= MAX_CIPHERTEXT
            and encrypted.startswith(b"age-encryption.org/v1\n"), "Only bounded age ciphertext may enter a Check.")
    encoded = base64.b64encode(encrypted).decode("ascii")
    require(len(encoded) <= MAX_ENCODED, "The encrypted Check summary exceeds its size bound.")
    run, attempt = os.environ["GITHUB_RUN_ID"], os.environ["GITHUB_RUN_ATTEMPT"]
    api(f"/repos/{REPOSITORY}/check-runs", token, "POST", {
        "name": name, "head_sha": os.environ["GITHUB_SHA"], "status": "completed", "conclusion": "neutral",
        "completed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "details_url": f"https://github.com/{REPOSITORY}/actions/runs/{run}/attempts/{attempt}",
        "output": {"title": title, "summary": encoded}})


def request_challenge():
    guard()
    token = check_token()
    run_id, attempt, sha = os.environ["GITHUB_RUN_ID"], os.environ["GITHUB_RUN_ATTEMPT"], os.environ["GITHUB_SHA"]
    verify_run(api(f"/repos/{REPOSITORY}/actions/runs/{run_id}", token), PARENT_WORKFLOW, run_id, attempt, sha, active=True)
    state = state_path()
    require(not state.exists() and not state.is_symlink(), "One-time transport state already exists.")
    state.mkdir(mode=0o700)
    binary, keygen = tools(state)
    recipient_file = Path("delivery-recipient.txt")
    require(recipient_file.is_file() and not recipient_file.is_symlink() and recipient_file.stat().st_size <= 256,
            "The committed delivery public key is missing or invalid.")
    recipient = recipient_file.read_text(encoding="ascii").strip()
    require(re.fullmatch(r"age1[qpzry9x8gf2tvdw0s3jn54khce6mua7l]{58}", recipient), "The committed public recipient is invalid.")
    identity = state / "transport-identity.txt"
    native([str(keygen), "--output", str(identity)])
    identity.chmod(0o600)
    ephemeral = native([str(keygen), "-y", str(identity)]).decode().strip()
    require(re.fullmatch(r"age1[qpzry9x8gf2tvdw0s3jn54khce6mua7l]{58}", ephemeral), "The ephemeral public recipient is invalid.")
    transport = {"protocol": "y3-profile-secret-v1", "repository": REPOSITORY, "repository_id": REPOSITORY_ID,
                 "parent_run_id": run_id, "parent_run_attempt": attempt, "source_sha": sha,
                 "recipient": ephemeral, "handoff_nonce": secrets.token_urlsafe(32), "expires_at": int(time.time()) + 600,
                 "reply_workflow": REPLY_WORKFLOW, "bundle_identifier": BUNDLE_ID, "secret_name": SECRET_NAME}
    protected_write(state / "transport-state.json", json.dumps(transport))
    encrypted = native([str(binary), "--encrypt", "--recipient", recipient], json.dumps(transport).encode())
    create_check("Y3 encrypted profile challenge " + run_id + "-" + attempt,
                 "Encrypted profile challenge for the exact run and attempt", encrypted, token)
    print("The encrypted one-time profile challenge is ready in its native GitHub Check.")


def decode_ciphertext(encoded):
    require(isinstance(encoded, str) and 0 < len(encoded) <= MAX_ENCODED, "The encrypted reply exceeds its size bound.")
    try:
        ciphertext = base64.b64decode(encoded, validate=True)
    except ValueError:
        raise BridgeError("The reply input must be Base64 age ciphertext.") from None
    require(0 < len(ciphertext) <= MAX_CIPHERTEXT and ciphertext.startswith(b"age-encryption.org/v1\n"),
            "The reply input must contain bounded age ciphertext only.")
    return ciphertext


def publish_reply():
    guard()
    token = check_token()
    parent_id, parent_attempt = os.environ.get("Y3_PROFILE_PARENT_RUN", ""), os.environ.get("Y3_PROFILE_PARENT_ATTEMPT", "")
    require(re.fullmatch(r"[1-9][0-9]{0,19}", parent_id) and re.fullmatch(r"[1-9][0-9]{0,3}", parent_attempt),
            "The reply must identify an exact parent run and attempt.")
    verify_run(api(f"/repos/{REPOSITORY}/actions/runs/{parent_id}", token), PARENT_WORKFLOW,
               parent_id, parent_attempt, os.environ["GITHUB_SHA"], active=True)
    own_id, own_attempt = os.environ["GITHUB_RUN_ID"], os.environ["GITHUB_RUN_ATTEMPT"]
    verify_run(api(f"/repos/{REPOSITORY}/actions/runs/{own_id}", token), REPLY_WORKFLOW,
               own_id, own_attempt, os.environ["GITHUB_SHA"], active=True)
    ciphertext = decode_ciphertext(os.environ.get("Y3_PROFILE_ENCRYPTED_PAYLOAD", ""))
    create_check("Y3 encrypted profile reply " + parent_id + "-" + parent_attempt,
                 "Y3 profile reply " + own_id + "-" + own_attempt, ciphertext, token)
    print("The ciphertext-only profile reply was published for its exact parent.")


def accept_reply(check, transport, token):
    require(check.get("name") == "Y3 encrypted profile reply " + transport["parent_run_id"] + "-" + transport["parent_run_attempt"]
            and check.get("head_sha") == transport["source_sha"]
            and check.get("app", {}).get("id") == APP_ID and check.get("app", {}).get("slug") == "github-actions"
            and check.get("status") == "completed" and check.get("conclusion") == "neutral",
            "The profile reply Check does not match the approved GitHub Actions producer.")
    match = re.fullmatch(r"Y3 profile reply ([1-9][0-9]*)-([1-9][0-9]*)", check.get("output", {}).get("title", ""))
    require(match, "The profile reply must identify its native publisher run and attempt.")
    child_id, child_attempt = match.groups()
    require(check.get("details_url") in (
        f"https://github.com/{REPOSITORY}/actions/runs/{child_id}/attempts/{child_attempt}",
        f"https://github.com/{REPOSITORY}/runs/{check.get('id')}"), "The reply Check URL is not canonical.")
    child = api(f"/repos/{REPOSITORY}/actions/runs/{child_id}", token)
    verify_run(child, REPLY_WORKFLOW, child_id, child_attempt, transport["source_sha"])
    parent = api(f"/repos/{REPOSITORY}/actions/runs/{transport['parent_run_id']}", token)
    verify_run(parent, PARENT_WORKFLOW, transport["parent_run_id"], transport["parent_run_attempt"], transport["source_sha"], active=True)
    suite_id = check.get("check_suite", {}).get("id")
    require(isinstance(suite_id, int) and suite_id in (parent.get("check_suite_id"), child.get("check_suite_id")),
            "The reply Check suite is not a recognized parent or publisher suite.")
    suite = api(f"/repos/{REPOSITORY}/check-suites/{suite_id}", token)
    require(suite.get("id") == suite_id and suite.get("head_sha") == transport["source_sha"]
            and suite.get("app", {}).get("id") == APP_ID and suite.get("app", {}).get("slug") == "github-actions"
            and suite.get("repository", {}).get("id") == REPOSITORY_ID
            and suite.get("repository", {}).get("full_name") == REPOSITORY
            and suite.get("repository", {}).get("owner", {}).get("id") == OWNER_ID,
            "The reply Check suite repository, source or producer does not match.")
    if child.get("status") != "completed":
        raise PendingReply()
    require(child.get("conclusion") == "success", "The native reply workflow did not complete successfully.")
    jobs = api(f"/repos/{REPOSITORY}/actions/runs/{child_id}/attempts/{child_attempt}/jobs?per_page=100", token).get("jobs", [])
    publishers = [job for job in jobs if job.get("name") == "publish-ciphertext"]
    if not publishers:
        raise PendingReply()
    require(len(publishers) == 1, "The native reply must have exactly one publisher job.")
    publisher = publishers[0]
    if publisher.get("status") != "completed":
        raise PendingReply()
    require(publisher.get("conclusion") == "success", "The exact native publisher job did not complete successfully.")
    steps = [step for step in publisher.get("steps", []) if step.get("name") == "Publish only the encrypted profile reply"]
    if not steps:
        raise PendingReply()
    require(len(steps) == 1, "The native reply must have exactly one publication step.")
    if steps[0].get("status") != "completed":
        raise PendingReply()
    require(steps[0].get("conclusion") == "success", "The exact native reply publication step did not complete successfully.")
    ciphertext = decode_ciphertext(check.get("output", {}).get("summary", ""))
    state = state_path()
    plaintext = native([str(state / "age"), "--decrypt", "--identity", str(state / "transport-identity.txt")], ciphertext, timeout=15)
    require(0 < len(plaintext) <= 34_000, "The private profile reply exceeded its plaintext size bound.")
    payload = json.loads(plaintext)
    require(isinstance(payload, dict) and all(payload.get(key) == transport[key] for key in BOUND_FIELDS)
            and time.time() < transport["expires_at"], "The decrypted profile reply does not match this unexpired challenge.")
    require(set(payload) == set(BOUND_FIELDS) | {"oauth_token", "profile_base64", "expected_team_identifier", "expected_certificate_sha1", "profile_sha256"},
            "The decrypted profile reply has unexpected fields.")
    return payload


def verify_owner(token):
    require(isinstance(token, str) and re.fullmatch(r"gho_[A-Za-z0-9]{36,}", token),
            "The reply requires the approved owner GitHub CLI OAuth credential.")
    owner, headers = api("/user", token, with_headers=True)
    scopes = set(headers.get("X-OAuth-Scopes", "").replace(" ", "").split(","))
    require(owner.get("login") == "444yttt" and owner.get("id") == OWNER_ID and owner.get("type") == "User"
            and {"repo", "workflow"}.issubset(scopes), "The OAuth owner or approved scopes do not match.")
    repo = api(f"/repos/{REPOSITORY}", token)
    require(repo.get("id") == REPOSITORY_ID and repo.get("full_name") == REPOSITORY and repo.get("private") is False
            and repo.get("owner", {}).get("id") == OWNER_ID, "The destination repository does not match.")
    api(f"/repos/{REPOSITORY}/actions/secrets/public-key", token)


def register(payload):
    token = payload.pop("oauth_token")
    verify_owner(token)
    team = os.environ.pop("APPLE_TEAM_ID", "")
    require(re.fullmatch(r"[A-Z0-9]{10}", team) and payload.get("expected_team_identifier") == team,
            "The payload Team does not match the existing repository signing Team.")
    fingerprint = payload.get("expected_certificate_sha1", "")
    require(isinstance(fingerprint, str) and re.fullmatch(r"[A-F0-9]{40}", fingerprint), "The expected certificate fingerprint is invalid.")
    encoded = payload.pop("profile_base64", "")
    require(isinstance(encoded, str) and 0 < len(encoded) <= MAX_PROFILE_ENCODED,
            "The profile Base64 exceeds its approved size bound.")
    profile = base64.b64decode(encoded, validate=True)
    expected_hash = payload.get("profile_sha256", "")
    require(isinstance(expected_hash, str) and re.fullmatch(r"[a-f0-9]{64}", expected_hash)
            and hashlib.sha256(profile).hexdigest() == expected_hash, "The supplied profile bytes differ from the approved download.")
    p12 = base64.b64decode("".join(os.environ.pop("BUILD_CERTIFICATE_BASE64", "").split()), validate=True)
    password = os.environ.pop("P12_PASSWORD", "")
    require(bool(password) and 0 < len(p12) <= 16 * 1024 * 1024, "The existing P12 credentials are unavailable or invalid.")
    validate_profile(profile, p12, password, team, BUNDLE_ID, fingerprint)
    environment = dict(os.environ)
    for name in ("GITHUB_TOKEN", "GH_TOKEN", "GH_DEBUG", "GH_API_DEBUG", "Y3_PROFILE_CHECK_TOKEN"):
        environment.pop(name, None)
    configuration = state_path() / "owner-cli"
    configuration.mkdir(mode=0o700)
    environment.update(GH_TOKEN=token, GH_HOST="github.com", GH_CONFIG_DIR=str(configuration))
    # gh performs the destination-public-key sealed-box encryption internally.
    # The fixed Secret's plaintext enters only stdin; owner OAuth is only env.
    native(["gh", "secret", "set", SECRET_NAME, "--repo", REPOSITORY], encoded.encode(), env=environment)
    secret = api(f"/repos/{REPOSITORY}/actions/secrets/{SECRET_NAME}", token)
    require(secret.get("name") == SECRET_NAME, "GitHub did not confirm the fixed profile Secret registration.")
    print("The dedicated client profile was validated and only BUILD_PROVISION_PROFILE_BASE64 was registered.")


def wait_and_register():
    guard()
    state = state_path()
    manifest = state / "transport-state.json"
    require(manifest.is_file() and not manifest.is_symlink() and not manifest.stat().st_mode & 0o077,
            "The protected one-time challenge state is unavailable.")
    transport = json.loads(manifest.read_text())
    require(transport.get("source_sha") == os.environ["GITHUB_SHA"]
            and transport.get("parent_run_id") == os.environ["GITHUB_RUN_ID"]
            and transport.get("parent_run_attempt") == os.environ["GITHUB_RUN_ATTEMPT"],
            "The protected challenge state does not belong to this exact run.")
    token = check_token()
    name = "Y3 encrypted profile reply " + transport["parent_run_id"] + "-" + transport["parent_run_attempt"]
    query = urllib.parse.urlencode({"check_name": name, "per_page": 100})
    while time.time() < transport["expires_at"]:
        checks = api(f"/repos/{REPOSITORY}/commits/{transport['source_sha']}/check-runs?{query}", token).get("check_runs", [])
        matches = [check for check in checks if check.get("name") == name]
        require(len(matches) <= 1, "Multiple profile reply Checks target the same one-time challenge.")
        if matches:
            try:
                payload = accept_reply(matches[0], transport, token)
            except PendingReply:
                pass
            else:
                register(payload)
                return
        time.sleep(5)
    raise BridgeError("The one-time profile challenge expired without an authenticated completed reply.")


def interrupted(_signal, _frame):
    raise BridgeError("The one-time profile registration was interrupted.")


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("request", "publish-reply", "register", "cleanup"))
    args = parser.parse_args()
    for number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, interrupted)
    try:
        if args.mode == "request":
            request_challenge()
        elif args.mode == "publish-reply":
            publish_reply()
        elif args.mode == "register":
            try:
                wait_and_register()
            finally:
                cleanup()
        else:
            cleanup()
    except (BridgeError, ProfileValidationError, OSError, ValueError, KeyError, TypeError, tarfile.TarError):
        error = sys.exc_info()[1]
        message = str(error) if isinstance(error, (BridgeError, ProfileValidationError)) else "A protected input or transport structure could not be processed."
        print("Profile Secret registration failed: " + message, file=sys.stderr)
        try:
            cleanup()
        except (BridgeError, OSError):
            print("Protected temporary cleanup could not complete.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
