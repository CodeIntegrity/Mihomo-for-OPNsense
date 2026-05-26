#!/bin/bash
echo -e ''
echo -e "\033[32m========Mihomo for OPNsense 一键安装脚本=========\033[0m"
echo -e ''

# 定义颜色变量
GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
CYAN="\033[36m"
BLUE="\033[34m"
RESET="\033[0m"

# 定义目录变量
ROOT="/usr/local"
BIN_DIR="$ROOT/bin"
WWW_DIR="$ROOT/www"
CONF_DIR="$ROOT/etc"
MENU_DIR="$ROOT/opnsense/mvc/app/models/OPNsense"
RC_DIR="$ROOT/etc/rc.d"
PLUGINS="$ROOT/etc/inc/plugins.inc.d"
ACTIONS="$ROOT/opnsense/service/conf/actions.d"
RC_CONF="/etc/rc.conf.d/"
CONFIG_FILE="/conf/config.xml"
TMP_FILE="/tmp/config.xml.tmp"
TIMESTAMP=$(date +%F-%H%M%S)
BACKUP_FILE="/conf/config.xml.bak.$TIMESTAMP"
TARGET_IF_BLOCK=""

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

run_or_die() {
  "$@" || {
    log_error "命令执行失败：$*"
    exit 1
  }
}

install_pkg_if_missing() {
  local pkg_name="$1"

  if pkg info -q "$pkg_name" > /dev/null 2>&1; then
    log_warn "$pkg_name 已安装，跳过"
    return 0
  fi

  if pkg install -y "$pkg_name" > /dev/null 2>&1; then
    log_success "$pkg_name 安装完成"
  else
    log_error "$pkg_name 安装失败"
    exit 1
  fi
}

# 创建目录
log_step "创建目录..."
run_or_die mkdir -p "$CONF_DIR/mihomo"

# 清理旧版 mosdns 残留文件
if [ -f "$WWW_DIR/services_mosdns.php" ] || [ -f "$BIN_DIR/mosdns" ]; then
	log_step "清理旧版 mosdns 残留..."
	rm -f "$WWW_DIR/services_mosdns.php" "$WWW_DIR/status_mosdns.php"
	rm -f "$WWW_DIR/status_mosdns_logs.php" "$BIN_DIR/mosdns"
	log_success "旧版 mosdns 文件已清理"
fi

# 复制文件
log_step "复制文件并部署组件..."
log_info "生成菜单..."
log_info "生成服务..."
# 预检：bin/mihomo 必须是真实的 FreeBSD ELF 二进制，而非占位符文本
if ! file -b ./bin/mihomo 2>/dev/null | grep -qE 'ELF.*executable|FreeBSD'; then
	log_error "bin/mihomo 不是有效的 FreeBSD 可执行文件（疑似占位符或损坏）"
	log_error "请从 https://github.com/Vincent-Loeng/clash-meta/releases 下载"
	log_error "freebsd-amd64 版本，解压后替换 bin/mihomo 再重新安装"
	exit 1
fi
log_info "添加权限..."
run_or_die chmod +x ./bin/* ./rc.d/*
# conf/sub/*.sh 可能不存在（非首次安装），失败不终止
chmod +x ./conf/sub/*.sh 2>/dev/null || true
run_or_die cp -f bin/* "$BIN_DIR/"
run_or_die cp -f www/*.php "$WWW_DIR/"
run_or_die cp -f rc.d/* "$RC_DIR/"
run_or_die cp -f rc.conf/* "$RC_CONF/"
run_or_die cp -f plugins/* "$PLUGINS/"
run_or_die cp -f actions/* "$ACTIONS/"
run_or_die cp -R -f menu/* "$MENU_DIR/"

# 资产/脚本：始终更新（Country.mmdb / sub 脚本 / 内置 UI）
mkdir -p "$CONF_DIR/mihomo" "$CONF_DIR/mihomo/sub" "$CONF_DIR/mihomo/ui"
if [ -f ./conf/Country.mmdb ]; then
	run_or_die cp -f ./conf/Country.mmdb "$CONF_DIR/mihomo/"
fi
if [ -d ./conf/sub ]; then
	# 排除 env 占位文件，避免覆盖用户残留
	find ./conf/sub -maxdepth 1 -type f ! -name env -exec cp -f {} "$CONF_DIR/mihomo/sub/" \;
fi
if [ -d ./conf/ui ]; then
	run_or_die cp -Rf ./conf/ui/. "$CONF_DIR/mihomo/ui/"
fi

# 部署新版 PHP 公共库
if [ -d ./www/includes ]; then
	mkdir -p "$WWW_DIR/includes"
	run_or_die cp -f ./www/includes/* "$WWW_DIR/includes/"
	log_success "PHP 公共库已部署"
fi
log_success "文件复制完成"

# 创建 v2 目录结构
log_step "创建 v2 目录结构..."
mkdir -p "$CONF_DIR/mihomo/profiles"
mkdir -p "$CONF_DIR/mihomo/backups"
log_success "目录结构就绪"

# 初始化 v2 配置文件：用户数据只在缺失时写入，避免覆盖
log_step "初始化 v2 配置文件..."
init_if_missing() {
	local src="$1" dst="$2"
	if [ ! -e "$dst" ] && [ -e "$src" ]; then
		cp -R "$src" "$dst"
		log_info "  初始化 $(basename "$dst")"
	fi
}
init_if_missing ./conf/base.yaml      "$CONF_DIR/mihomo/base.yaml"
init_if_missing ./conf/override.yaml  "$CONF_DIR/mihomo/override.yaml"
init_if_missing ./conf/subs.json      "$CONF_DIR/mihomo/subs.json"
init_if_missing ./conf/active.json    "$CONF_DIR/mihomo/active.json"
init_if_missing ./conf/config.yaml    "$CONF_DIR/mihomo/config.yaml"
# 默认 profile：只在 profiles/ 目录为空时铺设
if [ -z "$(ls -A "$CONF_DIR/mihomo/profiles" 2>/dev/null)" ] && [ -d ./conf/profiles ]; then
	cp -R ./conf/profiles/. "$CONF_DIR/mihomo/profiles/"
	log_info "  初始化默认 profile"
fi
log_success "v2 配置就绪"

# 统一设置文件权限
log_step "设置文件权限..."
chown -R root:www "$CONF_DIR/mihomo" 2>/dev/null || true
chmod 750 "$CONF_DIR/mihomo"
chmod 750 "$CONF_DIR/mihomo/profiles"
chmod 750 "$CONF_DIR/mihomo/backups"
chmod 640 "$CONF_DIR/mihomo/base.yaml" 2>/dev/null || true
chmod 640 "$CONF_DIR/mihomo/override.yaml" 2>/dev/null || true
chmod 640 "$CONF_DIR/mihomo/subs.json" 2>/dev/null || true
chmod 640 "$CONF_DIR/mihomo/active.json" 2>/dev/null || true
chmod 640 "$CONF_DIR/mihomo/config.yaml" 2>/dev/null || true
chmod 640 "$CONF_DIR/mihomo/profiles/"*.yaml 2>/dev/null || true
log_success "权限设置完成"

# 新建订阅程序
log_step "添加订阅..."
cat>/usr/bin/sub<<'SUBEOF'
#!/bin/bash
# Mihomo subscription update entry — delegates to cron巡检 script
bash /usr/local/etc/mihomo/sub/sub_cron.sh
SUBEOF
run_or_die chmod +x /usr/bin/sub
log_success "订阅程序添加完成"

# 安装运行依赖
log_step "检查并安装运行依赖..."
install_pkg_if_missing bash
install_pkg_if_missing jq
install_pkg_if_missing curl

# 启动Tun接口
log_step "启动 mihomo..."
if service mihomo restart > /dev/null 2>&1; then
  log_success "mihomo 重启完成"
else
  log_error "mihomo 重启失败"
fi
echo ""

# 备份配置文件
log_step "备份配置文件..."
cp "$CONFIG_FILE" "$BACKUP_FILE" || {
  log_error "配置备份失败，终止操作！"
  echo ""
  exit 1
}
log_success "配置已备份到 $BACKUP_FILE"

TARGET_IF_BLOCK=$(awk '
BEGIN {
  in_block = 0
  current = ""
  found = ""
  max_opt = -1
}
{
  if ($0 ~ /^[[:space:]]*<opt[0-9]+>[[:space:]]*$/) {
    line = $0
    gsub(/^[[:space:]]*</, "", line)
    gsub(/>[[:space:]]*$/, "", line)
    current = line
    in_block = 1

    num = current
    sub(/^opt/, "", num)
    if ((num + 0) > max_opt) {
      max_opt = num + 0
    }
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
  if (found != "") {
    print found
  } else {
    print "opt" (max_opt + 1)
  }
}
' "$CONFIG_FILE")

log_info "tun_3000 目标接口：$TARGET_IF_BLOCK"

# 添加tun接口
log_step "添加 tun_3000 接口..."
if grep -q "<if>tun_3000</if>" "$CONFIG_FILE"; then
  log_warn "存在同名接口，忽略"
else
  awk -v target="$TARGET_IF_BLOCK" '
  BEGIN { inserted = 0 }
  {
    print
    if ($0 ~ /<\/lo0>/ && inserted == 0) {
      print "    <" target ">"
      print "      <if>tun_3000</if>"
      print "      <descr>TUN</descr>"
      print "      <enable>1</enable>"
      print "    </" target ">"
      inserted = 1
    }
  }
  END {
    if (inserted == 0) exit 1
  }
  ' "$CONFIG_FILE" > "$TMP_FILE"

  if [ $? -eq 0 ] && [ -s "$TMP_FILE" ]; then
    mv "$TMP_FILE" "$CONFIG_FILE"
    log_success "${TARGET_IF_BLOCK} 接口添加完成"
  else
    rm -f "$TMP_FILE"
    log_error "接口添加失败，请检查配置文件"
  fi
fi
echo ""

# 添加防火墙规则（允许TUN子网互访问）
log_step "添加防火墙规则..."
if grep -q "5a73c3dc-69b1-4e15-89cb-b542aa2c1154" "$CONFIG_FILE"; then
  log_warn "存在同名规则，忽略"
else
  awk -v target="$TARGET_IF_BLOCK" '
  BEGIN { inserted = 0 }
  {
    if ($0 ~ /<rules>/ && inserted == 0) {
      print
      print "          <rule uuid=\"5a73c3dc-69b1-4e15-89cb-b542aa2c1154\">"
      print "            <enabled>1</enabled>"
      print "            <statetype>keep</statetype>"
      print "            <state-policy/>"
      print "            <sequence>200</sequence>"
      print "            <action>pass</action>"
      print "            <quick>1</quick>"
      print "            <interfacenot>0</interfacenot>"
      print "            <interface>" target "</interface>"
      print "            <direction>in</direction>"
      print "            <ipprotocol>inet</ipprotocol>"
      print "            <protocol>any</protocol>"
      print "            <icmptype/>"
      print "            <icmp6type/>"
      print "            <source_net>" target "</source_net>"
      print "            <source_not>0</source_not>"
      print "            <source_port/>"
      print "            <destination_net>" target "</destination_net>"
      print "            <destination_not>0</destination_not>"
      print "            <destination_port/>"
      print "            <divert-to/>"
      print "            <gateway/>"
      print "            <replyto/>"
      print "            <disablereplyto>0</disablereplyto>"
      print "            <log>0</log>"
      print "            <allowopts>0</allowopts>"
      print "            <nosync>0</nosync>"
      print "            <nopfsync>0</nopfsync>"
      print "            <statetimeout/>"
      print "            <udp-first/>"
      print "            <udp-multiple/>"
      print "            <udp-single/>"
      print "            <max-src-nodes/>"
      print "            <max-src-states/>"
      print "            <max-src-conn/>"
      print "            <max/>"
      print "            <max-src-conn-rate/>"
      print "            <max-src-conn-rates/>"
      print "            <overload/>"
      print "            <adaptivestart/>"
      print "            <adaptiveend/>"
      print "            <prio/>"
      print "            <set-prio/>"
      print "            <set-prio-low/>"
      print "            <tag/>"
      print "            <tagged/>"
      print "            <tcpflags1/>"
      print "            <tcpflags2/>"
      print "            <tcpflags_any>0</tcpflags_any>"
      print "            <categories/>"
      print "            <sched/>"
      print "            <tos/>"
      print "            <shaper1/>"
      print "            <shaper2/>"
      print "            <description/>"
      print "          </rule>"
      inserted = 1
      next
    }
    print
  }
  END {
    if (inserted == 0) exit 1
  }
  ' "$CONFIG_FILE" > "$TMP_FILE"

  if [ $? -eq 0 ] && [ -s "$TMP_FILE" ]; then
    mv "$TMP_FILE" "$CONFIG_FILE"
    log_success "${TARGET_IF_BLOCK} 防火墙规则添加完成"
  else
    rm -f "$TMP_FILE"
    log_error "防火墙规则添加失败，请检查配置文件"
  fi
fi
echo ""

# 更改Unbound端口为 5355
sleep 1
log_step "更改 Unbound 端口..."

UNBOUND_STATE=$(awk '
BEGIN {
  in_unbound = 0
  in_general = 0
  has_5355 = 0
  has_other_port = 0
}
{
  if ($0 ~ /<unboundplus[^>]*>/ || $0 ~ /<unbound[^>]*>/) in_unbound = 1
  if (in_unbound && $0 ~ /<general>/) in_general = 1

  if (in_unbound && in_general && $0 ~ /<port>5355<\/port>/) has_5355 = 1
  if (in_unbound && in_general && $0 ~ /<port>[0-9]+<\/port>/ && $0 !~ /<port>5355<\/port>/) has_other_port = 1

  if (in_unbound && $0 ~ /<\/general>/) in_general = 0
  if ($0 ~ /<\/unboundplus>/ || $0 ~ /<\/unbound>/) {
    in_unbound = 0
    in_general = 0
  }
}
END {
  if (has_5355) {
    print "already_ok"
  } else if (has_other_port) {
    print "need_replace"
  } else {
    print "need_insert"
  }
}
' "$CONFIG_FILE")

if [ "$UNBOUND_STATE" = "already_ok" ]; then
  log_warn "端口已经为 5355，跳过"
else
  awk '
  BEGIN {
    in_unbound = 0
    in_general = 0
    port_handled = 0
  }
  {
    if ($0 ~ /<unboundplus[^>]*>/ || $0 ~ /<unbound[^>]*>/) {
      in_unbound = 1
    }

    if (in_unbound && $0 ~ /<general>/) {
      in_general = 1
      print
      next
    }

    if (in_unbound && in_general && $0 ~ /<\/general>/) {
      if (port_handled == 0) {
        print "        <port>5355</port>"
        port_handled = 1
      }
      in_general = 0
      print
      next
    }

    if (in_unbound && in_general && $0 ~ /<port>[0-9]+<\/port>/ && port_handled == 0) {
      sub(/<port>[0-9]+<\/port>/, "<port>5355</port>")
      port_handled = 1
      print
      next
    }

    print

    if ($0 ~ /<\/unboundplus>/ || $0 ~ /<\/unbound>/) {
      in_unbound = 0
      in_general = 0
    }
  }
  END {
    if (port_handled == 0) exit 1
  }
  ' "$CONFIG_FILE" > "$TMP_FILE"

  if [ $? -eq 0 ] && [ -s "$TMP_FILE" ]; then
    mv "$TMP_FILE" "$CONFIG_FILE"
    log_success "端口已设置为 5355"
  else
    rm -f "$TMP_FILE"
    log_error "修改失败，请检查配置文件"
  fi
fi
echo ""

log_step "清理菜单缓存..."
rm -f /var/lib/php/tmp/opnsense_menu_cache.xml
rm -f /var/lib/php/tmp/opnsense_acl_cache.json
log_success "菜单缓存清理完成"

# 部署语言文件
log_step "部署语言文件..."
LANG_DEST="/usr/local/share/locale/zh_CN/LC_MESSAGES"
if [ -f ./lang/zh_CN/LC_MESSAGES/mihomo.mo ]; then
	mkdir -p "$LANG_DEST"
	run_or_die cp -f ./lang/zh_CN/LC_MESSAGES/mihomo.mo "$LANG_DEST/"
	log_success "中文语言文件已部署"
else
	log_warn "语言文件未找到，跳过"
fi

# 重新载入configd
log_step "重新载入 configd..."
if service configd restart > /dev/null 2>&1; then
  log_success "configd 重新载入完成"
else
  log_error "configd 重新载入失败"
fi
echo ""

# 重启 Unbound DNS 服务
log_step "重启 Unbound DNS..."
if configctl unbound restart > /dev/null 2>&1; then
  log_success "Unbound DNS 重启完成"
else
  log_error "Unbound DNS 重启失败"
fi
echo ""

# 重新载入防火墙规则
log_step "重新加载防火墙规则..."
if configctl filter reload > /dev/null 2>&1; then
  log_success "防火墙规则重新加载完成"
else
  log_error "防火墙规则重新加载失败"
fi
echo ""

# 完成提示
log_success "安装完毕，请导航到 VPN > Mihomo 进行配置。"
echo ""
