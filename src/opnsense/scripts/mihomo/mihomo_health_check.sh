#!/usr/local/bin/python3
"""Mihomo health check — async worker for configd action `health-check`.

Usage:
    mihomo_health_check.sh <uuid> <profile_name> <mode>

Where mode is "quick" (test URL-Test group members, capped at 10) or "full"
(test every proxy in the profile, capped at 64). Progress is written to
/tmp/mihomo-health-<uuid>.json so the front-end can poll without holding a
PHP-FPM worker open.

The script reads the active profile YAML to enumerate proxies, then calls
Mihomo's `/proxies/<name>/delay?url=...` endpoint in batches of 5 to obtain
per-node latency. Dead = HTTP timeout or non-2xx; Alive = latency reported.

Concurrency is intentionally low (batch=5) — health checks should not
saturate the proxy paths or the FPM worker pool.
"""

from __future__ import annotations

import concurrent.futures
import http.client
import json
import os
import socket
import sys
import time
import urllib.parse
import xml.etree.ElementTree as ET

try:
    import yaml
except ImportError:
    sys.stderr.write("FATAL: py-yaml required\n")
    sys.exit(2)

CONFIG_XML = "/conf/config.xml"
MIHOMO_DIR = "/usr/local/etc/mihomo"
PROFILES_DIR = os.path.join(MIHOMO_DIR, "profiles")

QUICK_CAP = 10
FULL_CAP = 64
BATCH_CONCURRENCY = 5
DEFAULT_TEST_URL = "https://www.gstatic.com/generate_204"
DEFAULT_TIMEOUT_MS = 3000


def _config_xml_root() -> ET.Element:
    return ET.parse(CONFIG_XML).getroot()


def _read_controller(root: ET.Element) -> tuple[str, int, str]:
    ec = (root.findtext("./OPNsense/Mihomo/mihomo/controller/external_controller") or "127.0.0.1:9090").strip()
    secret = (root.findtext("./OPNsense/Mihomo/mihomo/controller/secret") or "").strip()
    ec = ec.replace("0.0.0.0", "127.0.0.1")
    host, _, port = ec.partition(":")
    return host or "127.0.0.1", int(port or "9090"), secret


def _read_test_settings(root: ET.Element) -> tuple[str, int]:
    url = (root.findtext("./OPNsense/Mihomo/mihomo/update/health_check_url") or DEFAULT_TEST_URL).strip()
    timeout_raw = (root.findtext("./OPNsense/Mihomo/mihomo/update/health_check_timeout") or "").strip()
    try:
        timeout = int(timeout_raw) if timeout_raw else DEFAULT_TIMEOUT_MS
    except ValueError:
        timeout = DEFAULT_TIMEOUT_MS
    return url or DEFAULT_TEST_URL, timeout


def _read_active_profile_name(root: ET.Element) -> str:
    n = root.findtext("./OPNsense/Mihomo/mihomo/state/active_profile")
    return (n or "legacy").strip() or "legacy"


def _proxies_from_profile(profile_yaml_path: str, mode: str) -> list[str]:
    if not os.path.isfile(profile_yaml_path):
        return []
    with open(profile_yaml_path, "r", encoding="utf-8") as fp:
        cfg = yaml.safe_load(fp) or {}
    proxies = cfg.get("proxies") or []
    proxy_names = [p.get("name") for p in proxies if isinstance(p, dict) and p.get("name")]

    if mode == "quick":
        # Only nodes referenced by url-test groups.
        wanted: list[str] = []
        for g in (cfg.get("proxy-groups") or []):
            if isinstance(g, dict) and g.get("type") in ("url-test", "fallback", "load-balance"):
                for p in (g.get("proxies") or []):
                    if isinstance(p, str) and p in proxy_names and p not in wanted:
                        wanted.append(p)
                        if len(wanted) >= QUICK_CAP:
                            return wanted
        # Fall back to first N proxies if no url-test group exists.
        return wanted or proxy_names[:QUICK_CAP]
    return proxy_names[:FULL_CAP]


def _delay_request(host: str, port: int, secret: str, name: str, test_url: str, timeout_ms: int) -> tuple[str, int | None]:
    """Return (name, latency_ms or None on failure)."""
    qs = urllib.parse.urlencode({"url": test_url, "timeout": timeout_ms})
    path = "/proxies/" + urllib.parse.quote(name, safe="") + "/delay?" + qs
    try:
        conn = http.client.HTTPConnection(host, port, timeout=(timeout_ms / 1000.0) + 2)
        headers = {}
        if secret:
            headers["Authorization"] = f"Bearer {secret}"
        conn.request("GET", path, headers=headers)
        resp = conn.getresponse()
        body = resp.read().decode("utf-8", errors="replace")
        conn.close()
        if resp.status < 200 or resp.status >= 300:
            return name, None
        data = json.loads(body) if body else {}
        delay = data.get("delay")
        return name, int(delay) if isinstance(delay, int) else None
    except (socket.timeout, ConnectionError, OSError, json.JSONDecodeError):
        return name, None


def _write_progress(path: str, payload: dict) -> None:
    try:
        with open(path, "w", encoding="utf-8") as fp:
            json.dump(payload, fp, ensure_ascii=False)
        os.chmod(path, 0o640)
    except OSError:
        pass


def main(argv: list[str]) -> int:
    if len(argv) < 4:
        sys.stderr.write("usage: mihomo_health_check.sh <uuid> <profile_name> <mode>\n")
        return 2
    uuid = argv[1]
    profile_name = argv[2]
    mode = argv[3] if argv[3] in ("quick", "full") else "quick"

    job_file = f"/tmp/mihomo-health-{uuid}.json"

    try:
        root = _config_xml_root()
    except (ET.ParseError, OSError) as e:
        _write_progress(job_file, {"state": "failed", "message": f"config.xml: {e}"})
        return 1

    host, port, secret = _read_controller(root)
    test_url, timeout_ms = _read_test_settings(root)

    profile_path = os.path.join(PROFILES_DIR, profile_name + ".yaml")
    proxies = _proxies_from_profile(profile_path, mode)

    total = len(proxies)
    alive: list[dict] = []
    dead: list[str] = []
    done = 0
    _write_progress(job_file, {
        "state": "running",
        "progress": {"done": 0, "total": total},
        "result": None,
        "started": int(time.time()),
    })

    if total == 0:
        _write_progress(job_file, {
            "state": "done",
            "progress": {"done": 0, "total": 0},
            "result": {"alive": 0, "dead": 0, "dead_list": [], "alive_list": []},
        })
        return 0

    with concurrent.futures.ThreadPoolExecutor(max_workers=BATCH_CONCURRENCY) as pool:
        futures = [pool.submit(_delay_request, host, port, secret, name, test_url, timeout_ms)
                   for name in proxies]
        for fut in concurrent.futures.as_completed(futures):
            name, latency = fut.result()
            if latency is None:
                dead.append(name)
            else:
                alive.append({"name": name, "delay_ms": latency})
            done += 1
            # Throttle progress writes — every node or every second.
            _write_progress(job_file, {
                "state": "running",
                "progress": {"done": done, "total": total},
                "result": None,
            })

    _write_progress(job_file, {
        "state": "done",
        "progress": {"done": done, "total": total},
        "result": {
            "alive": len(alive),
            "dead": len(dead),
            "alive_list": alive,
            "dead_list": dead,
        },
    })
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception as e:  # noqa: BLE001 — last-ditch progress
        try:
            uuid = sys.argv[1] if len(sys.argv) > 1 else "unknown"
            _write_progress(f"/tmp/mihomo-health-{uuid}.json",
                            {"state": "failed", "message": str(e)})
        finally:
            sys.exit(1)
