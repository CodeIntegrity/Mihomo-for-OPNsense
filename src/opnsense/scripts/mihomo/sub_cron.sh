#!/bin/sh
# sub_cron.sh — configd cron entry for subscription auto-update.
#
# Pipeline (mirrors design §5.5):
#   1. sleep $((RANDOM % 30)) — random jitter to avoid WAF stampede.
#   2. flock -n /tmp/mihomo-sub-cron.lock — single-instance guard.
#   3. For each subscription whose enabled=1 and (now - last_update) >= interval*3600,
#      invoke sub.sh <uuid> sequentially.
#
# POSIX sh + standard FreeBSD tools (jq/awk/xmllint optional — we use Python).
# Logs to /var/log/mihomo_sub.log (sub.sh appends its own lines per uuid).

set -u

CONFIG_PATH=/conf/config.xml
SCRIPT_DIR=/usr/local/opnsense/scripts/mihomo
LOG=/var/log/mihomo_sub.log
LOCK=/tmp/mihomo-sub-cron.lock

log() { printf '[%s sub-cron] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }

# ---- random jitter ---------------------------------------------------------
JITTER=$(awk -v seed=$$ 'BEGIN { srand(seed); print int(rand()*30) }')
sleep "$JITTER"

# ---- single-instance lock --------------------------------------------------
exec 9>"$LOCK"
if ! flock -n 9; then
    log "another cron is running, exiting"
    exit 0
fi

# ---- enumerate due subscriptions ------------------------------------------
# Use Python to read /conf/config.xml safely. Stdout = one uuid per line.
DUE=$(/usr/local/bin/python3 - <<'PY'
import os, time, xml.etree.ElementTree as ET

CONFIG = "/conf/config.xml"
try:
    root = ET.parse(CONFIG).getroot()
except Exception:
    raise SystemExit(0)

subs = root.find("./OPNsense/Mihomo/mihomo/subscriptions")
if subs is None:
    raise SystemExit(0)

now = int(time.time())
for sub in subs.findall("subscription"):
    if (sub.findtext("enabled") or "0").strip() != "1":
        continue
    interval = (sub.findtext("interval") or "").strip()
    try:
        ih = int(interval)
    except ValueError:
        ih = 0
    if ih <= 0:
        continue  # 0 = disabled

    last = (sub.findtext("last_update") or "").strip()
    last_ts = 0
    if last:
        try:
            # ISO 8601 UTC — parse with time.strptime.
            t = last.rstrip("Z")
            last_ts = int(time.mktime(time.strptime(t, "%Y-%m-%dT%H:%M:%S")))
        except (ValueError, OverflowError):
            last_ts = 0

    if (now - last_ts) >= ih * 3600:
        uuid = sub.get("uuid", "")
        if uuid:
            print(uuid)
PY
)

if [ -z "${DUE:-}" ]; then
    exit 0
fi

# ---- run each due subscription --------------------------------------------
for uuid in $DUE; do
    log "refreshing $uuid"
    "$SCRIPT_DIR/sub.sh" "$uuid" || log "refresh $uuid returned non-zero"
done
log "cron pass complete"
exit 0
