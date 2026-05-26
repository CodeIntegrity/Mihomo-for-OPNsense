#!/bin/bash
#
# update_geoip.sh [check|update]
#
# Download latest Country.mmdb from MetaCubeX/meta-rules-dat releases.
# Progress written to /tmp/mihomo-update-geoip.json

set -e

MODE="${1:-check}"
STATE_FILE="/tmp/mihomo-update-geoip.json"
MMDB_PATH="/usr/local/etc/mihomo/Country.mmdb"
BACKUP_DIR="/usr/local/etc/mihomo/backups"
REPO="MetaCubeX/meta-rules-dat"
CACHE_FILE="/tmp/mihomo-geoip-release.json"

update_state() {
    local tmp
    tmp=$(mktemp /tmp/mihomo-up.XXXXXX)
    cat > "$tmp" <<JSONEOF
{"state": "$1", "progress": $2, "message": "$3"}
JSONEOF
    mv "$tmp" "$STATE_FILE" 2>/dev/null || cp "$tmp" "$STATE_FILE"
    rm -f "$tmp"
}

CURRENT_DATE=$(date -r "$MMDB_PATH" '+%Y-%m-%d' 2>/dev/null || echo "unknown")

if [ "$MODE" = "check" ]; then
    update_state "checking" 10 "Checking for GeoIP updates..."
    RELEASE=$(curl -sf --max-time 10 -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null || echo "")

    if [ -z "$RELEASE" ]; then
        update_state "failed" 0 "Failed to check GeoIP updates"
        exit 1
    fi

    echo "$RELEASE" > "$CACHE_FILE"
    LATEST_TAG=$(echo "$RELEASE" | jq -r '.tag_name' 2>/dev/null)
    update_state "done" 100 "Latest: $LATEST_TAG (current: $CURRENT_DATE)"
    exit 0
fi

# ── Update ──
update_state "downloading" 30 "Downloading Country.mmdb..."

ASSET_URL=$(curl -sf --max-time 10 -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null | \
    jq -r '.assets[] | select(.name == "Country.mmdb") | .browser_download_url' 2>/dev/null | head -1)

if [ -z "$ASSET_URL" ]; then
    update_state "failed" 0 "Country.mmdb asset not found"
    exit 2
fi

TMP_MMDB="/tmp/Country.mmdb.new"
curl -fL -k --max-time 60 -o "$TMP_MMDB" "$ASSET_URL" 2>/dev/null || {
    update_state "failed" 0 "Download failed"
    rm -f "$TMP_MMDB"
    exit 3
}

# Verify file is valid (not HTML, reasonable size)
FILE_SIZE=$(wc -c < "$TMP_MMDB" | tr -d ' ')
if [ "$FILE_SIZE" -lt 100000 ]; then
    update_state "failed" 0 "Downloaded file too small ($FILE_SIZE bytes)"
    rm -f "$TMP_MMDB"
    exit 4
fi

update_state "installing" 80 "Installing..."

# Backup
mkdir -p "$BACKUP_DIR"
cp "$MMDB_PATH" "$BACKUP_DIR/Country.mmdb.bak.$(date '+%Y%m%d_%H%M%S')" 2>/dev/null || true

# Replace
mv "$TMP_MMDB" "$MMDB_PATH"
chmod 640 "$MMDB_PATH"
chown root:www "$MMDB_PATH" 2>/dev/null || true

# Hot reload geo
CONTROLLER=$(awk '/^external-controller:/ {print $2}' /usr/local/etc/mihomo/base.yaml 2>/dev/null | tr -d "'\"" || echo "")
SECRET=$(awk '/^secret:/ {print $2}' /usr/local/etc/mihomo/base.yaml 2>/dev/null | tr -d "'\"" || echo "")

if [ -n "$CONTROLLER" ] && [ -n "$SECRET" ]; then
    curl -sf --max-time 5 -X PUT -H "Authorization: Bearer $SECRET" \
        "http://${CONTROLLER}/configs/geo" >/dev/null 2>&1 && \
        update_state "done" 100 "GeoIP updated successfully" || \
        update_state "done" 100 "GeoIP updated (reload via restart needed)"
else
    update_state "done" 100 "GeoIP updated (restart mihomo to apply)"
fi
