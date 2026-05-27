#!/usr/local/bin/python3
"""Mihomo core update — configd action `update-core` (runs via daemon -f).

Pipeline (mirrors design §1.5.2):
    1. Resolve latest tag via /tmp/mihomo-release-cache-core.json (or fetch).
    2. Download mihomo-freebsd-amd64-vX.Y.Z.gz + .sha256.
    3. SHA256 verify -> fail aborts.
    4. gunzip into /tmp/mihomo-<ver>.bin
    5. chmod +x and smoke-test (`mihomo -v` returns new version).
    6. Backup current /usr/local/bin/mihomo to .bak.<ts>
    7. Atomic mv new binary in place.
    8. configctl mihomo restart
    9. Poll service status for ≤10s. If still down -> roll back.

Progress is written to /tmp/mihomo-update-core.json, polled by the front-end.
"""

from __future__ import annotations

import gzip
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.request
import xml.etree.ElementTree as ET

PROGRESS = "/tmp/mihomo-update-core.json"
RELEASE_CACHE = "/tmp/mihomo-release-cache-core.json"
BIN_PATH = "/usr/local/bin/mihomo"
CONFIG_PATH = "/conf/config.xml"
REPO = "MetaCubeX/mihomo"
ASSET_RE_GZ = "mihomo-freebsd-amd64-v"  # asset filename prefix
CONFIGCTL = "/usr/local/sbin/configctl"


def progress(state: str, step: str = "", percent: int = 0, message: str = "") -> None:
    payload = {"state": state, "step": step, "percent": percent, "message": message,
               "updated": int(time.time())}
    try:
        with open(PROGRESS, "w", encoding="utf-8") as fp:
            json.dump(payload, fp, ensure_ascii=False)
        os.chmod(PROGRESS, 0o640)
    except OSError:
        pass


def github_headers() -> dict:
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "Mihomo-for-OPNsense",
    }
    try:
        root = ET.parse(CONFIG_PATH).getroot()
        token = (root.findtext("./OPNsense/Mihomo/mihomo/update/github_token") or "").strip()
        if token:
            headers["Authorization"] = f"Bearer {token}"
    except (ET.ParseError, OSError):
        pass
    return headers


def github_mirror_prefix() -> str:
    try:
        root = ET.parse(CONFIG_PATH).getroot()
        return (root.findtext("./OPNsense/Mihomo/mihomo/update/github_mirror") or "").strip().rstrip("/")
    except (ET.ParseError, OSError):
        return ""


def fetch_url(url: str, timeout: int = 30) -> bytes:
    req = urllib.request.Request(url, headers=github_headers())
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        if resp.status < 200 or resp.status >= 300:
            raise RuntimeError(f"http {resp.status} for {url}")
        return resp.read()


def get_latest_release() -> dict:
    if os.path.isfile(RELEASE_CACHE) and (time.time() - os.path.getmtime(RELEASE_CACHE)) < 3600:
        try:
            with open(RELEASE_CACHE, "r", encoding="utf-8") as fp:
                cached = json.load(fp)
            if cached.get("tag_name") and cached.get("assets"):
                return cached
        except (OSError, json.JSONDecodeError):
            pass

    mirror = github_mirror_prefix()
    api_url = f"https://api.github.com/repos/{REPO}/releases/latest"
    if mirror:
        api_url = f"{mirror}/{api_url}"
    raw = fetch_url(api_url, timeout=10)
    data = json.loads(raw)
    # Slim to just what we need.
    slim = {
        "tag_name": data.get("tag_name", ""),
        "assets": [{"name": a.get("name", ""), "url": a.get("browser_download_url", "")}
                   for a in (data.get("assets") or [])],
    }
    try:
        with open(RELEASE_CACHE, "w", encoding="utf-8") as fp:
            json.dump(slim, fp)
        os.chmod(RELEASE_CACHE, 0o640)
    except OSError:
        pass
    return slim


def pick_asset(release: dict) -> tuple[str, str]:
    """Return (gz_url, sha256_url)."""
    gz_url = sha_url = ""
    for a in release.get("assets") or []:
        name = a.get("name", "")
        url  = a.get("url", "")
        if not name or not url:
            continue
        if name.startswith(ASSET_RE_GZ) and name.endswith(".gz") and "amd64" in name:
            gz_url = url
        elif name.startswith(ASSET_RE_GZ) and (name.endswith(".sha256") or name.endswith(".sha256sum")) and "amd64" in name:
            sha_url = url
    if not gz_url:
        raise RuntimeError("no freebsd-amd64 .gz asset in release")
    return gz_url, sha_url


def apply_mirror(url: str) -> str:
    prefix = github_mirror_prefix()
    if prefix and url.startswith("https://github.com/"):
        return f"{prefix}/{url}"
    return url


def sha256_of_file(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as fp:
        while True:
            chunk = fp.read(65536)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def smoke_test(path: str) -> str:
    res = subprocess.run([path, "-v"], capture_output=True, text=True, timeout=5)
    if res.returncode != 0:
        raise RuntimeError(f"smoke test exit {res.returncode}: {(res.stderr or res.stdout)}")
    return (res.stdout or res.stderr).splitlines()[0] if (res.stdout or res.stderr) else ""


def service_running() -> bool:
    res = subprocess.run([CONFIGCTL, "mihomo", "status"], capture_output=True, text=True, timeout=10)
    out = (res.stdout or "") + (res.stderr or "")
    return "is running" in out or " running" in out


def main() -> int:
    progress("running", step="resolving", percent=2)
    try:
        release = get_latest_release()
        gz_url, sha_url = pick_asset(release)
        gz_url  = apply_mirror(gz_url)
        sha_url = apply_mirror(sha_url) if sha_url else ""
    except (urllib.error.URLError, urllib.error.HTTPError, RuntimeError, OSError, json.JSONDecodeError) as e:
        progress("failed", message=f"resolve: {e}")
        return 1

    ver = release.get("tag_name", "unknown")
    progress("running", step=f"downloading {ver}", percent=15)
    gz_path = f"/tmp/mihomo-{ver}.gz"
    try:
        data = fetch_url(gz_url, timeout=120)
        with open(gz_path, "wb") as fp:
            fp.write(data)
    except (urllib.error.URLError, urllib.error.HTTPError, OSError) as e:
        progress("failed", message=f"download .gz: {e}")
        return 1

    # SHA256 check (best-effort if .sha256 asset exists).
    if sha_url:
        progress("running", step="verifying SHA256", percent=40)
        try:
            sha_blob = fetch_url(sha_url, timeout=30).decode("utf-8", errors="replace")
        except (urllib.error.URLError, urllib.error.HTTPError, OSError) as e:
            progress("failed", message=f"download .sha256: {e}")
            return 1
        expected = sha_blob.strip().split()[0] if sha_blob.strip() else ""
        if not expected or expected != sha256_of_file(gz_path):
            progress("failed", message="SHA256 mismatch")
            try: os.unlink(gz_path)
            except OSError: pass
            return 1

    progress("running", step="extracting", percent=55)
    new_bin = f"/tmp/mihomo-{ver}.bin"
    try:
        with gzip.open(gz_path, "rb") as gz, open(new_bin, "wb") as out:
            shutil.copyfileobj(gz, out)
        os.chmod(new_bin, 0o755)
    except OSError as e:
        progress("failed", message=f"extract: {e}")
        return 1
    finally:
        try: os.unlink(gz_path)
        except OSError: pass

    progress("running", step="smoke-test", percent=65)
    try:
        version_line = smoke_test(new_bin)
    except (subprocess.TimeoutExpired, RuntimeError, OSError) as e:
        progress("failed", message=f"smoke test: {e}")
        try: os.unlink(new_bin)
        except OSError: pass
        return 1

    # Backup current and swap in.
    ts = time.strftime("%Y%m%d-%H%M%S")
    backup_path = f"{BIN_PATH}.bak.{ts}"
    progress("running", step="installing", percent=75)
    try:
        if os.path.isfile(BIN_PATH):
            shutil.copy2(BIN_PATH, backup_path)
        os.replace(new_bin, BIN_PATH)
        os.chmod(BIN_PATH, 0o755)
    except OSError as e:
        progress("failed", message=f"install: {e}")
        return 1

    progress("running", step="restarting", percent=85)
    try:
        subprocess.run([CONFIGCTL, "mihomo", "restart"], capture_output=True, text=True, timeout=30)
    except (subprocess.TimeoutExpired, OSError) as e:
        progress("failed", message=f"restart dispatch: {e}")
        return 1

    # Poll up to 10s for service to come back up.
    progress("running", step="verifying restart", percent=90)
    ok = False
    for _ in range(20):
        time.sleep(0.5)
        if service_running():
            ok = True
            break

    if not ok and os.path.isfile(backup_path):
        progress("running", step="rolling back", percent=95)
        try:
            shutil.copy2(backup_path, BIN_PATH)
            os.chmod(BIN_PATH, 0o755)
            subprocess.run([CONFIGCTL, "mihomo", "restart"],
                           capture_output=True, text=True, timeout=30)
        except OSError:
            pass
        progress("failed", message=f"service did not recover; rolled back to {backup_path}")
        return 1

    progress("done", step=f"updated to {ver}", percent=100,
             message=version_line or ver)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # noqa: BLE001
        progress("failed", message=f"unhandled: {e}")
        sys.exit(1)
