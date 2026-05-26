#!/bin/bash
#
# sub.sh <sub_id> — 参数化订阅抓取脚本
#
# 从 subs.json 读取订阅源配置 → 下载 → 解析 → 过滤 → 生成 profile
# 写入日志到 /var/log/mihomo_sub.log

set -e

SUB_ID="${1:-}"
if [ -z "$SUB_ID" ]; then
    echo "Usage: sub.sh <sub_id>" >&2
    exit 1
fi

SUBS_JSON="/usr/local/etc/mihomo/subs.json"
PROFILES_DIR="/usr/local/etc/mihomo/profiles"
MIHOMO_DIR="/usr/local/etc/mihomo"
LOG_FILE="/var/log/mihomo_sub.log"
TMP_DIR="/tmp"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [sub_id=$SUB_ID] $1" >> "$LOG_FILE"
}

log "======== 开始订阅抓取 ========"

# ── 检查 jq ──
command -v jq >/dev/null 2>&1 || {
    log "错误: 缺少 jq"
    exit 1
}

# ── 读取 subs.json ──
if [ ! -f "$SUBS_JSON" ]; then
    log "错误: subs.json 不存在"
    exit 1
fi

SUB_DATA=$(jq -r --arg id "$SUB_ID" '.[] | select(.id == $id)' "$SUBS_JSON" 2>/dev/null)

if [ -z "$SUB_DATA" ] || [ "$SUB_DATA" = "null" ]; then
    log "错误: subs.json 中未找到 id=$SUB_ID"
    exit 1
fi

SUB_NAME=$(echo "$SUB_DATA" | jq -r '.name // empty')
SUB_URL=$(echo "$SUB_DATA" | jq -r '.url // empty')
SUB_UA=$(echo "$SUB_DATA" | jq -r '.user_agent // "clash-verge/v1.7.0"')
ACTIVE_PROFILE=""

# 检查当前激活的 profile
if [ -f "$MIHOMO_DIR/active.json" ]; then
    ACTIVE_PROFILE=$(jq -r '.profile // ""' "$MIHOMO_DIR/active.json" 2>/dev/null)
fi

PROFILE_NAME="sub-${SUB_NAME}"

# ── 1. 更新状态为 updating ──
jq --arg id "$SUB_ID" '
    map(if .id == $id then .last_status = "updating" | .last_update = (now | strftime("%Y-%m-%d %H:%M:%S")) else . end)
' "$SUBS_JSON" > "$SUBS_JSON.tmp" && mv "$SUBS_JSON.tmp" "$SUBS_JSON"
log "状态: updating"

# ── 2. 下载 ──
TMP_RAW="$TMP_DIR/sub-${SUB_ID}.raw"
log "下载: $SUB_URL"
if ! curl -fL -k -sS --retry 3 -m 30 \
    -H "User-Agent: ${SUB_UA}" \
    -o "$TMP_RAW" "$SUB_URL"; then
    log "错误: 下载失败"

    jq --arg id "$SUB_ID" '
        map(if .id == $id then .last_status = "failed" | .last_error = "Download failed" else . end)
    ' "$SUBS_JSON" > "$SUBS_JSON.tmp" && mv "$SUBS_JSON.tmp" "$SUBS_JSON"
    rm -f "$TMP_RAW"
    exit 2
fi

RAW_SIZE=$(wc -c < "$TMP_RAW" | tr -d ' ')
log "下载完成: ${RAW_SIZE} 字节"

# 检查是否为 HTML
if head -n 20 "$TMP_RAW" | grep -Eiq '^(<!doctype html|<html|<head|<body)'; then
    log "错误: 返回内容为 HTML，订阅可能失效"
    jq --arg id "$SUB_ID" '
        map(if .id == $id then .last_status = "failed" | .last_error = "Response is HTML" else . end)
    ' "$SUBS_JSON" > "$SUBS_JSON.tmp" && mv "$SUBS_JSON.tmp" "$SUBS_JSON"
    rm -f "$TMP_RAW"
    exit 3
fi

# ── 3. 提取 proxies/proxy-groups/rules ──
TMP_PROFILE="$TMP_DIR/sub-${SUB_ID}.yaml"

awk '
BEGIN { capture = 0 }
/^proxies:/ || /^proxy-groups:/ || /^rules:/ { capture = 1 }
/^[a-zA-Z-]+:/ && !/^proxies:/ && !/^proxy-groups:/ && !/^rules:/ {
    if (capture) capture = 0
}
capture { print }
' "$TMP_RAW" > "$TMP_PROFILE"

NODE_COUNT=$(grep -c '^  - name:' "$TMP_PROFILE" 2>/dev/null || echo 0)
log "提取节点数: $NODE_COUNT"

# ── 4. 校验 ──
TMP_TEST="/tmp/sub-${SUB_ID}-validate.yaml"
cat > "$TMP_TEST" <<TESTEOF
port: 7890
socks-port: 7891
TESTEOF
cat "$TMP_PROFILE" >> "$TMP_TEST"

if /usr/local/bin/mihomo -d /tmp -t -f "$TMP_TEST" >/dev/null 2>&1; then
    log "校验通过"
else
    log "错误: 校验失败"
    jq --arg id "$SUB_ID" '
        map(if .id == $id then .last_status = "failed" | .last_error = "Validation failed" else . end)
    ' "$SUBS_JSON" > "$SUBS_JSON.tmp" && mv "$SUBS_JSON.tmp" "$SUBS_JSON"
    rm -f "$TMP_RAW" "$TMP_PROFILE" "$TMP_TEST"
    exit 4
fi

# ── 5. 写入 profile ──
mkdir -p "$PROFILES_DIR"
PROFILE_FILE="$PROFILES_DIR/${PROFILE_NAME}.yaml"
cp "$TMP_PROFILE" "$PROFILE_FILE"
log "Profile 已写入: $PROFILE_FILE"

# ── 6. 写 meta.json ──
cat > "$PROFILES_DIR/${PROFILE_NAME}.meta.json" <<METAEOF
{
    "source_type": "subscription",
    "sub_id": "$SUB_ID",
    "source_url": "$SUB_URL",
    "last_update": "$(date '+%Y-%m-%d %H:%M:%S')",
    "node_count": $NODE_COUNT
}
METAEOF

# ── 7. 更新 subs.json 状态 ──
jq --arg id "$SUB_ID" --arg ts "$(date '+%Y-%m-%d %H:%M:%S')" '
    map(if .id == $id then
        .last_status = "done" |
        .last_update = $ts |
        del(.last_error)
    else . end)
' "$SUBS_JSON" > "$SUBS_JSON.tmp" && mv "$SUBS_JSON.tmp" "$SUBS_JSON"
log "状态: done"

# ── 8. 如果 active 则重新合并并 reload ──
if [ "$ACTIVE_PROFILE" = "$PROFILE_NAME" ]; then
    log "当前激活 profile，重新合并 config.yaml..."
    php -r "
    require_once '/usr/local/www/includes/mihomo_lib.inc.php';
    \$base = file_exists(MIHOMO_BASE_YAML) ? mihomoYamlParse(file_get_contents(MIHOMO_BASE_YAML)) : [];
    \$override = file_exists(MIHOMO_OVERRIDE_YAML) ? mihomoYamlParse(file_get_contents(MIHOMO_OVERRIDE_YAML)) : [];
    \$profile = file_exists('$PROFILE_FILE') ? mihomoYamlParse(file_get_contents('$PROFILE_FILE')) : [];
    \$merged = mergeAll(\$base, \$override, \$profile);
    \$yaml = mihomoYamlDump(\$merged);
    \$tmp = '/tmp/config.yaml.subupdate';
    file_put_contents(\$tmp, \$yaml, LOCK_EX);
    exec('/usr/local/bin/mihomo -d ' . escapeshellarg('$MIHOMO_DIR') . ' -t -f ' . escapeshellarg(\$tmp) . ' 2>&1', \$out, \$rc);
    if (\$rc === 0) {
        \$bak = MIHOMO_CONFIG_YAML . '.bak.' . date('Ymd_His');
        if (file_exists(MIHOMO_CONFIG_YAML)) copy(MIHOMO_CONFIG_YAML, \$bak);
        rename(\$tmp, MIHOMO_CONFIG_YAML);
        \$b = file_exists(MIHOMO_BASE_YAML) ? mihomoYamlParse(file_get_contents(MIHOMO_BASE_YAML)) : [];
        \$secret = \$b['secret'] ?? '';
        \$ctrl = \$b['external-controller'] ?? '';
        if (\$ctrl && \$secret) {
            \$ctx = stream_context_create(['http' => ['method' => 'PUT', 'header' => \"Authorization: Bearer \$secret\r\n\", 'timeout' => 5, 'ignore_errors' => true]]);
            @file_get_contents(\"http://{\$ctrl}/configs?force=true\", false, \$ctx);
            usleep(1500000);
        } else {
            exec('/usr/local/sbin/configctl mihomo restart');
        }
    } else {
        echo 'Validation failed: ' . implode(chr(10), \$out);
        unlink(\$tmp);
    }
    " >> "$LOG_FILE" 2>&1 || {
        log "PHP merge/reload 失败，fallback restart"
        /usr/local/sbin/configctl mihomo restart >> "$LOG_FILE" 2>&1 || true
    }
fi

# ── 9. 清理 ──
rm -f "$TMP_RAW" "$TMP_PROFILE" "$TMP_TEST"

log "======== 订阅抓取完成 ========"
