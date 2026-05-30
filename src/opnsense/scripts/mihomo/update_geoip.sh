#!/usr/local/bin/python3
"""GeoIP database update — configd action `update-geoip`.

Pipeline:
    1. Resolve latest release from MetaCubeX/meta-rules-dat (1h cache). The
       repo is a rolling release (tag_name == "latest"), so the version label
       is the release publish date (YYYY-MM-DD).
    2. Download Country.mmdb asset.
    3. Atomic-replace /usr/local/etc/mihomo/Country.mmdb with a timestamped
       backup of the previous file.
    4. Write a .version-geoip marker for future "current" detection.
    5. Try `PUT /configs/geo` for hot-reload. If unsupported, fall back to
       `configctl mihomo reconfigure`.

Progress is written to /tmp/mihomo-update-geoip.json for UI polling.
"""

from __future__ import annotations

import http.client
import json
import os
import shutil
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

# SSL context that tolerates MITM proxies (e.g. Mihomo fake-ip TUN).
_SSL_CONTEXT = ssl.create_default_context()
_SSL_CONTEXT.check_hostname = False
_SSL_CONTEXT.verify_mode = ssl.CERT_NONE

PROGRESS = "/tmp/mihomo-update-geoip.json"
RELEASE_CACHE = "/tmp/mihomo-release-cache-geoip.json"
TARGET = "/usr/local/etc/mihomo/Country.mmdb"
VERSION_MARKER = "/usr/local/etc/mihomo/.version-geoip"
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


def geoip_custom_url():
    """Return the custom GeoIP download URL if configured, empty string otherwise."""
    root = _opnsense_root()
    if root is None:
        return ""
    return (root.findtext("./OPNsense/Mihomo/mihomo/update/geoip_url") or "").strip()


def github_mirror():
    root = _opnsense_root()
    if root is None:
        return ""
    return (root.findtext("./OPNsense/Mihomo/mihomo/update/github_mirror") or "").strip().rstrip("/")


def _resolve_doh(hostname):
    """Resolve a hostname via Cloudflare DoH to bypass fake-ip DNS hijack.
    Uses curl subprocess because Python's urllib also falls victim to fake-ip."""
    try:
        url = "https://1.1.1.1/dns-query?name=" + urllib.parse.quote(hostname) + "&type=A"
        res = subprocess.run(["/usr/local/bin/curl", "-sk", "--connect-timeout", "5", "--max-time", "10",
                              "-H", "accept: application/dns-json", url],
                             capture_output=True, text=True, timeout=12)
        if res.returncode != 0:
            return None
        data = json.loads(res.stdout)
        for a in (data.get("Answer") or []):
            if a.get("type") == 1:
                return a["data"]
    except Exception:
        pass
    return None


def _download_file(url, timeout=120):
    """Download a (potentially large) file via curl, resolving each redirect
    hostname through DoH so CDN hops get real IPs instead of fake-ip DNS."""
    max_redirects = 5
    for _ in range(max_redirects):
        parsed = urllib.parse.urlparse(url)
        hostname = parsed.hostname
        port = str(parsed.port or (443 if parsed.scheme == "https" else 80))
        real_ip = _resolve_doh(hostname)
        if real_ip is None:
            raise RuntimeError(f"cannot resolve {hostname} via DoH")
        # HEAD first to detect redirects.
        head_res = subprocess.run(
            ["/usr/local/bin/curl", "-skI",
             "--resolve", f"{hostname}:{port}:{real_ip}",
             "--connect-timeout", str(max(5, timeout // 3)),
             "--max-time", str(min(15, timeout)),
             url],
            capture_output=True, text=True, timeout=min(20, timeout + 5))
        if head_res.returncode != 0:
            raise RuntimeError(f"curl HEAD returned {head_res.returncode}")
        # Parse status line and Location.
        status_line = head_res.stdout.split("\n")[0] if head_res.stdout else ""
        if " 301 " in status_line or " 302 " in status_line or \
           " 303 " in status_line or " 307 " in status_line or " 308 " in status_line:
            # Follow redirect.
            new_url = ""
            for line in head_res.stdout.split("\n"):
                if line.lower().startswith("location:"):
                    new_url = line.split(":", 1)[1].strip()
                    break
            if new_url:
                url = new_url
                continue
            raise RuntimeError(f"redirect without Location header")
        if " 200 " not in status_line and " 201 " not in status_line:
            raise RuntimeError(f"unexpected HTTP status: {status_line.strip()}")
        # Download the body.
        curl_cmd = ["/usr/local/bin/curl", "-sk",
                    "--resolve", f"{hostname}:{port}:{real_ip}",
                    "--connect-timeout", str(max(5, timeout // 3)),
                    "--max-time", str(timeout),
                    url]
        hdrs = github_headers()
        for k, v in hdrs.items():
            curl_cmd += ["-H", f"{k}: {v}"]
        try:
            res = subprocess.run(curl_cmd, capture_output=True,
                                 timeout=timeout + 5)
        except (subprocess.TimeoutExpired, OSError) as e:
            raise RuntimeError(f"curl failed: {e}")
        if res.returncode != 0 or len(res.stdout) < 100:
            raise RuntimeError(f"curl returned {res.returncode}, {len(res.stdout)} bytes")
        return res.stdout
    raise RuntimeError("too many redirects")


def fetch(url, timeout=30):
    req = urllib.request.Request(url, headers=github_headers())
    with urllib.request.urlopen(req, timeout=timeout, context=_SSL_CONTEXT) as resp:
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
        "published_at": data.get("published_at", ""),
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


def version_label(release):
    """Version marker mirroring the UI's check display: for the rolling
    'latest' tag, use the release publish date (YYYY-MM-DD); else the tag."""
    tag = (release.get("tag_name") or "").strip()
    if tag.lower() == "latest":
        published = (release.get("published_at") or "").strip()
        if published:
            try:
                t = time.strptime(published, "%Y-%m-%dT%H:%M:%SZ")
                return time.strftime("%Y-%m-%d", t)
            except ValueError:
                pass
    return tag


def write_version_marker(label):
    if not label:
        return
    try:
        with open(VERSION_MARKER, "w", encoding="utf-8") as fp:
            fp.write(label)
        os.chmod(VERSION_MARKER, 0o640)
        _chown_www(VERSION_MARKER)
    except OSError:
        pass


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
    custom_url = geoip_custom_url()

    if custom_url:
        # Custom URL path — download directly, skip GitHub API.
        progress("running", step="downloading", percent=10)
        tmp = "/tmp/mihomo-Country.mmdb.new"
        try:
            data = _download_file(custom_url, timeout=120)
            with open(tmp, "wb") as fp:
                fp.write(data)
            os.chmod(tmp, 0o640)
        except (RuntimeError, OSError) as e:
            progress("failed", message=f"download: {e}")
            return 1

        # Sanity check.
        if os.path.getsize(tmp) < 100_000:
            progress("failed", message="downloaded file too small (likely an error page)")
            try:
                os.unlink(tmp)
            except OSError:
                pass
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

        # No release metadata on the custom path — record the install date so
        # "current" stays truthful and any stale GitHub-era marker is cleared.
        write_version_marker(time.strftime("%Y-%m-%d"))

        # Hot-reload.
        progress("running", step="reloading geo", percent=90)
        if not hot_reload_geo():
            try:
                subprocess.run([CONFIGCTL, "mihomo", "reconfigure"],
                               capture_output=True, text=True, timeout=30)
            except (subprocess.TimeoutExpired, OSError) as e:
                progress("failed", message=f"reconfigure fallback: {e}")
                return 1

        progress("done", step="updated", percent=100, message="custom-url")
        return 0

    # Default path — GitHub release.
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
        data = _download_file(url, timeout=120)
        with open(tmp, "wb") as fp:
            fp.write(data)
        os.chmod(tmp, 0o640)
    except (RuntimeError, OSError) as e:
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

    label = version_label(release)
    write_version_marker(label)

    # Try hot-reload first; fall back to reconfigure.
    progress("running", step="reloading geo", percent=90)
    if not hot_reload_geo():
        try:
            subprocess.run([CONFIGCTL, "mihomo", "reconfigure"],
                           capture_output=True, text=True, timeout=30)
        except (subprocess.TimeoutExpired, OSError) as e:
            progress("failed", message=f"reconfigure fallback: {e}")
            return 1

    progress("done", step="updated", percent=100, message=label or release.get("tag_name", ""))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:  # noqa: BLE001
        progress("failed", message=f"unhandled: {e}")
        sys.exit(1)
