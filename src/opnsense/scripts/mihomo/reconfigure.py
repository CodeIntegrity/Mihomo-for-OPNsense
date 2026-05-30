#!/usr/local/bin/python3
"""Mihomo reconfigure — configd action `reconfigure`.

Pipeline:
    1. Read OPNsense config.xml -> render base.yaml (top-level Mihomo keys).
    2. Read /usr/local/etc/mihomo/override.yaml (if present).
    3. Read /usr/local/etc/mihomo/profiles/<active>.yaml (if present).
    4. Merge base + override + profile per the convention keys
       (prepend-rules / append-rules / append-proxies / prepend-proxy-groups /
        append-proxy-groups), with deep-merge for remaining top-level keys.
    5. Write /tmp/mihomo-config.yaml.new and validate with `mihomo -t -f`.
    6. On success: atomic rename to /usr/local/etc/mihomo/config.yaml, then
       PUT /configs?force=true to hot-reload, falling back to
       `configctl mihomo restart` on failure.

Exit code 0 + "OK" printed on success. Any other state prints an error line
and exits non-zero so the PHP caller can surface the failure.

This script is intentionally self-contained — only stdlib + PyYAML (shipped
on OPNsense via py-yaml).
"""

from __future__ import annotations

import errno
import fcntl
import http.client
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET

try:
    import yaml  # py-yaml; ships on OPNsense
except ImportError:  # pragma: no cover
    sys.stderr.write("FATAL: 需要 py-yaml（pkg install py311-yaml）\n")
    sys.exit(2)

CONFIG_XML = "/conf/config.xml"
MIHOMO_DIR = "/usr/local/etc/mihomo"
BASE_PATH = os.path.join(MIHOMO_DIR, "base.yaml")
OVERRIDE_PATH = os.path.join(MIHOMO_DIR, "override.yaml")
CONFIG_PATH = os.path.join(MIHOMO_DIR, "config.yaml")
PROFILES_DIR = os.path.join(MIHOMO_DIR, "profiles")
LOCK_PATH = "/tmp/mihomo-reconfigure.lock"
MIHOMO_BIN = "/usr/local/bin/mihomo"


# ---------------------------------------------------------------------------
# config.xml -> base.yaml
# ---------------------------------------------------------------------------

# Map of XML element name (snake_case) -> YAML key (hyphen-case).
_SNAKE_TO_HYPHEN = {
    "socks_port": "socks-port",
    "mixed_port": "mixed-port",
    "allow_lan": "allow-lan",
    "bind_address": "bind-address",
    "log_level": "log-level",
    "tcp_concurrent": "tcp-concurrent",
    "find_process_mode": "find-process-mode",
    "unified_delay": "unified-delay",
    "interface_name": "interface-name",
    "external_controller": "external-controller",
    "external_ui": "external-ui",
    "auto_route": "auto-route",
    "strict_route": "strict-route",
    "auto_detect_interface": "auto-detect-interface",
    "dns_hijack": "dns-hijack",
    "enhanced_mode": "enhanced-mode",
    "fake_ip_range": "fake-ip-range",
    "default_nameserver": "default-nameserver",
    "fake_ip_filter": "fake-ip-filter",
    "use_hosts": "use-hosts",
    "force_dns_mapping": "force-dns-mapping",
    "parse_pure_ip": "parse-pure-ip",
    "override_destination": "override-destination",
}

# Keys whose value is a CSV string in config.xml but a YAML list in mihomo.
_CSV_LIST_KEYS = {
    "dns_hijack",
    "default_nameserver",
    "nameserver",
    "fallback",
    "fake_ip_filter",
    "skip_domains",
}

# Boolean keys (config.xml stores "0"/"1").
_BOOL_KEYS = {
    "allow_lan", "ipv6", "tcp_concurrent", "unified_delay",
    "enable", "auto_route", "strict_route", "auto_detect_interface",
    "use_hosts",
    "force_dns_mapping", "parse_pure_ip", "override_destination",
}

# Integer keys.
_INT_KEYS = {
    "port", "socks_port", "mixed_port", "mtu",
    "health_check_timeout",
}


def _xml_key_to_yaml(name: str) -> str:
    return _SNAKE_TO_HYPHEN.get(name, name.replace("_", "-"))


def _coerce(name: str, raw: str):
    if raw is None:
        raw = ""
    if name in _BOOL_KEYS:
        return raw == "1" or raw.lower() == "true"
    if name in _INT_KEYS:
        try:
            return int(raw)
        except ValueError:
            return 0
    if name in _CSV_LIST_KEYS:
        return [s.strip() for s in raw.split(",") if s.strip()]
    return raw


def _parse_group(elem) -> dict:
    """Convert a <group> element into a dict suitable for YAML."""
    result: dict = {}
    for child in elem:
        tag = child.tag
        # Skip child containers we don't support generically (none for now).
        if len(child) > 0:
            # nested group — recurse
            result[_xml_key_to_yaml(tag)] = _parse_group(child)
            continue
        text = (child.text or "").strip()
        # Drop empty optional fields so YAML stays clean.
        if text == "" and tag not in _BOOL_KEYS and tag not in _INT_KEYS:
            continue
        result[_xml_key_to_yaml(tag)] = _coerce(tag, text)
    return result


def _sniff_ports_csv_to_list(csv: str) -> list:
    return [p.strip() for p in csv.split(",") if p.strip()]


def render_base_from_xml(root: ET.Element) -> dict:
    """Render mihomo base.yaml as a dict from the parsed config.xml root."""
    mhm = root.find("./OPNsense/Mihomo/mihomo")
    if mhm is None:
        # Fresh install — produce a sensible empty base.
        return {}

    base: dict = {}
    general = mhm.find("general")
    if general is not None:
        base.update(_parse_group(general))

    controller = mhm.find("controller")
    if controller is not None:
        base.update(_parse_group(controller))

    tun = mhm.find("tun")
    if tun is not None:
        base["tun"] = _parse_group(tun)

    dns = mhm.find("dns")
    if dns is not None:
        dns_dict = _parse_group(dns)
        # `hosts` is a multi-line "domain=ip" text field — convert to map.
        hosts_raw = dns_dict.pop("hosts", "")
        if isinstance(hosts_raw, str) and hosts_raw.strip():
            hosts = {}
            for line in hosts_raw.splitlines():
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if "=" in line:
                    k, v = line.split("=", 1)
                    hosts[k.strip()] = v.strip()
            if hosts:
                dns_dict["hosts"] = hosts
        base["dns"] = dns_dict

    sniffer = mhm.find("sniffer")
    if sniffer is not None:
        s = _parse_group(sniffer)
        # Reshape sniff_* ports to mihomo's `sniff:` map.
        sniff_map = {}
        for proto, key in (("HTTP", "sniff-http-ports"),
                           ("TLS",  "sniff-tls-ports"),
                           ("QUIC", "sniff-quic-ports")):
            ports = s.pop(key, "")
            if ports:
                sniff_map[proto] = {"ports": _sniff_ports_csv_to_list(ports),
                                    "override-destination": s.get("override-destination", True)}
        if sniff_map:
            s["sniff"] = sniff_map
        # `skip-domains` -> list
        skip = s.pop("skip-domains", [])
        if skip:
            s["skip-domain"] = skip
        base["sniffer"] = s

    return base


# ---------------------------------------------------------------------------
# Merge
# ---------------------------------------------------------------------------

CONVENTION_KEYS = {
    "prepend-rules", "append-rules",
    "append-proxies",
    "prepend-proxy-groups", "append-proxy-groups",
}


def _deep_merge(a: dict, b: dict) -> dict:
    """Recursive dict merge — b overrides a; lists are replaced (not concatenated)."""
    out = dict(a)
    for k, v in b.items():
        if k in out and isinstance(out[k], dict) and isinstance(v, dict):
            out[k] = _deep_merge(out[k], v)
        else:
            out[k] = v
    return out


def merge_all(base: dict, override: dict, profile: dict) -> dict:
    """Three-way merge per design Section 1.5 convention.

    profile contributes proxies / proxy-groups / rules.
    override's prepend-* / append-* keys reshape those lists.
    All remaining top-level keys: profile overrides base, then override
    deep-merges on top.
    """
    if base is None:
        base = {}
    if override is None:
        override = {}
    if profile is None:
        profile = {}

    # Step 1: combine base + non-convention override (deep merge).
    plain_override = {k: v for k, v in override.items() if k not in CONVENTION_KEYS}
    merged = _deep_merge(base, plain_override)

    # Step 2: pull profile's proxies / groups / rules in.
    proxies = list(profile.get("proxies") or [])
    proxy_groups = list(profile.get("proxy-groups") or [])
    rules = list(profile.get("rules") or [])

    # Step 3: apply override's convention keys.
    prepend_rules = list(override.get("prepend-rules") or [])
    append_rules = list(override.get("append-rules") or [])
    append_proxies = list(override.get("append-proxies") or [])
    prepend_groups = list(override.get("prepend-proxy-groups") or [])
    append_groups = list(override.get("append-proxy-groups") or [])

    final_proxies = proxies + append_proxies
    final_groups = prepend_groups + proxy_groups + append_groups
    final_rules = prepend_rules + rules + append_rules

    if final_proxies:
        merged["proxies"] = final_proxies
    if final_groups:
        merged["proxy-groups"] = final_groups
    if final_rules:
        merged["rules"] = final_rules

    # Step 4: profile may also carry top-level keys (rare); deep merge them
    # without overwriting proxies/groups/rules we just composed.
    extra_profile = {k: v for k, v in profile.items()
                     if k not in ("proxies", "proxy-groups", "rules")}
    if extra_profile:
        merged = _deep_merge(merged, extra_profile)

    return merged


# ---------------------------------------------------------------------------
# IO helpers
# ---------------------------------------------------------------------------

def _read_yaml(path: str) -> dict:
    if not os.path.isfile(path):
        return {}
    with open(path, "r", encoding="utf-8") as fp:
        data = yaml.safe_load(fp) or {}
    if not isinstance(data, dict):
        raise RuntimeError(f"{path} 未解析为映射结构")
    return data


def _atomic_write(path: str, content: str) -> None:
    fd, tmp = tempfile.mkstemp(prefix=".cfg.", dir=os.path.dirname(path) or ".")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fp:
            fp.write(content)
        os.chmod(tmp, 0o640)
        try:
            os.chown(tmp, 0, _gid("www"))
        except (PermissionError, KeyError):
            pass
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _gid(name: str) -> int:
    import grp
    return grp.getgrnam(name).gr_gid


def _active_profile_name(root: ET.Element) -> str:
    n = root.find("./OPNsense/Mihomo/mihomo/state/active_profile")
    if n is not None and (n.text or "").strip():
        return n.text.strip()
    return "default"


def _mihomo_validate(path: str) -> tuple[bool, str]:
    """Run `mihomo -t -f path` and capture combined stdout/stderr."""
    if not os.path.exists(MIHOMO_BIN):
        return True, "未找到 mihomo 二进制，跳过校验"
    try:
        res = subprocess.run(
            [MIHOMO_BIN, "-d", MIHOMO_DIR, "-t", "-f", path],
            capture_output=True, text=True, timeout=10,
        )
    except subprocess.TimeoutExpired as e:
        return False, f"mihomo -t 校验超时：{e}"
    out = (res.stdout or "") + (res.stderr or "")
    return res.returncode == 0, out.strip()


def _api_reload() -> tuple[bool, str]:
    """PUT /configs?force=true with body {path: CONFIG_PATH}.

    Returns (ok, message). Caller falls back to restart if not ok.
    """
    # Read controller bind + secret from config.xml so we follow user changes.
    try:
        root = ET.parse(CONFIG_XML).getroot()
    except Exception as e:
        return False, f"无法解析 {CONFIG_XML}：{e}"
    ec_node = root.find("./OPNsense/Mihomo/mihomo/controller/external_controller")
    secret_node = root.find("./OPNsense/Mihomo/mihomo/controller/secret")
    bind = (ec_node.text or "").strip() if ec_node is not None else "127.0.0.1:9090"
    secret = (secret_node.text or "").strip() if secret_node is not None else ""
    bind = bind.replace("0.0.0.0", "127.0.0.1")
    host, _, port = bind.partition(":")
    try:
        conn = http.client.HTTPConnection(host or "127.0.0.1", int(port or "9090"), timeout=5)
        headers = {"Content-Type": "application/json"}
        if secret:
            headers["Authorization"] = f"Bearer {secret}"
        body = json.dumps({"path": CONFIG_PATH})
        conn.request("PUT", "/configs?force=true", body=body, headers=headers)
        resp = conn.getresponse()
        data = resp.read().decode("utf-8", errors="replace")
        conn.close()
    except (ConnectionRefusedError, OSError) as e:
        return False, f"重载连接失败：{e}"
    if resp.status >= 200 and resp.status < 300:
        # Brief settle to avoid premature status checks
        time.sleep(1.5)
        return True, "已通过 API 重载"
    return False, f"重载 HTTP {resp.status}：{data}"


def _service_restart() -> tuple[bool, str]:
    """Fallback: `service mihomo onerestart` (rc.d script)."""
    try:
        res = subprocess.run(
            ["/usr/local/etc/rc.d/mihomo", "onerestart"],
            capture_output=True, text=True, timeout=20,
        )
    except subprocess.TimeoutExpired as e:
        return False, f"重启超时：{e}"
    out = (res.stdout or "") + (res.stderr or "")
    return res.returncode == 0, out.strip()


def _acquire_lock():
    fp = open(LOCK_PATH, "w")
    try:
        fcntl.flock(fp, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        sys.stderr.write("FAIL 已有 reconfigure 任务进行中\n")
        sys.exit(3)
    return fp


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main() -> int:
    lock = _acquire_lock()
    try:
        root = ET.parse(CONFIG_XML).getroot()
    except (ET.ParseError, OSError) as e:
        print(f"FAIL 无法读取 {CONFIG_XML}：{e}")
        return 1

    # 1. Render base.yaml.
    base_dict = render_base_from_xml(root)
    base_yaml = yaml.safe_dump(base_dict, allow_unicode=True, sort_keys=False)
    try:
        _atomic_write(BASE_PATH, base_yaml)
    except OSError as e:
        print(f"FAIL 写入 base.yaml 失败：{e}")
        return 1

    # 2/3. Read override + active profile.
    override_dict = _read_yaml(OVERRIDE_PATH) if os.path.isfile(OVERRIDE_PATH) else {}
    active_name = _active_profile_name(root)
    profile_path = os.path.join(PROFILES_DIR, f"{active_name}.yaml")
    profile_dict = _read_yaml(profile_path) if os.path.isfile(profile_path) else {}

    # 4. Merge.
    merged = merge_all(base_dict, override_dict, profile_dict)
    merged_yaml = yaml.safe_dump(merged, allow_unicode=True, sort_keys=False)

    # 5. Validate.
    tmp_path = "/tmp/mihomo-config.yaml.new"
    try:
        _atomic_write(tmp_path, merged_yaml)
    except OSError as e:
        print(f"FAIL 写入临时配置失败：{e}")
        return 1

    ok, msg = _mihomo_validate(tmp_path)
    if not ok:
        print(f"FAIL mihomo 配置校验失败：\n{msg}")
        return 1

    # 6. Commit + reload.
    try:
        # Back up existing config.yaml for safety.
        if os.path.isfile(CONFIG_PATH):
            shutil.copy2(CONFIG_PATH, CONFIG_PATH + ".bak." + time.strftime("%Y%m%d_%H%M%S"))
        shutil.move(tmp_path, CONFIG_PATH)
        try:
            os.chown(CONFIG_PATH, 0, _gid("www"))
        except (PermissionError, KeyError):
            pass
        os.chmod(CONFIG_PATH, 0o640)
    except OSError as e:
        print(f"FAIL 提交 config.yaml 失败：{e}")
        return 1

    ok, msg = _api_reload()
    if not ok:
        # Fallback to service restart.
        ok2, msg2 = _service_restart()
        if ok2:
            print(f"OK 配置已应用，通过重启回退完成重载（{msg}）")
            return 0
        print(f"FAIL 配置已写入但重载失败：api=（{msg}） restart=（{msg2}）")
        return 1

    print(f"OK 配置已应用（{msg}）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
