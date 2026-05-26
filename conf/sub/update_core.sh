#!/bin/bash
#
# update_core.sh [check|update]
#
# Mihomo core binary update.
# check: only check latest version
# update: download → SHA256 → smoke test → backup → replace → restart
# Progress written to /tmp/mihomo-update-core.json

set -e

MODE="${1:-check}"
STATE_FILE="/tmp/mihomo-update-core.json"
CACHE_FILE="/tmp/mihomo-latest-release.json"
BIN_PATH="/usr/local/bin/mihomo"
BACKUP_DIR="/usr/local/etc/mihomo/backups"
REPO="MetaCubeX/mihomo"
MIRROR=""
TOKEN=""

update_state() {
    local tmp
    tmp=$(mktemp /tmp/mihomo-up.XXXXXX)
    cat > "$tmp" <<JSONEOF
{"state": "$1", "progress": $2, "message": "$3"}
JSONEOF
    mv "$tmp" "$STATE_FILE" 2>/dev/null || cp "$tmp" "$STATE_FILE"
    rm -f "$tmp"
}

# ── Get current version ──
CURRENT_VER=$("$BIN_PATH" -v 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
echo "Current version: $CURRENT_VER"

# ── Fetch latest release ──
# Read mirror/token from base.yaml if available
BASE_YAML="/usr/local/etc/mihomo/base.yaml"
if [ -f "$BASE_YAML" ]; then
    MIRROR=$(awk '/^github-mirror:/ {print $2}' "$BASE_YAML" | tr -d "'\"" 2>/dev/null || echo "")
    TOKEN=$(awk '/^github-token:/ {print $2}' "$BASE_YAML" | tr -d "'\"" 2>/dev/null || echo "")
fi

API_URL="https://api.github.com/repos/${REPO}/releases/latest"
if [ -n "$MIRROR" ]; then
    API_URL="${MIRROR}${API_URL}"
fi

AUTH_HEADER=""
[ -n "$TOKEN" ] && AUTH_HEADER="Authorization: Bearer ${TOKEN}"

# Check cache (1h TTL)
if [ -f "$CACHE_FILE" ] && [ "$MODE" = "check" ]; then
    CACHE_AGE=$(($(date +%s) - $(stat -f %m "$CACHE_FILE" 2>/dev/null || stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0)))
    if [ "$CACHE_AGE" -lt 3600 ]; then
        LATEST_VER=$(jq -r '.tag_name' "$CACHE_FILE" 2>/dev/null || echo "")
        echo "Latest (cached): $LATEST_VER"
        update_state "done" 100 "Latest: $LATEST_VER (current: $CURRENT_VER)"
        exit 0
    fi
fi

update_state "checking" 10 "Checking GitHub for latest release..."
RELEASE=$(curl -sf --max-time 10 -H "$AUTH_HEADER" -H "Accept: application/vnd.github+json" "$API_URL" 2>/dev/null || echo "")

if [ -z "$RELEASE" ]; then
    update_state "failed" 0 "Failed to fetch release info from GitHub"
    exit 1
fi

echo "$RELEASE" > "$CACHE_FILE"

LATEST_VER=$(echo "$RELEASE" | jq -r '.tag_name' 2>/dev/null)
echo "Latest version: $LATEST_VER"

if [ "$MODE" = "check" ]; then
    update_state "done" 100 "Latest: $LATEST_VER (current: $CURRENT_VER)"
    exit 0
fi

# ── Mode: update ──
if [ "$LATEST_VER" = "$CURRENT_VER" ]; then
    update_state "done" 100 "Already up to date ($CURRENT_VER)"
    exit 0
fi

# Find freebsd-amd64 asset
ASSET_URL=$(echo "$RELEASE" | jq -r '.assets[] | select(.name | test("freebsd-amd64.*\\.gz")) | .browser_download_url' 2>/dev/null | head -1)
SHA256_URL=$(echo "$RELEASE" | jq -r '.assets[] | select(.name | test("\\.sha256$")) | .browser_download_url' 2>/dev/null | head -1)

if [ -z "$ASSET_URL" ]; then
    update_state "failed" 0 "No FreeBSD amd64 asset found"
    exit 2
fi

update_state "downloading" 30 "Downloading mihomo $LATEST_VER..."

TMP_DIR="/tmp/mihomo-update-$LATEST_VER"
mkdir -p "$TMP_DIR"

GZ_FILE="$TMP_DIR/mihomo.gz"
SHA256_FILE="$TMP_DIR/mihomo.sha256"
NEW_BIN="$TMP_DIR/mihomo"

curl -fL -k --max-time 120 -o "$GZ_FILE" "$ASSET_URL" 2>/dev/null || {
    update_state "failed" 0 "Download failed"
    rm -rf "$TMP_DIR"
    exit 3
}

# Download SHA256 if available
if [ -n "$SHA256_URL" ]; then
    curl -fL -k --max-time 10 -o "$SHA256_FILE" "$SHA256_URL" 2>/dev/null || true
fi

update_state "verifying" 60 "Verifying SHA256..."

# SHA256 check
if [ -s "$SHA256_FILE" ]; then
    EXPECTED=$(grep -oE '^[a-f0-9]{64}' "$SHA256_FILE" | head -1 || echo "")
    if [ -n "$EXPECTED" ]; then
        ACTUAL=$(sha256 -q "$GZ_FILE" 2>/dev/null || sha256sum "$GZ_FILE" 2>/dev/null | awk '{print $1}')
        if [ "$EXPECTED" != "$ACTUAL" ]; then
            update_state "failed" 0 "SHA256 mismatch"
            rm -rf "$TMP_DIR"
            exit 4
        fi
    fi
fi

# gunzip
gunzip -f "$GZ_FILE" 2>/dev/null || {
    update_state "failed" 0 "gunzip failed"
    rm -rf "$TMP_DIR"
    exit 5
}
chmod +x "$NEW_BIN"

# Smoke test
update_state "verifying" 80 "Smoke test..."
SMOKE_VER=$("$NEW_BIN" -v 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
if [ "$SMOKE_VER" != "$LATEST_VER" ]; then
    update_state "failed" 0 "Smoke test failed: expected $LATEST_VER, got $SMOKE_VER"
    rm -rf "$TMP_DIR"
    exit 6
fi

# Backup
update_state "installing" 90 "Installing..."
BACKUP_FILE="$BACKUP_DIR/mihomo.bak.$(date '+%Y%m%d_%H%M%S')"
cp "$BIN_PATH" "$BACKUP_FILE" 2>/dev/null || true

# Atomic replace
mv "$NEW_BIN" "$BIN_PATH"

# Restart
/usr/local/sbin/configctl mihomo restart >/dev/null 2>&1 || true

# Poll 10s
update_state "installing" 95 "Waiting for service to stabilize..."
for i in $(seq 1 20); do
    sleep 0.5
    if /usr/local/sbin/configctl mihomo status 2>&1 | grep -q "is running"; then
        update_state "done" 100 "Updated to $LATEST_VER successfully"
        rm -rf "$TMP_DIR"
        exit 0
    fi
done

# Auto-rollback
echo "Service not running after 10s, rolling back..."
cp "$BACKUP_FILE" "$BIN_PATH"
/usr/local/sbin/configctl mihomo restart >/dev/null 2>&1 || true
update_state "done" 100 "Rolled back to previous version (update to $LATEST_VER failed)"
rm -rf "$TMP_DIR"
