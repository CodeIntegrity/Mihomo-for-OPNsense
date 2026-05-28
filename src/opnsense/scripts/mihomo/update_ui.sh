#!/usr/local/bin/python3
"""Dashboard UI update — configd action `update-ui`.

Usage:
    update_ui.sh <variant>  (variant ∈ zashboard|metacubexd|yacd)

Pipeline:
    1. Resolve latest release for the chosen variant (1h cache).
    2. Download the release archive (.zip or .tar.gz depending on variant).
    3. Extract into a staging directory.
    4. Atomic-replace /usr/local/etc/mihomo/ui (renaming old to ui.bak.<ts>).
    5. Drop a .version-<variant> marker for future "current" detection.

No service reload needed — Mihomo serves from disk on each /ui/ request.

Progress is written to /tmp/mihomo-update-ui.json.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
import zipfile

PROGRESS = "/tmp/mihomo-update-ui.json"
UI_DIR = "/usr/local/etc/mihomo/ui"
CONFIG_PATH = "/conf/config.xml"

REPOS = {
    "zashboard":  "Zephyruso/zashboard",
    "metacubexd": "MetaCubeX/metacubexd",
    "yacd":       "haishanh/yacd",
}

# Per-variant asset name patterns (case-insensitive substring match).
ASSET_PATTERNS = {
    "zashboard":  ["dist.zip"],
    "metacubexd": ["compressed-dist.tgz", "compressed-dist.tar.gz", "dist.tgz"],
    "yacd":       ["yacd.tar.xz", "yacd.tgz", "dist.tgz"],
}


def progress(state, step="", percent=0, message=""):
    payload = {"state": state, "step": step, "percent": percent,
               "message": message, "updated": int(time.time())}
    try:
        with open(PROGRESS, "w", encoding="utf-8") as fp:
            json.dump(payload, fp, ensure_ascii=False)
        os.chmod(PROGRESS, 0o640)
        _chown_www(PROGRESS)
    except OSError:
        pass


def _chown_www(path):
    """Chown path to root:www. Best-effort — no-op if unresolvable."""
    try:
        import grp
        gid = grp.getgrnam("www").gr_gid
    except (ImportError, KeyError):
        try:
            gid = os.stat(path).st_gid  # keep existing group
        except OSError:
            return
    try:
        os.chown(path, 0, gid)
    except (PermissionError, OSError):
        pass


def _opnsense_root():
    try:
        return ET.parse(CONFIG_PATH).getroot()
    except (ET.ParseError, OSError):
        return None


def github_headers():
    headers = {"Accept": "application/vnd.github+json",
               "User-Agent": "Mihomo-for-OPNsense"}
    root = _opnsense_root()
    if root is not None:
        token = (root.findtext("./OPNsense/Mihomo/mihomo/update/github_token") or "").strip()
        if token:
            headers["Authorization"] = f"Bearer {token}"
    return headers


def github_mirror():
    root = _opnsense_root()
    if root is None:
        return ""
    return (root.findtext("./OPNsense/Mihomo/mihomo/update/github_mirror") or "").strip().rstrip("/")


def fetch(url, timeout=60):
    req = urllib.request.Request(url, headers=github_headers())
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        if resp.status < 200 or resp.status >= 300:
            raise RuntimeError(f"http {resp.status} for {url}")
        return resp.read()


def get_latest_release(variant: str) -> dict:
    repo = REPOS[variant]
    cache_file = f"/tmp/mihomo-release-cache-ui-{variant}.json"
    if os.path.isfile(cache_file) and (time.time() - os.path.getmtime(cache_file)) < 3600:
        try:
            with open(cache_file, "r", encoding="utf-8") as fp:
                cached = json.load(fp)
            if cached.get("assets"):
                return cached
        except (OSError, json.JSONDecodeError):
            pass

    api = f"https://api.github.com/repos/{repo}/releases/latest"
    mirror = github_mirror()
    if mirror:
        api = f"{mirror}/{api}"
    raw = fetch(api, timeout=10)
    data = json.loads(raw)
    slim = {
        "tag_name": data.get("tag_name", ""),
        "assets": [{"name": a.get("name", ""), "url": a.get("browser_download_url", "")}
                   for a in (data.get("assets") or [])],
    }
    try:
        with open(cache_file, "w", encoding="utf-8") as fp:
            json.dump(slim, fp)
        os.chmod(cache_file, 0o640)
    except OSError:
        pass
    return slim


def pick_asset(release: dict, variant: str) -> tuple[str, str]:
    patterns = [p.lower() for p in ASSET_PATTERNS.get(variant, [])]
    for a in release.get("assets") or []:
        name_l = (a.get("name") or "").lower()
        url = a.get("url") or ""
        if not name_l or not url:
            continue
        if any(name_l.endswith(p) or p in name_l for p in patterns):
            return a["name"], url
    raise RuntimeError(f"no matching asset for {variant} (patterns: {patterns})")


def apply_mirror(url: str) -> str:
    prefix = github_mirror()
    if prefix and url.startswith("https://github.com/"):
        return f"{prefix}/{url}"
    return url


def extract_archive(archive_path: str, name: str, stage_dir: str) -> None:
    nlower = name.lower()
    if nlower.endswith(".zip"):
        with zipfile.ZipFile(archive_path, "r") as zf:
            for member in zf.infolist():
                # Reject absolute / parent-traversal paths.
                target = os.path.realpath(os.path.join(stage_dir, member.filename))
                if not target.startswith(os.path.realpath(stage_dir) + os.sep) and target != os.path.realpath(stage_dir):
                    raise RuntimeError(f"unsafe zip entry: {member.filename}")
            zf.extractall(stage_dir)
    elif nlower.endswith((".tar.gz", ".tgz", ".tar.xz")):
        mode = "r:gz" if nlower.endswith((".tar.gz", ".tgz")) else "r:xz"
        with tarfile.open(archive_path, mode) as tf:
            for member in tf.getmembers():
                target = os.path.realpath(os.path.join(stage_dir, member.name))
                if not target.startswith(os.path.realpath(stage_dir) + os.sep) and target != os.path.realpath(stage_dir):
                    raise RuntimeError(f"unsafe tar entry: {member.name}")
            tf.extractall(stage_dir)
    else:
        raise RuntimeError(f"unsupported archive type: {name}")


def find_dist_root(stage_dir: str) -> str:
    """Locate the actual UI root inside the extracted archive.

    Most release tarballs contain a single top-level dir (e.g., "dist/") that
    holds the static files. We look for an index.html and use that as root.
    """
    # Direct hit?
    if os.path.isfile(os.path.join(stage_dir, "index.html")):
        return stage_dir
    # One-level descent.
    for entry in os.listdir(stage_dir):
        sub = os.path.join(stage_dir, entry)
        if os.path.isdir(sub) and os.path.isfile(os.path.join(sub, "index.html")):
            return sub
    # Walk a bit deeper as a last resort.
    for root, _dirs, files in os.walk(stage_dir):
        if "index.html" in files:
            return root
    raise RuntimeError("no index.html found in archive")


def main(argv: list[str]) -> int:
    if len(argv) < 2 or argv[1] not in REPOS:
        sys.stderr.write("usage: update_ui.sh <zashboard|metacubexd|yacd>\n")
        return 2
    variant = argv[1]

    progress("running", step="resolving", percent=5)
    try:
        release = get_latest_release(variant)
        asset_name, asset_url = pick_asset(release, variant)
        asset_url = apply_mirror(asset_url)
    except (urllib.error.URLError, urllib.error.HTTPError, RuntimeError, OSError) as e:
        progress("failed", message=f"resolve: {e}")
        return 1

    progress("running", step=f"downloading {asset_name}", percent=25)
    with tempfile.TemporaryDirectory(prefix="mihomo-ui-", dir="/tmp") as tmp:
        archive_path = os.path.join(tmp, asset_name)
        try:
            data = fetch(asset_url, timeout=180)
            with open(archive_path, "wb") as fp:
                fp.write(data)
        except (urllib.error.URLError, urllib.error.HTTPError, OSError) as e:
            progress("failed", message=f"download: {e}")
            return 1

        progress("running", step="extracting", percent=55)
        stage = os.path.join(tmp, "stage")
        os.makedirs(stage, exist_ok=True)
        try:
            extract_archive(archive_path, asset_name, stage)
            dist_root = find_dist_root(stage)
        except (RuntimeError, tarfile.TarError, zipfile.BadZipFile) as e:
            progress("failed", message=f"extract: {e}")
            return 1

        # Backup current ui/ and swap in.
        progress("running", step="installing", percent=80)
        try:
            if os.path.isdir(UI_DIR):
                ts = time.strftime("%Y%m%d-%H%M%S")
                os.replace(UI_DIR, f"{UI_DIR}.bak.{ts}")
            shutil.copytree(dist_root, UI_DIR)
        except OSError as e:
            progress("failed", message=f"install: {e}")
            return 1

        # Drop a version marker for future "current" detection.
        try:
            with open(os.path.join(UI_DIR, f".version-{variant}"), "w", encoding="utf-8") as fp:
                fp.write(release.get("tag_name", ""))
            for root, dirs, files in os.walk(UI_DIR):
                for d in dirs:
                    os.chmod(os.path.join(root, d), 0o755)
                for f in files:
                    os.chmod(os.path.join(root, f), 0o644)
        except OSError:
            pass

    progress("done", step=f"installed {variant}", percent=100,
             message=release.get("tag_name", ""))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception as e:  # noqa: BLE001
        progress("failed", message=f"unhandled: {e}")
        sys.exit(1)
