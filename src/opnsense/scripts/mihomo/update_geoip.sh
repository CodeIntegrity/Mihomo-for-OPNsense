#!/usr/local/bin/python3
"""GeoIP database update — configd action `update-geoip`.

Pipeline:
    1. Resolve latest tag from MetaCubeX/meta-rules-dat (1h cache).
    2. Download Country.mmdb asset.
    3. Atomic-replace /usr/local/etc/mihomo/Country.mmdb with a timestamped
       backup of the previous file.
    4. Try `PUT /configs/geo` for hot-reload. If unsupported, fall back to
       `configctl mihomo reconfigure`.

Progress is written to /tmp/mihomo-update-geoip.json for UI polling.
"""

from __future__ import annotations

import http.client
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

PROGRESS = "/tmp/mihomo-update-geoip.json"
RELEASE_CACHE = "/tmp/mihomo-release-cache-geoip.json"
TARGET = "/usr/local/etc/mihomo/Country.mmdb"
CONFIG_PATH = "/conf/config.xml"
REPO = "MetaCubeX/meta-rules-dat"
ASSET_NAME = "country.mmdb"  # case-insensitive match
CONFIGCTL = "/usr/local/sbin/configctl"


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


def fetch(url, timeout=30):
    req = urllib.request.Request(url, headers=github_headers())
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        if resp.status < 200 or resp.status >= 300:
            raise RuntimeError(f"http {resp.status} for {url}")
        return resp.read()


def get_latest_release():
    if os.path.isfile(RELEASE_CACHE) and (time.time() - os.path.getmtime(RELEASE_CACHE)) < 3600:
        try:
            with open(RELEASE_CACHE, "r", encoding="utf-8") as fp:
                cached = json.load(fp)
            if cached.get("assets"):
                return cached
        except (OSError, json.JSONDecodeError):
            pass

    api = f"https://api.github.com/repos/{REPO}/releases/latest"
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
        with open(RELEASE_CACHE, "w", encoding="utf-8") as fp:
            json.dump(slim, fp)
        os.chmod(RELEASE_CACHE, 0o640)
    except OSError:
        pass
    return slim


def pick_asset(release):
    for a in release.get("assets") or []:
        name = (a.get("name") or "").lower()
        url  = a.get("url") or ""
        if name == ASSET_NAME and url:
            return url
    raise RuntimeError("no Country.mmdb asset in release")


def apply_mirror(url):
    prefix = github_mirror()
    if prefix and url.startswith("https://github.com/"):
        return f"{prefix}/{url}"
    return url


def hot_reload_geo():
    """PUT /configs/geo. Returns True on success, False if unsupported."""
    root = _opnsense_root()
    if root is None:
        return False
    ec = (root.findtext("./OPNsense/Mihomo/mihomo/controller/external_controller") or "127.0.0.1:9090").strip()
    secret = (root.findtext("./OPNsense/Mihomo/mihomo/controller/secret") or "").strip()
    ec = ec.replace("0.0.0.0", "127.0.0.1")
    host, _, port = ec.partition(":")
    try:
        conn = http.client.HTTPConnection(host or "127.0.0.1", int(port or "9090"), timeout=5)
        headers = {}
        if secret:
            headers["Authorization"] = f"Bearer {secret}"
        conn.request("PUT", "/configs/geo", body="", headers=headers)
        resp = conn.getresponse()
        conn.close()
        return resp.status >= 200 and resp.status < 300
    except (ConnectionRefusedError, OSError):
        return False


def main():
    progress("running", step="resolving", percent=5)
    try:
        release = get_latest_release()
        url = apply_mirror(pick_asset(release))
    except (urllib.error.URLError, urllib.error.HTTPError, RuntimeError, OSError) as e:
        progress("failed", message=f"resolve: {e}")
        return 1

    progress("running", step=f"downloading {release.get('tag_name', '')}", percent=30)
    tmp = "/tmp/mihomo-Country.mmdb.new"
    try:
        data = fetch(url, timeout=120)
        with open(tmp, "wb") as fp:
            fp.write(data)
        os.chmod(tmp, 0o640)
    except (urllib.error.URLError, urllib.error.HTTPError, OSError) as e:
        progress("failed", message=f"download: {e}")
        return 1

    # Sanity check — Country.mmdb starts with magic "M\xfe\xfb\xfd" near the
    # binary end; a simple size floor is enough to catch HTML error pages.
    if os.path.getsize(tmp) < 100_000:
        progress("failed", message="downloaded file too small (likely an error page)")
        try: os.unlink(tmp)
        except OSError: pass
        return 1

    # Backup + atomic replace.
    progress("running", step="installing", percent=70)
    try:
        if os.path.isfile(TARGET):
            ts = time.strftime("%Y%m%d-%H%M%S")
            shutil.copy2(TARGET, f"{TARGET}.bak.{ts}")
        shutil.move(tmp, TARGET)
        _chown_www(TARGET)
        os.chmod(TARGET, 0o640)
    except OSError as e:
        progress("failed", message=f"install: {e}")
        return 1

    # Try hot-reload first; fall back to reconfigure.
    progress("running", step="reloading geo", percent=90)
    if not hot_reload_geo():
        try:
            subprocess.run([CONFIGCTL, "mihomo", "reconfigure"],
                           capture_output=True, text=True, timeout=30)
        except (subprocess.TimeoutExpired, OSError) as e:
            progress("failed", message=f"reconfigure fallback: {e}")
            return 1

    progress("done", step="updated", percent=100, message=release.get("tag_name", ""))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # noqa: BLE001
        progress("failed", message=f"unhandled: {e}")
        sys.exit(1)
