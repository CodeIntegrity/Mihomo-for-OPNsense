#!/bin/bash
#
# migrate.sh — Mihomo v2 配置迁移脚本
#
# 从旧版单文件 config.yaml 迁移到新版分层配置模型：
#   base.yaml + override.yaml + profiles/ + subs.json + active.json
#
# 幂等：检测 .migrated-v2 标志跳过。
# 失败：保留旧文件不动，拒绝注册新 UI。

set -e

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
CYAN="\033[36m"
RESET="\033[0m"

MIHOMO_DIR="/usr/local/etc/mihomo"
OLD_CONFIG="$MIHOMO_DIR/config.yaml"
BASE_YAML="$MIHOMO_DIR/base.yaml"
OVERRIDE_YAML="$MIHOMO_DIR/override.yaml"
PROFILES_DIR="$MIHOMO_DIR/profiles"
ACTIVE_JSON="$MIHOMO_DIR/active.json"
SUBS_JSON="$MIHOMO_DIR/subs.json"
BACKUPS_DIR="$MIHOMO_DIR/backups"
MIGRATED_FLAG="$MIHOMO_DIR/.migrated-v2"
MIGRATE_ERROR="/tmp/mihomo-migrate-error.txt"
SUB_ENV="$MIHOMO_DIR/sub/env"
LEGACY_PROFILE="legacy"

log_info()  { echo -e "${YELLOW}[INFO]${RESET} $1"; }
log_warn()  { echo -e "${CYAN}[WARN]${RESET} $1"; }
log_error() { echo -e "${RED}[ERROR]${RESET} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${RESET} $1"; }

# ── 幂等检查 ──
if [ -f "$MIGRATED_FLAG" ]; then
    log_info "已迁移（$MIGRATED_FLAG 存在），跳过。"
    exit 0
fi

log_info "======== Mihomo v2 配置迁移 ========"

# ── 确保必要目录 ──
mkdir -p "$PROFILES_DIR" "$BACKUPS_DIR"

# ── 0. 停止 mihomo ──
log_info "停止 mihomo 服务..."
/usr/local/sbin/configctl mihomo stop 2>/dev/null || true
sleep 2

# 确认已停止
if pgrep -f "/usr/local/bin/mihomo -d $MIHOMO_DIR" >/dev/null 2>&1; then
    log_warn "mihomo 进程仍在运行，强制终止..."
    pkill -f "/usr/local/bin/mihomo -d $MIHOMO_DIR" 2>/dev/null || true
    sleep 1
fi

# ── 1. 备份当前状态 ──
TS=$(date '+%Y%m%d_%H%M%S')
BACKUP_FILE="$BACKUPS_DIR/pre-upgrade-$TS.tar.gz"
log_info "备份当前配置到 $BACKUP_FILE ..."
tar -czf "$BACKUP_FILE" -C "$MIHOMO_DIR" . 2>/dev/null || {
    log_error "备份失败，终止迁移。"
    rm -f "$MIGRATE_ERROR"
    echo "Backup creation failed at $(date)" > "$MIGRATE_ERROR"
    exit 1
}
log_ok "备份完成"

# ── 2. 检查旧 config.yaml ──
if [ ! -f "$OLD_CONFIG" ]; then
    log_error "未找到 $OLD_CONFIG，无法迁移。"
    echo "Old config.yaml not found at $(date)" > "$MIGRATE_ERROR"
    exit 1
fi

# ── 3. 提取 base.yaml (基础设施字段) ──
log_info "提取 base.yaml（基础设施字段）..."

# 需要提取的顶层 key（general settings + tun + dns + sniffer + external
# 不包括 proxies / proxy-groups / rules / proxy-providers / rule-providers）
python3 -c "
import sys, re

with open('$OLD_CONFIG') as f:
    lines = f.readlines()

# Top-level keys that belong to infrastructure (not profile)
infra_keys = {
    'port', 'socks-port', 'mixed-port', 'mode', 'log-level',
    'allow-lan', 'bind-address', 'ipv6', 'tcp-concurrent',
    'find-process-mode', 'global-client-fingerprint', 'unified-delay',
    'interface-name', 'external-controller', 'external-ui', 'secret',
    'tun', 'dns', 'sniffer', 'profile', 'hosts', 'geodata-mode',
    'geox-url', 'geo-auto-update', 'geo-update-interval',
    'tls', 'keep-alive-interval', 'find-process-mode',
    'ebpf', 'iptables',
}

profile_keys = {
    'proxies', 'proxy-groups', 'rules', 'proxy-providers',
    'rule-providers', 'sub-rules',
}

out_lines = []
skip_until_top = False
current_top_key = None
indent = ''
in_profile = False

# Simple line-by-line: track top-level keys and their blocks
for i, line in enumerate(lines):
    # Empty or comment
    if line.strip() == '' or line.strip().startswith('#'):
        # Only include comments at top of file
        if not current_top_key:
            pass  # skip comments for clean split
        continue

    # Detect indent
    leading = len(line) - len(line.lstrip())
    content = line.strip()

    if leading == 0 and not content.startswith('#'):
        # Top-level key
        if ':' in content:
            key = content.split(':')[0].strip()
            current_top_key = key
            indent = ''
            in_profile = key in profile_keys
        else:
            current_top_key = None

    if current_top_key and current_top_key in infra_keys:
        out_lines.append(line)
    elif current_top_key is None and leading == 0 and ':' in content:
        key = content.split(':')[0].strip()
        if key in infra_keys:
            out_lines.append(line)

with open('$BASE_YAML', 'w') as f:
    f.writelines(out_lines)
" 2>/dev/null || {
    # Python fallback: use awk-based extraction
    log_warn "Python 提取失败，使用 awk 回退方案..."
    awk '
    BEGIN {
        in_profile = 0
        in_infra = 0
    }
    /^proxies:/ || /^proxy-groups:/ || /^rules:/ || /^proxy-providers:/ || /^rule-providers:/ {
        in_profile = 1
        next
    }
    /^[a-zA-Z-]+:/ {
        in_profile = 0
        in_infra = 1
    }
    in_infra { print }
    !in_profile && !in_infra && /^[a-zA-Z-]+:/ {
        in_infra = 1
        print
    }
    ' "$OLD_CONFIG" > "$BASE_YAML"
}

if [ ! -s "$BASE_YAML" ]; then
    log_warn "base.yaml 提取为空，创建默认 base.yaml"
    cat > "$BASE_YAML" <<'BASEEOF'
port: 7890
socks-port: 7891
mode: rule
allow-lan: true
log-level: warning
external-controller: '0.0.0.0:9090'
external-ui: /usr/local/etc/mihomo/ui
secret: ''
tun:
  enable: true
  stack: gvisor
  device: tun_3000
  mtu: 9000
  auto-route: true
  strict-route: true
  auto-detect-interface: true
  dns-hijack:
    - any:53
    - tcp://any:53
dns:
  enable: true
  listen: 0.0.0.0:53
  default-nameserver:
    - 127.0.0.1:5355
BASEEOF
fi

log_ok "base.yaml 提取完成"

# ── 4. 提取 proxies/proxy-groups/rules → profiles/legacy.yaml ──
log_info "提取 profile 到 $LEGACY_PROFILE ..."

python3 -c "
with open('$OLD_CONFIG') as f:
    lines = f.readlines()

profile_keys = {'proxies', 'proxy-groups', 'rules', 'proxy-providers', 'rule-providers'}
out = []
capture = False
for line in lines:
    stripped = line.strip()
    if stripped == '' or stripped.startswith('#'):
        if capture:
            out.append(line)
        continue
    leading = len(line) - len(line.lstrip())
    if leading == 0 and ':' in stripped:
        key = stripped.split(':')[0].strip()
        capture = key in profile_keys
    if capture:
        out.append(line)

with open('$PROFILES_DIR/$LEGACY_PROFILE.yaml', 'w') as f:
    f.writelines(out)
" 2>/dev/null || {
    awk '
    BEGIN { capture = 0 }
    /^proxies:/ || /^proxy-groups:/ || /^rules:/ { capture = 1 }
    /^[a-zA-Z-]+:/ && !/^proxies:/ && !/^proxy-groups:/ && !/^rules:/ {
        if (capture) { capture = 0 }
    }
    capture { print }
    ' "$OLD_CONFIG" > "$PROFILES_DIR/$LEGACY_PROFILE.yaml"
}

NODE_COUNT=$(grep -c '^  - name:' "$PROFILES_DIR/$LEGACY_PROFILE.yaml" 2>/dev/null || echo 0)

# ── 5. 创建 legacy.meta.json ──
cat > "$PROFILES_DIR/$LEGACY_PROFILE.meta.json" <<METAEOF
{
    "source_type": "manual",
    "last_update": "$(date '+%Y-%m-%d %H:%M:%S')",
    "node_count": $NODE_COUNT
}
METAEOF

log_ok "legacy profile 提取完成（节点数: $NODE_COUNT）"

# ── 6. 创建空 override.yaml ──
cat > "$OVERRIDE_YAML" <<'OVRDEOF'
# 用户覆写片段 — 订阅刷新不会覆盖此文件内容。
#
# 约定 key（按位置插入）：
#   prepend-rules       — 插入 rules 列表头部
#   append-rules        — 追加到 rules 列表尾部
#   append-proxies      — 追加私有节点到 proxies 列表末尾
#   prepend-proxy-groups — 插入 proxy-groups 列表头部
#   append-proxy-groups  — 追加到 proxy-groups 列表尾部
#
# 其余顶层 key 将深度合并覆盖 base.yaml。
OVRDEOF

log_ok "override.yaml 已创建"

# ── 7. 写入 active.json ──
cat > "$ACTIVE_JSON" <<ACTIVEEOF
{"profile": "$LEGACY_PROFILE"}
ACTIVEEOF

log_ok "active.json → $LEGACY_PROFILE"

# ── 8. 迁移旧订阅 ──
if [ -f "$SUB_ENV" ]; then
    log_info "检测到旧订阅配置，迁移到 subs.json..."
    # shellcheck source=/dev/null
    . "$SUB_ENV"

    if [ -n "$mihomo_URL" ]; then
        SUB_ID="migrated-1"
        cat > "$SUBS_JSON" <<SUBSEOF
[
    {
        "id": "$SUB_ID",
        "name": "Migrated Subscription",
        "url": "$mihomo_URL",
        "user_agent": "clash-verge/v1.7.0",
        "enabled": true,
        "include_keyword": "",
        "exclude_keyword": "剩余,流量,过期,官网,套餐",
        "update_interval_hours": 6,
        "last_update": null,
        "last_status": null
    }
]
SUBSEOF
        log_ok "订阅已迁移为 subs.json 条目 (id=$SUB_ID)"
    fi
else
    echo '[]' > "$SUBS_JSON"
    log_info "无旧订阅需要迁移"
fi

# ── 9. 校验合成结果 ──
log_info "校验合成配置..."

VALIDATION_OK=0

# 检查 PHP 是否可用
if command -v php >/dev/null 2>&1 && [ -f /usr/local/www/includes/mihomo_lib.inc.php ]; then
	log_info "使用 PHP 进行合成校验..."

	VALIDATION_RESULT=$(php -r '
	require_once "/usr/local/www/includes/mihomo_lib.inc.php";
	$base = file_exists(MIHOMO_BASE_YAML) ? mihomoYamlParse(file_get_contents(MIHOMO_BASE_YAML)) : [];
	$override = file_exists(MIHOMO_OVERRIDE_YAML) ? mihomoYamlParse(file_get_contents(MIHOMO_OVERRIDE_YAML)) : [];
	$pf = MIHOMO_PROFILES_DIR . "/'"$LEGACY_PROFILE"'.yaml";
	$profile = file_exists($pf) ? mihomoYamlParse(file_get_contents($pf)) : [];
	$merged = mergeAll($base, $override, $profile);
	$yaml = mihomoYamlDump($merged);
	$tmp = "/tmp/config.yaml.migrate";
	file_put_contents($tmp, $yaml, LOCK_EX);
	$output = [];
	$rc = 0;
	exec("/usr/local/bin/mihomo -d " . escapeshellarg(MIHOMO_DIR) . " -t -f " . escapeshellarg($tmp) . " 2>&1", $output, $rc);
	unlink($tmp);
	if ($rc === 0) {
	    echo "VALID";
	    exit(0);
	} else {
	    echo "INVALID:" . implode("\n", $output);
	    exit(1);
	}
	' 2>/dev/null)

	if [ $? -eq 0 ] && [ "$VALIDATION_RESULT" = "VALID" ]; then
		log_ok "配置校验通过"
		VALIDATION_OK=1
			# 写入合成后的 config.yaml
			php -r '
			require_once "/usr/local/www/includes/mihomo_lib.inc.php";
			$base = file_exists(MIHOMO_BASE_YAML) ? mihomoYamlParse(file_get_contents(MIHOMO_BASE_YAML)) : [];
			$override = file_exists(MIHOMO_OVERRIDE_YAML) ? mihomoYamlParse(file_get_contents(MIHOMO_OVERRIDE_YAML)) : [];
			$pf = MIHOMO_PROFILES_DIR . "/'"$LEGACY_PROFILE"'.yaml";
			$profile = file_exists($pf) ? mihomoYamlParse(file_get_contents($pf)) : [];
			$merged = mergeAll($base, $override, $profile);
			file_put_contents(MIHOMO_CONFIG_YAML, mihomoYamlDump($merged), LOCK_EX);
			' 2>/dev/null
			log_ok "合成 config.yaml 已写入"
	else
		log_warn "PHP 校验失败: $VALIDATION_RESULT"
		log_info "回退到直接校验..."
	fi
fi

if [ "$VALIDATION_OK" -eq 0 ]; then
	# 检查 mihomo 二进制是否有效
	if ! /usr/local/bin/mihomo -v >/dev/null 2>&1; then
		log_error "mihomo 二进制无效或未安装。请先安装 mihomo 内核后再执行迁移。"
		log_error "  (bin/mihomo 是占位文件，需要从 GitHub 下载真实二进制)"
		echo "mihomo binary not valid at $(date)" > "$MIGRATE_ERROR"
		exit 1
	fi

	# 简单合并: base + profile
	cat "$BASE_YAML" > "/tmp/config.yaml.migrate"
	echo "" >> "/tmp/config.yaml.migrate"
	cat "$PROFILES_DIR/$LEGACY_PROFILE.yaml" >> "/tmp/config.yaml.migrate"

	if /usr/local/bin/mihomo -d "$MIHOMO_DIR" -t -f "/tmp/config.yaml.migrate" >/dev/null 2>&1; then
		log_ok "配置校验通过"
		# Write merged config
		cp "/tmp/config.yaml.migrate" "$MIHOMO_DIR/config.yaml"
		rm -f "/tmp/config.yaml.migrate"
	else
		log_error "配置校验失败！保留旧文件不动。"
		/usr/local/bin/mihomo -d "$MIHOMO_DIR" -t -f "/tmp/config.yaml.migrate" 2>&1 | while read -r line; do
			log_error "  $line"
		done
		rm -f "/tmp/config.yaml.migrate"
		echo "Migration validation failed at $(date)" > "$MIGRATE_ERROR"
		/usr/local/bin/mihomo -d "$MIHOMO_DIR" -t -f "/tmp/config.yaml.migrate" 2>>"$MIGRATE_ERROR" || true
		exit 1
	fi
fi

# ── 10. 写入迁移标志 ──
date '+%Y-%m-%d %H:%M:%S' > "$MIGRATED_FLAG"
log_ok ".migrated-v2 标志已写入"

# ── 11. 启动 mihomo ──
log_info "启动 mihomo..."
if service mihomo start >/dev/null 2>&1; then
    log_ok "mihomo 已启动"
else
    log_warn "mihomo 启动失败，请手动检查"
fi

log_info "======== 迁移完成 ========"
log_info "备份位置: $BACKUP_FILE"
log_info "如果遇到问题，可通过 Backup 页面恢复。"
echo ""
exit 0
