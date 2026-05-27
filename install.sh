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
MVC_DIR="$ROOT/opnsense/mvc/app"
SCRIPTS_DIR="$ROOT/opnsense/scripts/mihomo"
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
run_or_die cp -f bin/* "$BIN_DIR/"
run_or_die cp -f rc.d/* "$RC_DIR/"
run_or_die cp -f rc.conf/* "$RC_CONF/"
run_or_die cp -f plugins/* "$PLUGINS/"

# === MVC 部署：controllers/models/views + configd actions + scripts ===
log_step "部署 MVC 层..."
mkdir -p "$MVC_DIR/controllers/OPNsense/Mihomo/Api" \
         "$MVC_DIR/controllers/OPNsense/Mihomo/forms" \
         "$MVC_DIR/models/OPNsense/Mihomo/ACL" \
         "$MVC_DIR/models/OPNsense/Mihomo/Menu" \
         "$MVC_DIR/views/OPNsense/Mihomo" \
         "$SCRIPTS_DIR"
run_or_die cp -R -f ./src/opnsense/mvc/app/. "$MVC_DIR/"
run_or_die cp -f ./src/opnsense/service/conf/actions.d/actions_mihomo.conf "$ACTIONS/"
run_or_die cp -R -f ./src/opnsense/scripts/mihomo/. "$SCRIPTS_DIR/"
chmod +x "$SCRIPTS_DIR"/*.sh "$SCRIPTS_DIR"/*.py 2>/dev/null || true
log_success "MVC 层部署完成"

# 资产/脚本：始终更新（Country.mmdb / 内置 UI）
mkdir -p "$CONF_DIR/mihomo" "$CONF_DIR/mihomo/ui"
if [ -f ./conf/Country.mmdb ]; then
	run_or_die cp -f ./conf/Country.mmdb "$CONF_DIR/mihomo/"
fi
if [ -d ./conf/ui ]; then
	run_or_die cp -Rf ./conf/ui/. "$CONF_DIR/mihomo/ui/"
fi
log_success "文件复制完成"

# 创建 v2 目录结构
log_step "创建配置目录结构..."
mkdir -p "$CONF_DIR/mihomo/profiles"
mkdir -p "$CONF_DIR/mihomo/backups"
log_success "目录结构就绪"

# 初始化配置文件：用户数据只在缺失时写入，避免覆盖
log_step "初始化默认配置文件..."
init_if_missing() {
	local src="$1" dst="$2"
	if [ ! -e "$dst" ] && [ -e "$src" ]; then
		cp -R "$src" "$dst"
		log_info "  初始化 $(basename "$dst")"
	fi
}
init_if_missing ./conf/base.yaml      "$CONF_DIR/mihomo/base.yaml"
init_if_missing ./conf/override.yaml  "$CONF_DIR/mihomo/override.yaml"
init_if_missing ./conf/active.json    "$CONF_DIR/mihomo/active.json"
init_if_missing ./conf/config.yaml    "$CONF_DIR/mihomo/config.yaml"
# 默认 profile：只在 profiles/ 目录为空时铺设
if [ -z "$(ls -A "$CONF_DIR/mihomo/profiles" 2>/dev/null)" ] && [ -d ./conf/profiles ]; then
	cp -R ./conf/profiles/. "$CONF_DIR/mihomo/profiles/"
	log_info "  初始化默认 profile"
fi
log_success "配置就绪"

# 统一设置文件权限
log_step "设置文件权限..."
chown -R root:www "$CONF_DIR/mihomo" 2>/dev/null || true
chmod 750 "$CONF_DIR/mihomo"
chmod 750 "$CONF_DIR/mihomo/profiles"
chmod 750 "$CONF_DIR/mihomo/backups"
chmod 640 "$CONF_DIR/mihomo/base.yaml" 2>/dev/null || true
chmod 640 "$CONF_DIR/mihomo/override.yaml" 2>/dev/null || true
chmod 640 "$CONF_DIR/mihomo/active.json" 2>/dev/null || true
chmod 640 "$CONF_DIR/mihomo/config.yaml" 2>/dev/null || true
chmod 640 "$CONF_DIR/mihomo/profiles/"*.yaml 2>/dev/null || true
log_success "权限设置完成"

# 订阅入口脚本：转发到 MVC 脚本目录
log_step "添加订阅入口..."
cat>/usr/bin/sub<<'SUBEOF'
#!/bin/sh
# Mihomo subscription cron entry — delegates to MVC script directory
exec /usr/local/opnsense/scripts/mihomo/sub_cron.sh "$@"
SUBEOF
run_or_die chmod +x /usr/bin/sub
log_success "订阅入口添加完成"

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
  # 预探测 <OPNsense> → <Firewall> → <Filter> → <rules> 路径上每一层是否存在
  # 仅在严格的父子上下文里计数，避免误匹配同名标签（例如 IPsec/Swanctl 也可能有 <rules>）
  DETECT=$(awk '
    /<OPNsense>/        { in_opn = 1; next }
    /<\/OPNsense>/      { in_opn = 0; next }
    in_opn && /<OPNsense\/>/                                     { has_opn_self = 1; next }
    in_opn && /<Firewall>/    { saw_fw = 1; in_fw = 1; next }
    in_opn && /<Firewall\/>/                                     { has_fw_self = 1; next }
    in_opn && /<\/Firewall>/  { in_fw = 0; next }
    in_fw  && /<Filter>/      { saw_ft = 1; in_ft = 1; next }
    in_fw  && /<Filter\/>/                                       { has_ft_self = 1; next }
    in_fw  && /<\/Filter>/    { in_ft = 0; next }
    in_ft  && /<rules>/       { saw_rules = 1; next }
    in_ft  && /<rules\/>/                                        { has_rules_self = 1; next }
    END {
      printf "%d %d %d %d %d %d",
        (saw_fw?1:0), (saw_ft?1:0), (saw_rules?1:0),
        (has_fw_self?1:0), (has_ft_self?1:0), (has_rules_self?1:0)
    }
  ' "$CONFIG_FILE")
  # POSIX sh 兼容：用 set -- 拆位置参数，不用 bash here-string
  set -- $DETECT
  SAW_FW=$1
  SAW_FT=$2
  SAW_RULES=$3
  HAS_FW_SELF=$4
  HAS_FT_SELF=$5
  HAS_RULES_SELF=$6

  if [ "$HAS_FW_SELF" = "1" ] || [ "$HAS_FT_SELF" = "1" ] || [ "$HAS_RULES_SELF" = "1" ]; then
    log_error "检测到自闭合的 <Firewall/> / <Filter/> / <rules/>，需要手动展开后再运行，已跳过自动插入"
  else
    awk -v target="$TARGET_IF_BLOCK" \
        -v saw_fw="$SAW_FW" -v saw_ft="$SAW_FT" -v saw_rules="$SAW_RULES" '
    function emit_rule(indent,    p) {
      p = indent
      print p "<rule uuid=\"5a73c3dc-69b1-4e15-89cb-b542aa2c1154\">"
      print p "  <enabled>1</enabled>"
      print p "  <statetype>keep</statetype>"
      print p "  <state-policy/>"
      print p "  <sequence>200</sequence>"
      print p "  <action>pass</action>"
      print p "  <quick>1</quick>"
      print p "  <interfacenot>0</interfacenot>"
      print p "  <interface>" target "</interface>"
      print p "  <direction>in</direction>"
      print p "  <ipprotocol>inet</ipprotocol>"
      print p "  <protocol>any</protocol>"
      print p "  <icmptype/>"
      print p "  <icmp6type/>"
      print p "  <source_net>" target "</source_net>"
      print p "  <source_not>0</source_not>"
      print p "  <source_port/>"
      print p "  <destination_net>" target "</destination_net>"
      print p "  <destination_not>0</destination_not>"
      print p "  <destination_port/>"
      print p "  <divert-to/>"
      print p "  <gateway/>"
      print p "  <replyto/>"
      print p "  <disablereplyto>0</disablereplyto>"
      print p "  <log>0</log>"
      print p "  <allowopts>0</allowopts>"
      print p "  <nosync>0</nosync>"
      print p "  <nopfsync>0</nopfsync>"
      print p "  <statetimeout/>"
      print p "  <udp-first/>"
      print p "  <udp-multiple/>"
      print p "  <udp-single/>"
      print p "  <max-src-nodes/>"
      print p "  <max-src-states/>"
      print p "  <max-src-conn/>"
      print p "  <max/>"
      print p "  <max-src-conn-rate/>"
      print p "  <max-src-conn-rates/>"
      print p "  <overload/>"
      print p "  <adaptivestart/>"
      print p "  <adaptiveend/>"
      print p "  <prio/>"
      print p "  <set-prio/>"
      print p "  <set-prio-low/>"
      print p "  <tag/>"
      print p "  <tagged/>"
      print p "  <tcpflags1/>"
      print p "  <tcpflags2/>"
      print p "  <tcpflags_any>0</tcpflags_any>"
      print p "  <categories/>"
      print p "  <sched/>"
      print p "  <tos/>"
      print p "  <shaper1/>"
      print p "  <shaper2/>"
      print p "  <description/>"
      print p "</rule>"
    }
    BEGIN { inserted = 0 }
    {
      # 进入 <OPNsense>
      if ($0 ~ /<OPNsense>/) { in_opn = 1 }

      # 离开 <OPNsense>：若整条 Firewall 链都不存在，补全后再插入
      if ($0 ~ /<\/OPNsense>/) {
        if (!inserted && saw_fw == 0) {
          print "    <Firewall>"
          print "      <Filter>"
          print "        <rules>"
          emit_rule("          ")
          print "        </rules>"
          print "      </Filter>"
          print "    </Firewall>"
          inserted = 1
        }
        in_opn = 0
      }

      # 进入 <Firewall>
      if (in_opn && $0 ~ /<Firewall>/) { in_fw = 1 }

      # 离开 <Firewall>：若没有 <Filter>，补 Filter+rules 后插入
      if (in_opn && $0 ~ /<\/Firewall>/) {
        if (!inserted && saw_fw == 1 && saw_ft == 0) {
          print "      <Filter>"
          print "        <rules>"
          emit_rule("          ")
          print "        </rules>"
          print "      </Filter>"
          inserted = 1
        }
        in_fw = 0
      }

      # 进入 <Filter>
      if (in_fw && $0 ~ /<Filter>/) { in_ft = 1 }

      # 离开 <Filter>：若没有 <rules>，补 rules 后插入
      if (in_fw && $0 ~ /<\/Filter>/) {
        if (!inserted && saw_ft == 1 && saw_rules == 0) {
          print "        <rules>"
          emit_rule("          ")
          print "        </rules>"
          inserted = 1
        }
        in_ft = 0
      }

      print

      # 在已有 <rules> 之后插入新规则
      if (in_ft && $0 ~ /<rules>/ && !inserted && saw_rules == 1) {
        emit_rule("          ")
        inserted = 1
      }
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
      log_error "防火墙规则添加失败，未能在 <OPNsense> 节点内定位到插入点"
    fi
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
