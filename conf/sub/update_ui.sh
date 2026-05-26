#!/bin/bash
#
# update_ui.sh [check|update]
#
# Download latest Dashboard UI (metacubexd/zashboard/yacd) release zip.
# Progress written to /tmp/mihomo-update-ui.json

set -e

MODE="${1:-check}"
STATE_FILE="/tmp/mihomo-update-ui.json"
UI_DIR="/usr/local/etc/mihomo/ui"
BACKUP_DIR="/usr/local/etc/mihomo/backups"

# Default UI variant
UI_VARIANT="metacubexd"

case "$UI_VARIANT" in
    metacubexd) REPO="MetaCubeX/metacubexd" ;;
    zashboard)  REPO="Zephyruso/zashboard" ;;
    yacd)       REPO="haishanh/yacd" ;;
    *)          REPO="MetaCubeX/metacubexd" ;;
esac

update_state() {
    local tmp
    tmp=$(mktemp /tmp/mihomo-up.XXXXXX)
    cat > "$tmp" <<JSONEOF
{"state": "$1", "progress": $2, "message": "$3"}
JSONEOF
    mv "$tmp" "$STATE_FILE" 2>/dev/null || cp "$tmp" "$STATE_FILE"
    rm -f "$tmp"
}

if [ "$MODE" = "check" ]; then
    update_state "checking" 10 "Checking for UI updates..."
    RELEASE=$(curl -sf --max-time 10 -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null || echo "")

    if [ -z "$RELEASE" ]; then
        update_state "failed" 0 "Failed to check UI updates"
        exit 1
    fi

    LATEST_TAG=$(echo "$RELEASE" | jq -r '.tag_name' 2>/dev/null)
    update_state "done" 100 "Latest: $LATEST_TAG ($UI_VARIANT)"
    exit 0
fi

# ── Update ──
update_state "downloading" 30 "Downloading dashboard UI..."

ASSET_URL=$(curl -sf --max-time 10 -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null | \
    jq -r '.assets[] | select(.name | test("zip$")) | .browser_download_url' 2>/dev/null | head -1)

if [ -z "$ASSET_URL" ]; then
    update_state "failed" 0 "UI zip asset not found"
    exit 2
fi

TMP_ZIP="/tmp/mihomo-ui.zip"
TMP_UI="/tmp/mihomo-ui-new"

curl -fL -k --max-time 120 -o "$TMP_ZIP" "$ASSET_URL" 2>/dev/null || {
    update_state "failed" 0 "Download failed"
    rm -f "$TMP_ZIP"
    exit 3
}

update_state "installing" 70 "Extracting and installing..."

rm -rf "$TMP_UI"
mkdir -p "$TMP_UI"

unzip -qo "$TMP_ZIP" -d "$TMP_UI" 2>/dev/null || {
    update_state "failed" 0 "Unzip failed"
    rm -rf "$TMP_ZIP" "$TMP_UI"
    exit 4
}

# Find the actual UI root (unzip may create subdirectory)
if [ -f "$TMP_UI/index.html" ]; then
    UI_ROOT="$TMP_UI"
elif [ -d "$TMP_UI/dist" ] && [ -f "$TMP_UI/dist/index.html" ]; then
    UI_ROOT="$TMP_UI/dist"
else
    # Find first subdirectory with index.html
    UI_ROOT=$(find "$TMP_UI" -name "index.html" -maxdepth 3 | head -1 | xargs dirname 2>/dev/null || echo "")
    if [ -z "$UI_ROOT" ]; then
        update_state "failed" 0 "Cannot find index.html in extracted files"
        rm -rf "$TMP_ZIP" "$TMP_UI"
        exit 5
    fi
fi

# Atomic directory replace
mkdir -p "$BACKUP_DIR"
BACKUP_UI="$BACKUP_DIR/ui.bak.$(date '+%Y%m%d_%H%M%S')"

if [ -d "$UI_DIR" ]; then
    mv "$UI_DIR" "$BACKUP_UI"
fi

mv "$UI_ROOT" "$UI_DIR"
chmod -R 755 "$UI_DIR"
chown -R root:www "$UI_DIR" 2>/dev/null || true

# Cleanup
rm -rf "$TMP_ZIP" "$TMP_UI"

update_state "done" 100 "Dashboard UI updated successfully"
