# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

Mihomo for OPNsense — 在 OPNsense 防火墙上集成 Mihomo（透明代理），通过 OPNsense Web UI 管理配置、服务控制和日志查看。仅在 x86_64 + OPNsense 26.1.6 测试通过。

## 技术栈

- **Shell** — install.sh / uninstall.sh 部署脚本
- **PHP** — OPNsense Web UI 页面（遵循 OPNsense `guiconfig.inc` + `head.inc` / `fbegin.inc` / `foot.inc` 框架）
- **FreeBSD rc.d** — 服务管理脚本，通过 `/usr/sbin/daemon` 包裹进程

## 架构

### 部署流程 (install.sh)

`install.sh` 是核心部署脚本，将仓库文件部署到 OPNsense 系统路径，并修改 `/conf/config.xml`：
1. 复制 `bin/` → `/usr/local/bin/`（mihomo 二进制 + 工具）
2. 复制 `www/` → `/usr/local/www/`（PHP Web 页面）
3. 复制 `rc.d/` → `/usr/local/etc/rc.d/`（服务脚本）
4. 复制 `actions/` → `/usr/local/opnsense/service/conf/actions.d/`（configd action 配置）
5. 复制 `plugins/` → `/usr/local/etc/inc/plugins.inc.d/`（插件注册：服务列表 + syslog）
6. 复制 `menu/` → `/usr/local/opnsense/mvc/app/models/OPNsense/`（菜单 XML）
7. 复制 `conf/` → `/usr/local/etc/mihomo/`（mihomo 默认配置 + Country.mmdb）
8. 创建 `/usr/bin/sub` → 订阅更新入口脚本
9. 用 awk 修改 `/conf/config.xml`：添加 tun_3000 接口、防火墙规则、将 Unbound DNS 端口改为 5355
10. 重启 configd、Unbound、防火墙

### 服务控制三层架构

```
OPNsense Web UI (PHP)
  → configctl <service> start/stop/restart/status  (configd action)
    → /usr/local/etc/rc.d/<service>                  (FreeBSD rc.d script)
      → /usr/sbin/daemon -P <pidfile> -o <logfile>   (守护进程包裹)
        → /usr/local/bin/<binary>                     (实际程序)
```

- **PHP 层**：`www/services_mihomo.php` — 通过 `exec("/usr/local/sbin/configctl mihomo ...")` 调用 configd
- **configd action 层**：`actions/actions_mihomo.conf` — 定义 start/stop/restart/status 等动作与 rc.d 脚本的映射；还注册了 cron 任务（订阅更新）
- **rc.d 层**：`rc.d/mihomo` — FreeBSD 服务管理，使用 `/usr/sbin/daemon` 守护进程化
- **插件层**：`plugins/mihomo.inc` — 向 OPNsense 注册服务（仪表盘显示 + syslog 设施 + WAN IP 变更时自动重启 mihomo）

### DNS 链路

```
客户端 DNS 请求
  → Mihomo (tun, dns-hijack any:53)     # 劫持所有 DNS
    → Mihomo 内置 DNS 解析               # 直连/代理分流
```

### 端口分配

| 端口 | 服务 |
|------|------|
| 53 | Mihomo DNS 劫持入口 |
| 5355 | Unbound DNS（OPNsense 默认 DNS 改到此端口） |
| 7890 | Mihomo HTTP 代理 |
| 7891 | Mihomo SOCKS5 代理 |
| 9090 | Mihomo API / Dashboard UI |

### 订阅机制

`sub/` 目录在仓库中不存在，由 `install.sh` 在部署时创建 `/usr/local/etc/mihomo/sub/`。订阅流程：
- `www/sub.php` — Web UI：保存订阅 URL + 密钥到 `/usr/local/etc/mihomo/sub/env`，触发 `sub.sh` 后台执行
- `sub.sh` — 下载订阅 → 解析代理节点 → 合并到 `/usr/local/etc/mihomo/config.yaml`
- `/usr/bin/sub` — install.sh 生成的入口，指向 `bash /usr/local/etc/mihomo/sub/sub.sh`
- 通过 configd action `actions_mihomo.conf` 中的 `[sub-update]` 注册为 cron 任务

### PHP 页面结构

所有 PHP 页面遵循相同模式：
- 引入 `guiconfig.inc`、`head.inc`、`fbegin.inc`（OPNsense 框架）
- 定义配置路径、通用函数（`execCommand`、`execBackgroundCommand`、`saveConfig`、`clearLogFile`、服务操作）
- POST 处理 → 渲染 Bootstrap 风格 HTML 表格
- 通过 `fetch()` + `setInterval` 轮询 `/status_*.php` 端点获取实时状态/日志
- 引入 `foot.inc`

管理页面：`services_mihomo.php`、`sub.php`
状态 API：`status_mihomo.php`（JSON）、`status_mihomo_logs.php`、`status_sub_logs.php`（text/plain）

### 配置校验

- Mihomo：保存前通过 `mihomo -t -f <tempfile>` 校验 YAML 语法
- 保存前创建 `.bak.Ymd_His` 备份

## 修改指引

- **新增菜单项**：修改 `menu/Magic/Menu/Menu.xml`，添加新的 `<PageName>` 节点
- **新增服务**：需要配套 rc.d 脚本 + actions conf + plugin inc + rc.conf + PHP 页面
- **修改默认配置**：改 `conf/config.yaml`（mihomo）
- **修改部署逻辑**：改 `install.sh`，注意 awk 对 `/conf/config.xml` 的操作
- **修改 UI**：改对应 `www/*.php`，遵循 OPNsense 框架约定

---

## 活跃任务：UI 重设计（2026-05-26）

### 当前阶段

头脑风暴已完成，设计文档已确定并经审查修订。下一步是 **writing-plans → 实施编码**。

### 设计文档

→ [docs/superpowers/specs/2026-05-26-mihomo-ui-redesign-design.md](docs/superpowers/specs/2026-05-26-mihomo-ui-redesign-design.md)

### 重设计目标

重写 OPNsense 的 Mihomo 集成 UI：
1. **配置页重写**：结构化表单替代裸 YAML 文本框（base.yaml 表单化，选 ~40 个高频字段）
2. **订阅配置切换**：多订阅 + 单激活 Profile 模式（profile 切换器）
3. **极简数据面板**：Dashboard 页（状态卡片 + 流量数字 + 日志尾部），复杂功能依赖 external-ui
4. **内核/资源在线更新**：mihomo / GeoIP / Dashboard UI 三资源在线更新 + 自动回滚
5. **OPNsense 风格 UI**：遵循 OPNsense 框架约定 + gettext 国际化

### 关键架构决策

**配置分层模型（base + override + profile）**：

```
config.yaml = merge(base, override, profile)

base.yaml      ← Settings 表单生成（general/tun/dns/sniffer/external-controller）
override.yaml  ← 用户覆写片段（订阅刷新不会覆盖），单一文件 + 约定 key：
                 prepend-rules / append-rules / append-proxies /
                 prepend-proxy-groups / append-proxy-groups，其余顶层 key 深度合并
profile        ← 订阅生成或手动创建（仅 proxies/proxy-groups/rules）
```

**配置切换**：混合机制——默认走 `PUT /configs?force=true` 热重载，失败 fallback 到 `configctl mihomo restart`。reload 后延迟 1-2s 再验状态防误判。

**Profile 命名**：订阅生成的 profile 强制 `sub-` 前缀（如 `sub-airport-a`），手动创建的无前缀。`meta.json` 中 `source_type` 区分 `subscription` / `manual`。

**文件安全**：
- 权限：配置文件 `640 root:www`，目录 `750`
- 并发：`lockedWrite()` + `flock()` 防止 Cron 与 Web UI 同时写入截断文件
- 原子写入：`atomicConfigUpdate()` — 所有 config.yaml 修改路径（Settings Save / Override Save / Profile Activate / 订阅刷新合并）必须走此函数（写 tmp → `mihomo -t` 校验 → mv 覆盖 → reload）

**Dashboard 数据流**：
- 流量/内存/连接数 → `status_mihomo_traffic.php`（后端差分计算速率，避免浏览器休眠失真）
- 节点健康检查 → 异步队列（写 job → 后台脚本分批 5 并发 → 前端轮询 `status_mihomo_health.php`），结果常驻显示
- 轮询异常 → 指数退避（1s→2s→4s→max 10s）+ "Reconnecting..."
- 页面切后台 → `visibilitychange` 暂停/恢复轮询
- Dashboard UI 链接 → 动态读取 external-controller 地址，绑定 localhost 时给出提示

### 新菜单结构

```
VPN > Mihomo
├── Dashboard               (mihomo_dashboard.php)      — 落地页
├── Configuration           (mihomo_configuration.php)  — 6 Tab:
│   ├── Settings            (base.yaml 表单 A-F 组)
│   ├── Override            (override.yaml 编辑器)
│   ├── Profiles            (列表 + 切换 + 激活)
│   ├── YAML                (当前 config.yaml 只读)
│   ├── Log                 (mihomo.log 查看 + 过滤)
│   └── Updates             (内核/GeoIP/UI 在线更新)
├── Backup                  (mihomo_backup.php)         — 导入导出/加密
└── Subscriptions           (mihomo_subscriptions.php)  — 订阅源 CRUD
```

### 新文件布局（PHP 层）

```
www/
├── mihomo_dashboard.php
├── mihomo_configuration.php    (6 Tab 单页)
├── mihomo_backup.php
├── mihomo_subscriptions.php
├── status_mihomo.php           (现有，扩展 pid+uptime)
├── status_mihomo_logs.php      (现有，+?level=/--lines=)
├── status_sub_logs.php         (现有，读 /var/log/mihomo_sub.log)
├── status_mihomo_traffic.php   (新增，后端差分速率)
├── status_mihomo_health.php    (新增，异步 Health Check 进度)
├── status_mihomo_update.php    (新增，资源更新进度)
└── includes/
    └── mihomo_lib.inc.php      (公共库：
        - lockedWrite() / atomicConfigUpdate()
        - reloadMihomo() / restartMihomo()
        - mergeAll()            — 三层合并，手写实现不用通用 deep-merge 库
        - mihomoApiCall() / secretFromBase()
        - readSubs() / writeSubs() / readProfiles() / activateProfile()
        - 按区块注释划分：// === CONFIG === // === API === // === MERGE ===)

/usr/local/etc/mihomo/ (运行时)：
├── base.yaml / override.yaml / config.yaml / config.yaml.bak.<ts>
├── profiles/sub-<name>.yaml / <name>.meta.json
├── subs.json / active.json / sub/ / ui/ / Country.mmdb
└── backups/  (自动备份，保留最近 10 份)

/var/log/mihomo_sub.log  (FHS 合规，动态日志放 /var/log/)
```

### Settings 表单字段分组（base.yaml ~40 个高频字段）

| Group | Key Fields |
|---|---|
| A: General | port, socks-port, mixed-port, allow-lan, mode, log-level, ipv6, interface-name, tcp-concurrent, find-process-mode, global-client-fingerprint, unified-delay |
| B: External Controller | external-controller, secret, external-ui (readonly) |
| C: TUN | enable, stack, device=tun_3000, mtu, auto-route, strict-route, auto-detect-interface, dns-hijack |
| D: DNS | enable, listen (含 53 端口冲突检测), ipv6, enhanced-mode, fake-ip-range, default-nameserver:5355, nameserver, fallback, fake-ip-filter, use-hosts, hosts |
| E: Sniffer | enable, force-dns-mapping, parse-pure-ip, override-destination, sniff ports |
| F: Auto Update | GitHub Mirror, GitHub Token (可选), auto-update 开关, Health Check URL, timeout |

表单未覆盖的字段由 YAML Tab 直接编辑 base.yaml，Save 时读取现有文件 → 覆盖表单管辖 key → 写回（不丢失未管辖字段）。

### 订阅机制（重写后）

- `subs.json` 字段：`id, name, url, user_agent, enabled, include_keyword, exclude_keyword, update_interval_hours, last_update, last_status(updating/done/failed)`
- `sub.sh <sub_id>` 参数化；下载前标记 `last_status=updating`；写入前先 `mihomo -t` 校验；完成标记 `done` 或 `failed`
- `sub_cron.sh`：每小时触发 → `sleep $((RANDOM % 30))` 随机延迟 → `flock -n` 防并发 → 遍历到期订阅
- 关键词过滤仅作用于 proxies 节点名，不影响 proxy-groups 的正则匹配

### 资源更新

- mihomo 内核 / GeoIP / Dashboard UI 三类在线更新
- GitHub API：`/tmp/mihomo-latest-release.json` 缓存 TTL 1h + 可选 Token 提额
- 内核更新流程：下载 .gz → SHA256 校验 → smoke test → 备份 → 原子替换 → restart → 轮询 10s 未恢复则自动回滚
- GeoIP 更新前备份；走 `PUT /configs/geo` 热重载（需实测，不支持则 fallback 到 reload）
- UI 更新：目录级原子替换 + 可一键回滚
- Updates Tab 点击更新后 UI 进入锁定状态

### 迁移 (migrate.sh)

install.sh 检测 `base.yaml` 不存在时运行：
0. **先停止 mihomo**（防新旧配置同时跑）
1. 备份当前 → 解析旧 config.yaml → 拆分为 base.yaml + profiles/legacy.yaml + active.json + 空 override.yaml
2. 旧 sub/env → subs.json 条目
3. 校验合成结果 → 通过才写 `.migrated-v2` 标志 + 启动 mihomo
4. 失败 → 保留旧文件不动，**拒绝注册新菜单/新 PHP 页面**，UI 显示强拦截错误
5. 幂等（检测 .migrated-v2 跳过）

旧 URL `/services_mihomo.php` / `/sub.php` → 302 跳转。Dashboard 顶显示可关闭升级横幅 2 周。

### 国际化

gettext 标准。翻译文件 `lang/zh_CN/LC_MESSAGES/mihomo.po` → 编译 `.mo`。`install.sh` 复制后重启 Web GUI。所有新 PHP 用 `gettext("...")`。

### 明确不做（Out of Scope）

首次向导、流媒体解锁检测、Fake-IP/Redir-Host 切换、多内核切换、自定义 Hosts 独立页、防火墙规则注入、Chain Proxy、游戏规则、图表/折线图、WebSocket 直连、iframe external-ui、V2Ray 原生格式订阅转换（首期仅 Clash/Mihomo YAML）、Regex 关键词过滤、响应式布局、per-profile override、Log 增量 offset 模式

### 技术约束

- 仅 vanilla JS（fetch + setInterval），不引入 JS 框架或图表库
- 不引入 WebSocket（PHP 短轮询代理 Mihomo API）
- 不引入第三方 YAML 库（手写合并，风险项：可能丢失注释/锚点，实施时再评估）
- 仅 x86_64 + OPNsense 26.1.6 测试通过
- 后台耗时操作统一走 `execBackgroundCommand` + 前端轮询进度
