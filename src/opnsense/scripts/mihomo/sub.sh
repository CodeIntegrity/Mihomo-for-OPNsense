#!/usr/local/bin/python3
"""Subscription refresh worker — configd action `sub-refresh`.

Usage:
    sub.sh <uuid>

Pipeline (mirrors design §5.4):
    1. Per-uuid flock guard (prevents concurrent refresh of same sub).
    2. Read subscription record from /conf/config.xml.
    3. Mark last_status=updating in config.xml.
    4. curl-download with the user-configured User-Agent.
    5. Parse YAML, extract proxies / proxy-groups / rules.
    6. Apply include/exclude keyword filters on proxy NAMES only;
       rewrite proxy-groups[].proxies references so they stay consistent.
    7. Render the new profile YAML, validate with `mihomo -t -f`.
    8. On success: rename into profiles/sub-<name>.yaml + write meta.json.
    9. Mark last_status=done + last_update in config.xml.
    10. If active profile uses this subscription, trigger reconfigure.

All stdout/stderr goes to /var/log/mihomo_sub.log (prefixed with [sub=<uuid>]).
Exit codes: 0 success, 1 fetch/parse/validate failure, 2 bad arg.
"""

from __future__ import annotations

import fcntl
import json
import os
import re
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

# SSL context that tolerates MITM proxies (e.g. Mihomo fake-ip TUN).
_SSL_CONTEXT = ssl.create_default_context()
_SSL_CONTEXT.check_hostname = False
_SSL_CONTEXT.verify_mode = ssl.CERT_NONE

try:
    import yaml
except ImportError:
    sys.stderr.write("FATAL: py-yaml required\n")
    sys.exit(2)

CONFIG_PATH = "/conf/config.xml"
MIHOMO_DIR = "/usr/local/etc/mihomo"
PROFILES_DIR = os.path.join(MIHOMO_DIR, "profiles")
MIHOMO_BIN = "/usr/local/bin/mihomo"
LOG_PATH = "/var/log/mihomo_sub.log"
CONFIGCTL = "/usr/local/sbin/configctl"


# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

def log(msg: str, uuid: str = "") -> None:
    """Append a line to /var/log/mihomo_sub.log with timestamp + uuid prefix."""
    line = "[{} sub={}] {}\n".format(
        time.strftime("%Y-%m-%d %H:%M:%S"), uuid or "-", msg)
    try:
        with open(LOG_PATH, "a", encoding="utf-8") as fp:
            fp.write(line)
    except OSError:
        sys.stderr.write(line)


# ---------------------------------------------------------------------------
# config.xml read / write
# ---------------------------------------------------------------------------

def _lock_config() -> "_io.TextIOWrapper":
    """Acquire LOCK_EX on /conf/config.xml. Mirrors OPNsense Config::save()."""
    fp = open(CONFIG_PATH, "r+", encoding="utf-8")
    fcntl.flock(fp.fileno(), fcntl.LOCK_EX)
    return fp


def _find_subscription(root: ET.Element, uuid: str) -> ET.Element | None:
    subs = root.find("./OPNsense/Mihomo/mihomo/subscriptions")
    if subs is None:
        return None
    for sub in subs.findall("subscription"):
        if sub.get("uuid") == uuid:
            return sub
    return None


def read_subscription(uuid: str) -> dict | None:
    try:
        tree = ET.parse(CONFIG_PATH)
    except (ET.ParseError, OSError) as e:
        log(f"read config.xml failed: {e}", uuid)
        return None
    sub = _find_subscription(tree.getroot(), uuid)
    if sub is None:
        return None
    out = {"uuid": uuid}
    for f in ("enabled", "name", "url", "user_agent", "interval",
              "include_keyword", "exclude_keyword",
              "last_update", "last_status"):
        out[f] = (sub.findtext(f) or "").strip()
    return out


def update_subscription_fields(uuid: str, updates: dict) -> bool:
    """Persist field changes back to config.xml under LOCK_EX."""
    lockfp = _lock_config()
    try:
        lockfp.seek(0)
        tree = ET.parse(lockfp)
        root = tree.getroot()
        sub = _find_subscription(root, uuid)
        if sub is None:
            return False
        for k, v in updates.items():
            elem = sub.find(k)
            if elem is None:
                elem = ET.SubElement(sub, k)
            elem.text = str(v)
        tmp = CONFIG_PATH + ".subref.tmp"
        tree.write(tmp, encoding="utf-8", xml_declaration=True)
        try:
            os.chmod(tmp, 0o644)
            os.chown(tmp, 0, 0)
        except (PermissionError, OSError):
            pass
        os.replace(tmp, CONFIG_PATH)
        return True
    finally:
        fcntl.flock(lockfp.fileno(), fcntl.LOCK_UN)
        lockfp.close()


def active_profile_name() -> str:
    try:
        root = ET.parse(CONFIG_PATH).getroot()
    except (ET.ParseError, OSError):
        return "default"
    return (root.findtext("./OPNsense/Mihomo/mihomo/state/active_profile") or "default").strip() or "default"


# ---------------------------------------------------------------------------
# Download
# ---------------------------------------------------------------------------

def download(url: str, user_agent: str, timeout: int = 30) -> bytes:
    req = urllib.request.Request(url, headers={
        "User-Agent": user_agent or "clash-verge/v1.7.0",
        "Accept": "*/*",
    })
    with urllib.request.urlopen(req, timeout=timeout, context=_SSL_CONTEXT) as resp:
        if resp.status < 200 or resp.status >= 300:
            raise RuntimeError(f"http {resp.status}")
        return resp.read()


# ---------------------------------------------------------------------------
# Filter
# ---------------------------------------------------------------------------

def _split_csv(s: str) -> list[str]:
    return [x.strip() for x in (s or "").split(",") if x.strip()]


def filter_proxies(profile: dict, include: list[str], exclude: list[str]) -> dict:
    """Apply keyword filters to proxies and reconcile proxy-groups."""
    proxies = profile.get("proxies") or []
    if not isinstance(proxies, list):
        return profile

    def keep(name: str) -> bool:
        if include and not any(kw in name for kw in include):
            return False
        if exclude and any(kw in name for kw in exclude):
            return False
        return True

    kept_names: set[str] = set()
    new_proxies = []
    for p in proxies:
        if not isinstance(p, dict):
            continue
        name = str(p.get("name", ""))
        if not name or not keep(name):
            continue
        new_proxies.append(p)
        kept_names.add(name)

    new_groups = []
    for g in profile.get("proxy-groups") or []:
        if not isinstance(g, dict):
            continue
        gp = list(g.get("proxies") or [])
        # Drop names that no longer exist; keep group references (like "DIRECT",
        # "REJECT", other group names) — these are not filtered.
        well_known = {"DIRECT", "REJECT", "PASS"}
        group_names = {x.get("name") for x in profile.get("proxy-groups") or []
                       if isinstance(x, dict)}
        gp_new = []
        for entry in gp:
            entry_str = str(entry) if entry is not None else ""
            if (entry_str in kept_names or entry_str in well_known
                    or entry_str in group_names
                    or entry_str.startswith(("@", "#"))):  # special selectors
                gp_new.append(entry)
        if not gp_new:
            # If a group ends up empty, give it DIRECT as a safe fallback.
            gp_new = ["DIRECT"]
        g2 = dict(g)
        g2["proxies"] = gp_new
        new_groups.append(g2)

    out = dict(profile)
    out["proxies"] = new_proxies
    if new_groups:
        out["proxy-groups"] = new_groups
    return out


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main(argv: list[str]) -> int:
    if len(argv) < 2 or not re.match(r"^[0-9a-f-]{36}$", argv[1]):
        sys.stderr.write("usage: sub.sh <uuid>\n")
        return 2
    uuid = argv[1]

    # Per-uuid lock to avoid concurrent refresh of the same subscription.
    lock_path = f"/tmp/mihomo-sub-{uuid}.lock"
    lock_fp = open(lock_path, "w")
    try:
        fcntl.flock(lock_fp, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log("another refresh in progress, skipping", uuid)
        return 0

    sub = read_subscription(uuid)
    if sub is None:
        log("subscription not found", uuid)
        return 1
    if sub.get("enabled") != "1":
        log("subscription disabled, skipping", uuid)
        return 0

    name = sub.get("name", "")
    if not re.match(r"^[a-zA-Z0-9_-]+$", name):
        log(f"invalid subscription name: {name!r}", uuid)
        update_subscription_fields(uuid, {"last_status": "failed",
                                          "last_update": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())})
        return 1

    profile_name = "sub-" + name
    profile_path = os.path.join(PROFILES_DIR, profile_name + ".yaml")
    meta_path    = os.path.join(PROFILES_DIR, profile_name + ".meta.json")

    update_subscription_fields(uuid, {"last_status": "updating"})

    try:
        log(f"downloading {sub['url']!r}", uuid)
        raw = download(sub["url"], sub.get("user_agent", ""))
    except (urllib.error.URLError, urllib.error.HTTPError, RuntimeError, TimeoutError, OSError) as e:
        log(f"download failed: {e}", uuid)
        update_subscription_fields(uuid, {
            "last_status": "failed",
            "last_update": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        })
        return 1

    # Parse YAML.
    try:
        data = yaml.safe_load(raw) or {}
    except yaml.YAMLError as e:
        log(f"yaml parse failed: {e}", uuid)
        update_subscription_fields(uuid, {
            "last_status": "failed",
            "last_update": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        })
        return 1
    if not isinstance(data, dict):
        log("downloaded content is not a YAML mapping", uuid)
        update_subscription_fields(uuid, {
            "last_status": "failed",
            "last_update": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        })
        return 1

    # Extract relevant sections only — drop the provider's own
    # base.yaml-style fields so they don't conflict with ours.
    profile = {}
    for k in ("proxies", "proxy-groups", "rules",
              "proxy-providers", "rule-providers"):
        if k in data:
            profile[k] = data[k]

    include = _split_csv(sub.get("include_keyword", ""))
    exclude = _split_csv(sub.get("exclude_keyword", ""))
    profile = filter_proxies(profile, include, exclude)
    node_count = len(profile.get("proxies") or [])
    log(f"filtered: {node_count} proxies", uuid)

    # Write tmp profile, validate via `mihomo -t -f` if possible.
    # Temp file must live on the same filesystem as PROFILES_DIR so the
    # final os.replace() is atomic (OPNsense /tmp may be a separate dataset).
    rendered = yaml.safe_dump(profile, allow_unicode=True, sort_keys=False)
    os.makedirs(PROFILES_DIR, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".sub-", suffix=".yaml", dir=PROFILES_DIR)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fp:
            fp.write(rendered)
        os.chmod(tmp, 0o640)

        if os.path.exists(MIHOMO_BIN):
            # Validation requires a "full" config — we synthesize one by
            # merging in the current base.yaml on the fly.
            full_tmp = tmp + ".full"
            base_yaml = {}
            base_path = os.path.join(MIHOMO_DIR, "base.yaml")
            if os.path.isfile(base_path):
                with open(base_path, "r", encoding="utf-8") as bfp:
                    base_yaml = yaml.safe_load(bfp) or {}
            merged = dict(base_yaml)
            merged.update(profile)
            with open(full_tmp, "w", encoding="utf-8") as ffp:
                yaml.safe_dump(merged, ffp, allow_unicode=True, sort_keys=False)
            try:
                res = subprocess.run([MIHOMO_BIN, "-d", MIHOMO_DIR, "-t", "-f", full_tmp],
                                     capture_output=True, text=True, timeout=10)
                if res.returncode != 0:
                    log("mihomo -t failed:\n" + (res.stdout or "") + (res.stderr or ""), uuid)
                    update_subscription_fields(uuid, {
                        "last_status": "failed",
                        "last_update": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                    })
                    return 1
            finally:
                try: os.unlink(full_tmp)
                except OSError: pass

        # Commit.
        os.replace(tmp, profile_path)
        try:
            os.chown(profile_path, 0, _gid("www"))
        except (PermissionError, KeyError, OSError):
            pass
        os.chmod(profile_path, 0o640)
        tmp = None  # ownership transferred

        meta = {
            "source_type": "subscription",
            "sub_id":      uuid,
            "source_url":  sub["url"],
            "last_update": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "last_status": "done",
            "node_count":  node_count,
        }
        with open(meta_path, "w", encoding="utf-8") as fp:
            json.dump(meta, fp, ensure_ascii=False, indent=2)
        os.chmod(meta_path, 0o640)
    finally:
        if tmp and os.path.exists(tmp):
            try: os.unlink(tmp)
            except OSError: pass

    # Update config.xml status fields.
    update_subscription_fields(uuid, {
        "last_status": "done",
        "last_update": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    })

    # Trigger reconfigure if this is the active profile.
    if active_profile_name() == profile_name:
        log("active profile updated — triggering reconfigure", uuid)
        try:
            subprocess.run([CONFIGCTL, "mihomo", "reconfigure"],
                           capture_output=True, text=True, timeout=20)
        except (subprocess.TimeoutExpired, OSError) as e:
            log(f"reconfigure dispatch failed: {e}", uuid)

    log("done", uuid)
    return 0


def _gid(name: str) -> int:
    import grp
    return grp.getgrnam(name).gr_gid


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception as e:  # noqa: BLE001 — last-ditch
        log(f"unhandled: {e}", sys.argv[1] if len(sys.argv) > 1 else "")
        try:
            if len(sys.argv) > 1 and re.match(r"^[0-9a-f-]{36}$", sys.argv[1]):
                update_subscription_fields(sys.argv[1], {
                    "last_status": "failed",
                    "last_update": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                })
        except Exception:
            pass
        sys.exit(1)
