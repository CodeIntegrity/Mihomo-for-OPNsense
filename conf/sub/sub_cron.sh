#!/bin/bash
#
# sub_cron.sh — 订阅定时更新入口
#
# 由 configd action [sub-update] 每小时触发。
# 随机延迟 + flock 防并发，遍历 subs.json 触发到期订阅。

SUBS_JSON="/usr/local/etc/mihomo/subs.json"
SUB_SCRIPT="/usr/local/etc/mihomo/sub/sub.sh"
LOCK_FILE="/tmp/mihomo-sub-cron.lock"
LOG_FILE="/var/log/mihomo_sub.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [cron] $1" >> "$LOG_FILE"
}

# ── 随机延迟 0-30s 防机场 WAF ──
DELAY=$((RANDOM % 30))
sleep "$DELAY"

# ── flock 防并发 ──
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    log "上次订阅更新尚未完成，跳过本次 cron。"
    exit 0
fi

# ── 读取 subs.json ──
if [ ! -f "$SUBS_JSON" ]; then
    log "subs.json 不存在，跳过。"
    exit 0
fi

# ── 遍历订阅源 ──
CURRENT_TS=$(date +%s)

jq -r '.[] | select(.enabled == true) | "\(.id)|\(.update_interval_hours // 0)|\(.last_update // "")"' \
    "$SUBS_JSON" 2>/dev/null | while IFS='|' read -r sub_id interval last_update; do

    if [ "$interval" = "0" ] || [ -z "$interval" ]; then
        continue
    fi

    DUE=0
    if [ -z "$last_update" ] || [ "$last_update" = "null" ]; then
        DUE=1
    else
        # 计算距今是否超过 interval 小时
        LAST_TS=$(date -j -f "%Y-%m-%d %H:%M:%S" "$last_update" +%s 2>/dev/null || echo 0)
        if [ "$LAST_TS" -gt 0 ]; then
            ELAPSED=$(( (CURRENT_TS - LAST_TS) / 3600 ))
            if [ "$ELAPSED" -ge "$interval" ]; then
                DUE=1
            fi
        fi
    fi

    if [ "$DUE" = "1" ]; then
        log "触发订阅更新: $sub_id (间隔 ${interval}h)"
        bash "$SUB_SCRIPT" "$sub_id" &
    fi
done

wait
log "Cron 巡检完成。"
