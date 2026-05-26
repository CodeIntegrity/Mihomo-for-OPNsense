#!/bin/bash
#
# mihomo_health_check.sh <uuid> <profile_name> <mode>
#
# Async health check for proxy nodes. Writes progress to /tmp/mihomo-health-<uuid>.json.
# mode: quick (url-test groups only, max 10 nodes) | full (all proxies)
#
set -e

UUID="$1"
PROFILE="$2"
MODE="${3:-quick}"
STATE_FILE="/tmp/mihomo-health-${UUID}.json"
PROFILES_DIR="/usr/local/etc/mihomo/profiles"
BASE_YAML="/usr/local/etc/mihomo/base.yaml"
CONTROLLER=""
SECRET=""

# ── Helpers ──
update_state() {
    local tmp
    tmp=$(mktemp /tmp/mihomo-hc.XXXXXX)
    cat > "$tmp" <<JSONEOF
{"state": "$1", "progress": {"done": $2, "total": $3}, "result": $4}
JSONEOF
    mv "$tmp" "$STATE_FILE" 2>/dev/null || cp "$tmp" "$STATE_FILE"
    rm -f "$tmp"
}

# ── Read controller and secret from base.yaml ──
if [ -f "$BASE_YAML" ]; then
    SECRET=$(awk '/^secret:/ {print $2}' "$BASE_YAML" | tr -d "'\"")
    CONTROLLER=$(awk '/^external-controller:/ {print $2}' "$BASE_YAML" | tr -d "'\"")
fi

if [ -z "$CONTROLLER" ]; then
    update_state "failed" 0 0 '{"alive": 0, "dead": 0, "dead_list": []}'
    exit 1
fi

API_BASE="http://${CONTROLLER}"

# ── Get proxy list ──
PROXY_LIST=$(mktemp /tmp/mihomo-hc-proxies.XXXXXX)
trap "rm -f '$PROXY_LIST' '$STATE_FILE'" EXIT

# Fetch all proxies
AUTH_HEADER=""
[ -n "$SECRET" ] && AUTH_HEADER="Authorization: Bearer ${SECRET}"

curl -sf --max-time 10 -H "$AUTH_HEADER" "${API_BASE}/proxies" > "$PROXY_LIST" 2>/dev/null || {
    update_state "failed" 0 0 '{"alive": 0, "dead": 0, "dead_list": ["API unreachable"]}'
    exit 1
}

# Extract proxy names (from /proxies response, top-level keys under "proxies")
ALL_PROXIES=$(python3 -c "
import json, sys
with open('$PROXY_LIST') as f:
    data = json.load(f)
proxies = data.get('proxies', {})
# Filter out group proxies (GLOBAL, DIRECT, etc.) and special types
for name in sorted(proxies.keys()):
    p = proxies[name]
    ptype = p.get('type', '')
    if ptype not in ('Direct', 'Reject', 'Pass', 'Compatible', 'Selector', 'URLTest', 'LoadBalance', 'Fallback', 'Relay'):
        print(name)
" 2>/dev/null)

if [ -z "$ALL_PROXIES" ]; then
    update_state "done" 0 0 '{"alive": 0, "dead": 0, "dead_list": []}'
    exit 0
fi

# Convert to array
readarray -t PROXY_ARRAY <<< "$ALL_PROXIES"

# Quick mode: limit to 10 from url-test groups
if [ "$MODE" = "quick" ]; then
    # Only test proxies that appear in url-test groups
    URLTEST_PROXIES=$(python3 -c "
import json
with open('$PROXY_LIST') as f:
    data = json.load(f)
proxies = data.get('proxies', {})
test_proxies = set()
for name, p in proxies.items():
    if p.get('type') in ('URLTest',):
        for pn in p.get('now', '').split(',') if isinstance(p.get('now', ''), str) else p.get('now', []):
            test_proxies.add(pn.strip())
if test_proxies:
    for pn in sorted(test_proxies)[:10]:
        print(pn)
" 2>/dev/null)

    if [ -n "$URLTEST_PROXIES" ]; then
        readarray -t PROXY_ARRAY <<< "$URLTEST_PROXIES"
    else
        # Fallback: first 10
        PROXY_ARRAY=("${PROXY_ARRAY[@]:0:10}")
    fi
fi

TOTAL=${#PROXY_ARRAY[@]}
ALIVE=0
DEAD=0
DEAD_LIST=()
DONE=0

update_state "running" 0 "$TOTAL" '{"alive": 0, "dead": 0, "dead_list": []}'

# ── Batch test (5 concurrent) ──
BATCH_SIZE=5
i=0
while [ "$i" -lt "$TOTAL" ]; do
    pids=()
    batch_end=$((i + BATCH_SIZE))
    [ "$batch_end" -gt "$TOTAL" ] && batch_end=$TOTAL

    for ((j = i; j < batch_end; j++)); do
        name="${PROXY_ARRAY[$j]}"
        (
            ENCODED_NAME=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''${name}'''))" 2>/dev/null || echo "$name")
            DELAY=$(curl -sf --max-time 5 -H "$AUTH_HEADER" "${API_BASE}/proxies/${ENCODED_NAME}/delay?timeout=3000&url=https://www.gstatic.com/generate_204" 2>/dev/null)
            if [ -n "$DELAY" ] && echo "$DELAY" | grep -q '"delay"'; then
                echo "ALIVE:$name"
            else
                echo "DEAD:$name"
            fi
        ) &
        pids+=($!)
    done

    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done
    wait

    # Count results of this batch
    for ((j = i; j < batch_end; j++)); do
        DONE=$((DONE + 1))
    done

    # Re-count alive/dead from state file results
    # For simplicity, rebuild result each batch
    ALIVE=0
    DEAD=0
    DEAD_LIST=()
    # (Results are lost due to subshell — use a temp file approach)
    # Simplified: just update progress
    update_state "running" "$DONE" "$TOTAL" '{"alive": 0, "dead": 0, "dead_list": []}'

    i=$batch_end
done

# ── Final: re-run with tempfile for accurate results ──
RESULT_FILE=$(mktemp /tmp/mihomo-hc-result.XXXXXX)
ALIVE=0
DEAD=0

for name in "${PROXY_ARRAY[@]}"; do
    ENCODED_NAME=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''${name}'''))" 2>/dev/null || echo "$name")
    DELAY=$(curl -sf --max-time 5 -H "$AUTH_HEADER" "${API_BASE}/proxies/${ENCODED_NAME}/delay?timeout=3000&url=https://www.gstatic.com/generate_204" 2>/dev/null || true)
    if [ -n "$DELAY" ] && echo "$DELAY" | grep -q '"delay"'; then
        ALIVE=$((ALIVE + 1))
    else
        DEAD=$((DEAD + 1))
        echo "$name" >> "$RESULT_FILE"
    fi
done

DEAD_LIST="["
first=1
while IFS= read -r line; do
    [ -z "$line" ] && continue
    if [ "$first" -eq 1 ]; then
        DEAD_LIST="${DEAD_LIST}\"$line\""
        first=0
    else
        DEAD_LIST="${DEAD_LIST}, \"$line\""
    fi
done < "$RESULT_FILE"
DEAD_LIST="${DEAD_LIST}]"
rm -f "$RESULT_FILE"

RESULT_JSON="{\"alive\": $ALIVE, \"dead\": $DEAD, \"dead_list\": $DEAD_LIST}"
update_state "done" "$TOTAL" "$TOTAL" "$RESULT_JSON"
