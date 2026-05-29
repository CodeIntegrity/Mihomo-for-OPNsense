#!/bin/bash

echo -e ''
echo -e "\033[32m========Mihomo for OPNsense 一键卸载脚本=========\033[0m"
echo -e ''

# 定义颜色变量
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
CYAN="\033[36m"
BLUE="\033[34m"
RESET="\033[0m"

# 定义日志函数
log() {
    local color="$1"
    local level="$2"
    local message="$3"
    local ts
    ts=$(date '+%F %T')
    echo -e "${color}[${ts}] [${level}] ${message}${RESET}"
}

log_info() {
    log "$YELLOW" "INFO" "$1"
}

log_warn() {
    log "$CYAN" "WARN" "$1"
}

log_error() {
    log "$RED" "ERROR" "$1"
}

log_success() {
    log "$GREEN" "OK" "$1"
}

log_step() {
    log "$BLUE" "STEP" "$1"
}

# 变量定义
CONFIG_FILE="/conf/config.xml"
TMP_FILE="/tmp/config.xml.tmp"
BACKUP_FILE="/conf/config.xml.bak.mihomo_uninstall_$(date +%Y%m%d_%H%M%S)"

log_step "停止 mihomo 服务..."
if service mihomo stop > /dev/null 2>&1; then
    log_success "mihomo 服务已停止"
else
    log_warn "mihomo 服务停止失败或服务不存在，跳过"
fi

echo ""

# 询问是否保留用户数据
log_step "用户数据清理选项..."
echo -e "${YELLOW}是否保留用户配置数据？${RESET}"
echo -e "  ${CYAN}y${RESET} — 保留 /usr/local/etc/mihomo/ 下的配置文件（base.yaml, override.yaml, profiles/ 等）"
echo -e "  ${CYAN}N${RESET} — 全部删除（默认）"
read -r -p "Do you want to keep user data? [y/N]: " KEEP_DATA
KEEP_DATA=${KEEP_DATA:-n}

echo ""

# 删除程序和配置
log_step "删除 Mihomo 组件..."

if [ "$KEEP_DATA" = "y" ] || [ "$KEEP_DATA" = "Y" ]; then
    log_warn "保留用户配置目录: /usr/local/etc/mihomo/"
else
    rm -rf /usr/local/etc/mihomo
    log_success "用户配置目录已删除"
fi

# 删除 rc.d
rm -f /usr/local/etc/rc.d/mihomo

# 删除 rc.conf
rm -f /etc/rc.conf.d/mihomo

# 删除 configd action
rm -f /usr/local/opnsense/service/conf/actions.d/actions_mihomo.conf

# 删除 MVC 层（controllers / models / views）
rm -rf /usr/local/opnsense/mvc/app/controllers/OPNsense/Mihomo
rm -rf /usr/local/opnsense/mvc/app/models/OPNsense/Mihomo
rm -rf /usr/local/opnsense/mvc/app/views/OPNsense/Mihomo

# 删除 configd 脚本
rm -rf /usr/local/opnsense/scripts/mihomo

# 删除插件 inc
rm -f /usr/local/etc/inc/plugins.inc.d/mihomo.inc

# 删除程序
rm -f /usr/local/bin/mihomo
rm -f /usr/bin/sub

# 删除语言文件
rm -f /usr/local/share/locale/zh_CN/LC_MESSAGES/mihomo.mo

# 清理日志
rm -f /var/log/mihomo.log
rm -f /var/log/mihomo_sub.log

# 清理临时文件
rm -f /tmp/mihomo-traffic-state.json
rm -f /tmp/mihomo-latest-release.json
rm -f /tmp/mihomo-geoip-release.json
rm -f /tmp/mihomo-sub-cron.lock
rm -f /tmp/mihomo-sub-*.lock
rm -f /tmp/mihomo-reconfigure.lock
rm -f /tmp/mihomo-health-*.json
rm -f /tmp/mihomo-update-*.json
rm -f /tmp/mihomo-release-cache-*.json
rm -f /tmp/mihomo-config.yaml.*

log_success "程序文件删除完成"

echo ""

log_step "备份配置文件..."
cp "$CONFIG_FILE" "$BACKUP_FILE" || {
    log_error "配置备份失败，终止操作！"
    echo ""
    exit 1
}
log_success "配置已备份到 $BACKUP_FILE"

echo ""

log_step "删除 tun_3000 接口..."
TARGET_IF_BLOCK=$(awk '
BEGIN {
  in_block = 0
  current = ""
  found = ""
}
{
  if ($0 ~ /^[[:space:]]*<opt[0-9]+>[[:space:]]*$/) {
    line = $0
    gsub(/^[[:space:]]*</, "", line)
    gsub(/>[[:space:]]*$/, "", line)
    current = line
    in_block = 1
  }

  if (in_block && $0 ~ /<if>tun_3000<\/if>/) {
    found = current
  }

  if (in_block && current != "" && $0 ~ ("^[[:space:]]*</" current ">[[:space:]]*$")) {
    in_block = 0
    current = ""
  }
}
END {
  if (found != "") print found
}
' "$CONFIG_FILE")

if [ -n "$TARGET_IF_BLOCK" ]; then
  awk -v target="$TARGET_IF_BLOCK" '
  BEGIN { skip = 0 }
  {
    if ($0 ~ ("^[[:space:]]*<" target ">[[:space:]]*$")) {
      skip = 1
      next
    }
    if (skip == 1) {
      if ($0 ~ ("^[[:space:]]*</" target ">[[:space:]]*$")) {
        skip = 0
        next
      }
      next
    }
    print
  }
  ' "$CONFIG_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$CONFIG_FILE"
  log_success "${TARGET_IF_BLOCK} 接口块删除完成"
else
  log_warn "未找到 tun_3000 对应的接口块，跳过"
fi

echo ""

log_step "删除防火墙规则..."
if grep -q "5a73c3dc-69b1-4e15-89cb-b542aa2c1154" "$CONFIG_FILE"; then
  awk '
  BEGIN { skip = 0 }
  /<rule uuid="5a73c3dc-69b1-4e15-89cb-b542aa2c1154">/ { skip = 1; next }
  skip == 1 {
    if ($0 ~ /<\/rule>/) {
      skip = 0
      next
    }
    next
  }
  { print }
  ' "$CONFIG_FILE" > "$TMP_FILE" && mv "$TMP_FILE" "$CONFIG_FILE"
  log_success "防火墙规则删除完成"
else
  log_warn "未找到对应防火墙规则，跳过"
fi

echo ""

log_step "恢复 Unbound DNS 端口为 53..."
UNBOUND_STATE=$(awk '
BEGIN {
  in_unbound = 0
  in_general = 0
  has_53 = 0
  has_5355 = 0
}
{
  if ($0 ~ /<unboundplus[ >]/ || $0 ~ /<unbound[ >]/) in_unbound = 1
  if (in_unbound && $0 ~ /<general>/) in_general = 1

  if (in_unbound && in_general && $0 ~ /<port>53<\/port>/) has_53 = 1
  if (in_unbound && in_general && $0 ~ /<port>5355<\/port>/) has_5355 = 1

  if (in_unbound && $0 ~ /<\/general>/) in_general = 0
  if ($0 ~ /<\/unboundplus>/ || $0 ~ /<\/unbound>/) {
    in_unbound = 0
    in_general = 0
  }
}
END {
  if (has_5355) {
    print "need_fix"
  } else if (has_53) {
    print "already_ok"
  } else {
    print "not_found"
  }
}
' "$CONFIG_FILE")

if [ "$UNBOUND_STATE" = "already_ok" ]; then
  log_warn "Unbound DNS 端口已经为 53，跳过"
elif [ "$UNBOUND_STATE" = "not_found" ]; then
  log_warn "未找到 Unbound DNS 端口配置，跳过"
else
  awk '
  BEGIN {
    in_unbound = 0
    in_general = 0
    replaced = 0
  }
  {
    if ($0 ~ /<unboundplus[ >]/ || $0 ~ /<unbound[ >]/) in_unbound = 1
    if (in_unbound && $0 ~ /<general>/) in_general = 1

    if (in_unbound && in_general && $0 ~ /<port>5355<\/port>/ && replaced == 0) {
      sub(/<port>5355<\/port>/, "<port>53</port>")
      replaced = 1
    }

    print

    if (in_unbound && $0 ~ /<\/general>/) in_general = 0
    if ($0 ~ /<\/unboundplus>/ || $0 ~ /<\/unbound>/) {
      in_unbound = 0
      in_general = 0
    }
  }
  END {
    if (replaced == 0) exit 1
  }
  ' "$CONFIG_FILE" > "$TMP_FILE"

  if [ $? -eq 0 ] && [ -s "$TMP_FILE" ]; then
    mv "$TMP_FILE" "$CONFIG_FILE"
    log_success "Unbound DNS 端口已恢复为 53"
  else
    rm -f "$TMP_FILE"
    log_error "恢复 Unbound DNS 端口失败，请检查配置文件"
  fi
fi

echo ""

log_step "清理菜单缓存..."
rm -f /var/lib/php/tmp/opnsense_menu_cache.xml
rm -f /var/lib/php/tmp/opnsense_acl_cache.json
log_success "菜单缓存清理完成"

# 重启服务

if service configd restart > /dev/null 2>&1; then
    log_success "configd 重启完成"
else
    log_error "configd 重启失败"
fi

if configctl unbound restart > /dev/null 2>&1; then
    log_success "Unbound DNS 重启完成"
else
    log_error "Unbound DNS 重启失败"
fi

if configctl filter reload > /dev/null 2>&1; then
    log_success "防火墙规则重新加载完成"
else
    log_error "防火墙规则重新加载失败"
fi

echo ""

# 完成提示
log_success "卸载完成，tun 接口、防火墙规则及 Unbound DNS 端口已处理完成。"
echo ""