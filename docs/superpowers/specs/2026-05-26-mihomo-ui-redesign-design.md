# Mihomo for OPNsense — UI 重设计方案

**状态**：已确认（Section 0-6 全部确认；进入 spec self-review 阶段）
**日期**：2026-05-26
**目标**：重写 OPNsense 的 Mihomo 集成 UI，增加结构化配置表单、Profile 切换、订阅多源管理、极简数据面板、内核/资源在线更新。整体保持 OPNsense 视觉风格。

---

## 0. 已确认的关键决策（决策日志）

| # | 议题 | 选项 | 选择 | 理由要点 |
|---|---|---|---|---|
| Q1 | 配置编辑形态 | A 完全表单 / B 分层 / C 纯 iframe | **B 分层** | 基础设施做表单（一次配置），proxies/rules 保留 YAML（订阅动态生成） |
| Q2 | 订阅与配置关系 | A 多订阅+单激活 profile / B 合并 / C 单订阅+备份 | **A profile 模式** | 与 Clash 生态心智模型一致；与 OPNsense 多 instance 模式相符 |
| Q3 | 数据面板范围 | A 极简卡片 / B 标准 / C 全功能 | **A 极简** | 复杂查看依赖 external-ui，避免与 metacubexd 重复造轮子 |
| Q4 | 菜单与页面组织 | A 扁平多顶项 / B 双页+Tab / C 三页折衷 | **C 三页折衷** | Dashboard 落地 + Configuration 配置中心 + Subscriptions 数据源；Backup 后续独立成第 4 页 |
| Q5 | 配置切换机制 | A 全重启 / B 热重载 / C 混合 | **C 混合** | 默认热重载，失败 fallback 到 restart |
| Q6 | 内核 / GeoIP / UI 更新 | 接受建议 | **采纳** | 拉 GitHub release + SHA256 + 自动回滚；可选 GitHub mirror；自动更新默认关 |
| Q7 | OpenClash 借鉴 Override Tab | 是 / 否 | **采纳** | 解决订阅刷新覆盖用户定制的痛点（最高价值借鉴） |
| Q8 | OpenClash 借鉴 多订阅独立开关+过滤+自动更新间隔 | 是 / 否 | **采纳** | 实现成本低、易用性收益高 |
| Q9 | OpenClash 借鉴 首次向导 + 流媒体解锁检测 | 是 / 否 | **不做** | 避免范围蔓延，后续迭代再考虑 |
| Q10 | Backup 位置 | Updates Tab 下方 / 独立 Tab / 独立页 | **独立页** | 与三类资源更新解耦；OPNsense 风格里"备份"常独立 |
| Q11 | 多语言方案 | A 完整 gettext / B 字典数组预留 / C 硬编码 | **A 完整 gettext** | OPNsense 标准做法；趁 UI 重写一次性规范化，避免日后返工 |
| Q12 | 文件并发安全 | 接受审查建议 | **采纳** | `flock()` + `atomicConfigUpdate()` 统一封装；所有 config.yaml 修改路径强制走原子写入 + `mihomo -t` 验证 |
| Q13 | Override 文件结构 | split head/tail vs 单一文件+约定key | **采纳单一文件 + `prepend-rules`/`append-proxies` 等约定 key** | 更简洁，与 OpenClash 心智模型一致 |
| Q14 | Health Check 机制 | 同步并发 vs 异步后台 | **采纳异步** | PHP-FPM 不应阻塞 30s；改为后端写临时文件 + 前端轮询进度 |
| Q15 | Profile 命名空间 | 无前缀 vs `sub-` 前缀 | **采纳 `sub-` 前缀** | 防手动创建与订阅生成的 profile 命名冲突 |
| Q16 | 订阅刷新状态检测 | 靠 `last_update` 变化 vs 显式 `last_status` | **采纳显式 `last_status`** | `updating`/`done`/`failed` 三种状态，修复失败时按钮永久灰显 |
| Q17 | 流量速率计算 | 前端差分 vs 后端差分 | **采纳后端差分** | 避免浏览器休眠导致计时失真；暂存状态到 `/tmp/mihomo-traffic-state.json` |
| Q18 | 日志路径 | `/usr/local/etc/mihomo/sub/sub.log` vs FHS 合规 | **采纳 `/var/log/mihomo_sub.log`** | `/usr/local/etc/` 不应放动态日志 |
| Q19 | 文件权限 | 默认 vs 显式 `640/750` | **采纳** | 强制 `root:www` 权限；Backup 增加可选 AES-256-CBC 加密 |
| Q20 | GitHub API 限流 | 无缓存 vs 1h 缓存 + 可选 Token | **采纳** | 60 req/h 未认证限流极易触发；`latest-release.json` 缓存 TTL 1h |

---

## 1. 整体架构

### 1.1 数据流总览

```
┌──────────────────────────────────────────────────────────────┐
│  OPNsense Web UI (PHP)                                       │
│                                                              │
│   Dashboard       Configuration     Backup    Subscriptions  │
│   (流量/状态/日志) (6 Tabs)         (导入导出) (订阅源 CRUD) │
│        │                │              │           │         │
└────────┼────────────────┼──────────────┼───────────┼─────────┘
         │ HTTP            │ 文件读写       │ tar.gz     │ exec sub.sh
         ▼                ▼              ▼           ▼
  ┌──────────────┐  ┌──────────────────┐ ┌──────┐  ┌──────────────┐
  │ Mihomo API   │  │ /usr/local/etc/  │ │tar   │  │ subs.json    │
  │ 127.0.0.1:   │  │   mihomo/        │ │.gz   │  │ profiles/    │
  │ 9090         │  │                  │ │      │  │              │
  └──────────────┘  └──────────────────┘ └──────┘  └──────────────┘
                            │
                            ▼
                   ┌────────────────────┐
                   │ /usr/local/etc/    │
                   │ rc.d/mihomo        │  ← reload fallback
                   └────────────────────┘
```

### 1.2 文件布局（`/usr/local/etc/mihomo/`）

```
mihomo/
├── base.yaml                # 用户表单生成：general/tun/dns/sniffer/external-controller
├── override.yaml            # 用户覆写片段（订阅刷新不会覆盖）
├── config.yaml              # 当前激活 = base + override(head) + profile + override(tail)
├── config.yaml.bak.<ts>     # 现有备份机制保留
│
├── profiles/                # 多 profile
│   ├── sub-<name>.yaml      # 订阅生成的 profile（前缀 sub-；含 proxies/proxy-groups/rules）
│   ├── <name>.yaml          # 手动创建的 profile（无前缀）
│   └── <name>.meta.json     # {source_type: "subscription"|"manual", sub_id, last_update, node_count, source_url}
│
├── subs.json                # 订阅源列表
│                            # [{id,name,url,user_agent,enabled,
│                            #   include_keyword,exclude_keyword,
│                            #   update_interval_hours,last_update,last_status}]
├── active.json              # {"profile": "<name>"}
│
├── sub/                     # 订阅脚本目录
│   ├── sub.sh               # 重写：参数化，按 sub_id 抓取 → 生成 profiles/<name>.yaml
│   └── sub_cron.sh          # Cron 入口：遍历 subs.json 触发到期的抓取
│
├── ui/                      # external-ui（zashboard/metacubexd）
└── Country.mmdb             # GeoIP 数据

# 日志路径（FHS 合规：动态日志放 /var/log/）
/var/log/
├── mihomo.log               # 现有：mihomo 运行时日志
├── mihomo_sub.log           # 订阅抓取日志（从 /usr/local/etc/mihomo/sub/sub.log 迁移）
```

### 1.3 PHP 层文件

```
www/
├── mihomo_dashboard.php           # 落地页
├── mihomo_configuration.php       # Tabs: Settings | Override | Profiles | YAML | Log | Updates
├── mihomo_backup.php              # 全量备份导入导出
├── mihomo_subscriptions.php       # 订阅源 CRUD（替代当前 sub.php）
│
├── status_mihomo.php              # 现有，扩展返回 pid + uptime
├── status_mihomo_logs.php         # 现有，保留 + 增加 ?level= / ?lines= / ?offset= 参数
├── status_sub_logs.php            # 现有，保留（读取 /var/log/mihomo_sub.log）
├── status_mihomo_traffic.php      # 新增：代理 /traffic + /memory + /connections 数量，后端差分计算速率
├── status_mihomo_health.php       # 新增：轮询异步 Health Check 进度
├── status_mihomo_update.php       # 新增：轮询资源更新进度
│
└── includes/
    └── mihomo_lib.inc.php         # 公共库：
                                   #   - reloadMihomo() / restartMihomo()
                                   #   - readSubs() / writeSubs()
                                   #   - readProfiles() / activateProfile()
                                   #   - mergeBaseAndProfile()
                                   #   - mihomoApiCall($path, $method, $body)
                                   #   - secretFromBase()
```

### 1.4 菜单结构

```
VPN > Mihomo
├── Dashboard               (services_mihomo_dashboard.php)
├── Configuration           (services_mihomo_configuration.php)
│   ├── Settings            (base.yaml 表单)
│   ├── Override            (override.yaml YAML 片段编辑)
│   ├── Profiles            (列表 + 激活 + 删除)
│   ├── YAML                (当前激活 config.yaml 只读视图)
│   ├── Log                 (mihomo.log 查看 + 清空)
│   └── Updates             (内核/GeoIP/UI 更新)
├── Backup                  (services_mihomo_backup.php)
└── Subscriptions           (services_mihomo_subscriptions.php)
```

`menu/Magic/Menu/Menu.xml` 需要相应更新。

### 1.5 关键设计点

1. **base + override + profile 三层合成模型**：base 来自表单（用户基础设施），profile 来自订阅（机器生成），override 是用户覆盖订阅的安全区。
2. **激活公式**：`config.yaml = merge(base, override, profile)`。override 使用单一文件 + 约定内部 key（`prepend-rules`、`append-rules`、`append-proxies`、`prepend-proxy-groups`、`append-proxy-groups`），其余顶层 key 深度合并。与 OpenClash 覆盖逻辑一致。
3. **subs ↔ profile 一对一并以 `sub-` 前缀隔离**：订阅生成的 profile 强制前缀 `sub-`（如 `sub-airport-a`），手动创建的 profile 无前缀。`meta.json` 中 `source_type` 字段区分 `subscription` / `manual`。
4. **公共库单文件 `mihomo_lib.inc.php`**：所有页面 require_once 它；避免重复代码与不一致行为。
5. **不引入 WebSocket**：所有实时数据通过 PHP 短轮询代理 Mihomo API，避开 lighttpd 反代下 WS 处理。
6. **不引入图表库与 JS 框架**：纯 vanilla JS + fetch + setInterval。

---

## 1.6 国际化（gettext）

### 规范

遵循 OPNsense 标准的 gettext 国际化：
- PHP 中所有用户可见字符串使用 `gettext("...")` 包裹
- 翻译文件位于 `lang/` 目录：`lang/zh_CN/LC_MESSAGES/mihomo.po` → 编译为 `.mo`
- `menu/Menu.xml` 使用 OPNsense 的多语言 XML 模式（`<VisibleName>` + lang 属性）
- 先交付中文 `.po`（母语翻译母语），英文 `.pot` 模板同步生成供后续社区贡献

### 涉及文件

| 文件 | 需翻译内容 |
|---|---|
| 所有 `www/mihomo_*.php` | 页面标题、区块标题、按钮文字、说明文字、alert 消息 |
| `www/includes/mihomo_lib.inc.php` | 公共函数的错误/提示消息 |
| `www/status_*.php` | 返回 JSON 中的 `message` 字段（如有） |
| `menu/Magic/Menu/Menu.xml` | 菜单 `VisibleName` |

### 实施规则
- 在 `install.sh` 部署时复制 `lang/zh_CN/LC_MESSAGES/mihomo.mo` 到 OPNsense 的 locale 路径
- `guiconfig.inc` 已初始化 gettext（OPNsense 框架自带），加载 mihomo 文本域绑定即可
- 所有新 PHP 文件使用 `gettext("...")` 而非直接写中文字符串
- `install.sh` 复制 `.mo` 后重启 Web GUI 确保 gettext 缓存刷新

---

## 1.7 文件安全与并发控制

### 1.7.1 文件权限

所有配置文件强制最小权限，由 `install.sh` 和 `migrate.sh` 显式 `chmod`/`chown`：

```
chown -R root:www /usr/local/etc/mihomo/
chmod 750 /usr/local/etc/mihomo/
chmod 750 /usr/local/etc/mihomo/profiles/
chmod 640 /usr/local/etc/mihomo/base.yaml
chmod 640 /usr/local/etc/mihomo/override.yaml
chmod 640 /usr/local/etc/mihomo/subs.json
chmod 640 /usr/local/etc/mihomo/active.json
chmod 640 /usr/local/etc/mihomo/profiles/*.yaml
```

`config.yaml`（合成产物）沿用 `640 root:www`。

### 1.7.2 文件锁与原子写入

`mihomo_lib.inc.php` 提供两个核心封装：

```php
// 带排他锁写入，超时 5s；获取失败抛异常
function lockedWrite($file, $content, $timeout = 5): bool

// 原子 config 更新：写 /tmp/config.yaml.new → mihomo -t 校验 → mv 覆盖 → reload
// 任何一步失败自动保留旧 config.yaml 不变，返回 [success, message]
function atomicConfigUpdate($newContent): array
```

**规则**：所有会修改 `config.yaml` 的路径**必须**走 `atomicConfigUpdate()`：
- Settings Save（3.2）
- Override Save（3.3）
- Profile Activate（3.4）
- 订阅刷新后的自动合并（5.4）

**并发保护**：`lockedWrite()` 确保同一时刻只有一个写者。Cron 与 Web UI 同时触发写入时，后者排队等待（超时返回友好提示），避免文件截断。

### 1.7.3 Cron 文件锁与防雪崩

`sub_cron.sh` 开头加 `flock -n /tmp/mihomo-sub-cron.lock`，若锁已被持有（上次未完成）则直接退出。

在获取锁**之前**执行 `sleep $((RANDOM % 30))` 随机延迟，避免多实例整点同时请求触发机场 WAF。

---

### 1.5.1 三类资源

| 资源 | 来源 | 当前状态 | 更新方式 |
|---|---|---|---|
| **mihomo 内核** | GitHub `MetaCubeX/mihomo/releases` | 静态打包 `bin/mihomo` | 拉取 freebsd-amd64.gz + SHA256 校验 |
| **Country.mmdb** | GitHub `MetaCubeX/meta-rules-dat/releases` | 静态打包 `conf/Country.mmdb` | 拉取 + 替换；走 `PUT /configs/geo` 热重载 |
| **external-ui** | zashboard / metacubexd zip release | 静态打包 `conf/ui/` | 拉取 zip → 替换 `ui/` 目录 |

### 1.5.2 内核更新流程

```
1. [Check]  GET https://api.github.com/repos/MetaCubeX/mihomo/releases/latest
              → 优先读缓存 `/tmp/mihomo-latest-release.json`（TTL 1h）
              → 缓存缺失或 [Force Refresh] 才发起 API 请求
              → 如有 GitHub Token（Settings > GitHub Token 字段，可选），用 Authorization header 提额至 5000 req/h
              → 解出 tag_name + freebsd-amd64 asset url + .sha256 url
              → 与本地 `mihomo -v` 输出对比

2. [Update] 后台执行（execBackgroundCommand 模式）：
   a. 下载 .gz 到 /tmp/mihomo-<ver>.gz
   b. 下载 .sha256
   c. SHA256 校验失败 → 中止 + UI 显示错误
   d. gunzip → /tmp/mihomo-<ver>
   e. chmod +x
   f. smoke test：`mihomo -v` 能返回新版本号
   g. 备份当前：mv /usr/local/bin/mihomo → /usr/local/bin/mihomo.bak.<ts>
   h. 原子 mv 新二进制就位
   i. configctl mihomo restart
   j. 轮询服务状态 10s，未恢复 running → 自动回滚备份并 restart
```

### 1.5.3 自动更新（默认关闭）

Settings 表单分组 `Auto Update`：
- ☐ 自动更新 GeoIP（每周）
- ☐ 自动更新 Dashboard UI（每月）
- ☐ 自动更新 mihomo 内核（默认禁用，建议手动）

通过 `actions_mihomo.conf` 新增 cron action：
- `mihomo-update-geoip`
- `mihomo-update-ui`
- `mihomo-update-core`

### 1.5.4 GitHub Mirror

Settings 加可选字段 `GitHub Mirror`（如 `https://ghproxy.com/`），默认空。
更新请求 URL 前置该 mirror。
**不强制依赖第三方镜像**。

### 1.5.5 取舍说明

- 不引入 pkg 管理：mihomo 不在 FreeBSD 官方 ports
- install.sh 不要求执行更新：保持安装与更新解耦
- 走 GitHub release 是 OPNsense 同类插件（OpenVPN-Cloud / WireGuard）的通用做法

---

## 2. Dashboard 页详细设计

### 2.1 页面定位
- 菜单进入的落地页
- 极简：状态可视 + 服务控制 + 关键数字 + 外部 UI 入口
- 不堆功能：复杂的代理列表、连接列表、规则、Provider 全部交给 external-ui

### 2.2 布局（自上而下）

```
┌─────────────────────────────────────────────────────────────────┐
│ Service Status                                                  │
│  ● mihomo 正在运行   uptime 2d 14h   PID 23145                 │
│  [▶ Start]  [■ Stop]  [↻ Restart]  [↗ Open Dashboard UI]       │
├─────────────────────────────────────────────────────────────────┤
│ Active Profile                                                  │
│  airport-a    23 nodes    last updated 2026-05-26 03:00        │
│  [Switch Profile ▾]  [↻ Refresh Subscription]  [⚡ Health Check] │
├─────────────────────────────────────────────────────────────────┤
│ Realtime Metrics                              (poll every 2s)   │
│  ┌──────────┬──────────┬────────────┬──────────┐               │
│  │ ↑ 12.3MB │ ↓ 56.7MB │ Conns: 142 │ Mem: 89M │               │
│  │   /s     │   /s     │ Total: 2.1G│          │               │
│  └──────────┴──────────┴────────────┴──────────┘               │
├─────────────────────────────────────────────────────────────────┤
│ Recent Log Tail                                  (poll every 5s)│
│  [textarea, 最近 30 行, readonly, monospace]                    │
└─────────────────────────────────────────────────────────────────┘
```

### 2.3 数据来源

| 区块 | 端点 | 频率 |
|---|---|---|
| Service Status | `status_mihomo.php`（扩展返回 pid + uptime） | 2s |
| Active Profile | `active.json` + `profiles/<name>.meta.json` | 进入页面时读 + 切换后刷新 |
| Realtime Metrics | `status_mihomo_traffic.php`（聚合 `/traffic` + `/memory` + `/connections` 数量，后端差分计算速率） | 2s |
| Health Check Progress | `status_mihomo_health.php?uuid=<uuid>`（异步进度轮询） | 2s 直到 done |
| Recent Log Tail | `status_mihomo_logs.php`（tail -n 30） | 5s |
| Open Dashboard UI | 静态链接 `http://<opnsense_ip>:9090/ui/`，新标签 | — |

### 2.4 交互细节

**Switch Profile**：下拉列出 `profiles/*.yaml`；选中后 POST `?action=activate&profile=<name>` → `activateProfile()` → `reloadMihomo()` → alert + 状态刷新

**Refresh Subscription**：触发当前 active profile 关联 `sub_id` 的抓取；`execBackgroundCommand("bash /usr/local/etc/mihomo/sub/sub.sh <sub_id>")`；按钮灰显 + 轮询 `subs.json.last_update` 变化时恢复

**Health Check**：POST `?action=health_check&mode=quick`（默认 Quick Check：仅测 URL-Test 组内的代理节点，上限 10 个）。`?mode=full` 测全部节点。

后端流程：
1. 写入 job `/tmp/mihomo-health-<uuid>.json` → `execBackgroundCommand("bash /usr/local/bin/mihomo_health_check.sh <uuid> <profile> <mode>")`
2. 前端轮询 `status_mihomo_health.php?uuid=<uuid>` 返回 `{state: "running"|"done"|"failed", progress: {done, total}, result: {alive, dead, dead_list}}`
3. 结果**常驻显示**，直到用户切换 Profile 或点击 "Clear Results"。不自动淡出。

Health Check 脚本内部：分批每批 5 并发（降低到 5），避免 PHP-FPM 阻塞。整个过程完全异步，不占用 FPM worker。

**Realtime Metrics**：PHP 用 `stream_socket_client` 短链 `/traffic` 与 `/memory`（读 1-2 frame 即关闭）；`/connections` HTTP 调用拿数量与累计流量。

**流量速率由后端计算**：`status_mihomo_traffic.php` 将上次累计值 + 时间戳暂存到 `/tmp/mihomo-traffic-state.json`，每次请求计算 `(current - last) / deltaT`，返回 `{upRate, downRate, upTotal, downTotal}`。前端只负责显示，避免浏览器标签页休眠导致计时失真。

### 2.5 OPNsense 风格遵循
- `content-box` + `table table-striped`
- 每行 `mihomo-section-title` + 图标
- 状态灯沿用 `.mihomo-status-light.is-running/is-stopped`
- 按钮：`btn-success / btn-danger / btn-warning / btn-default`
- 仅 vanilla JS

### 2.6 错误处理
- 服务未运行：Metrics 显示 "Service not running"，按钮全灰
- API 不可达：Metrics 显示 "API unavailable, check external-controller settings"
- Open Dashboard UI 按钮：动态读取 `external-controller` 绑定地址。若为 `127.0.0.1` 或 `0.0.0.0`，按钮旁显示提示"Dashboard 监听在 localhost，请通过 LAN 访问或配置防火墙放行端口"
- 轮询异常：`fetch` 连续失败后进入指数退避（1s→2s→4s→max 10s），UI 显示 "Reconnecting..." 而非 "Service not running"
- 页面切后台：利用 `visibilitychange` 事件暂停/恢复轮询，减少无效请求

---

## 3. Configuration 页详细设计

### 3.1 整体页面结构

Tab 导航，走 URL hash 保持刷新后当前 Tab：

- Settings → Override → Profiles → YAML → Log → Updates

### 3.2 Tab 1：Settings —— base.yaml 表单

**设计原则**：只覆盖安装即用 + OPNsense 集成必需的高频字段（~40 个，Mihomo 全量 80+）。高级字段通过 YAML Tab 直接编辑 base.yaml，表单 Save 时只更新管辖字段，未管辖字段保留不动。

保存时校验：端口范围、IP 格式、必填。跑 `mihomo -t -f` 验证合成结果。通过后原子 mv → reloadMihomo()。

**Group A：General**

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| HTTP Proxy Port (`port`) | int | 7890 | 0 = 禁用 |
| SOCKS Proxy Port (`socks-port`) | int | 7891 | 0 = 禁用 |
| Mixed Port (`mixed-port`) | int | 0 | HTTP+SOCKS 混合，0 = 禁用 |
| Allow LAN (`allow-lan`) | bool | true | |
| Bind Address (`bind-address`) | str | `*` | 监听地址 |
| Mode (`mode`) | select | rule | rule / global / direct |
| Log Level (`log-level`) | select | warning | silent/error/warning/info/debug |
| IPv6 (`ipv6`) | bool | true | |
| TCP Concurrent (`tcp-concurrent`) | bool | true | |
| Find Process Mode (`find-process-mode`) | select | off | off/strict/always（strict 在 FreeBSD 上可能失效，需 tooltip 说明） |
| Global Client Fingerprint (`global-client-fingerprint`) | select | chrome | chrome/firefox/safari/ios/random |
| Unified Delay (`unified-delay`) | bool | false | |
| Interface Name (`interface-name`) | select | (auto) | 下拉填充 OPNsense 物理接口列表 |

**Group B：External Controller (API & UI)**

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| External Controller (`external-controller`) | str | `0.0.0.0:9090` | RESTful API 监听 |
| Secret (`secret`) | password | (随机生成) | API 密钥，提供 "Generate" 按钮 |
| External UI Path (`external-ui`) | str (readonly) | `/usr/local/etc/mihomo/ui` | 不可直接编辑，避免破坏 Update 流程 |

**Group C：TUN**

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| Enable TUN (`tun.enable`) | bool | true | 取消勾选让透明代理失效，二次确认 |
| Stack (`tun.stack`) | select | gvisor | system/gvisor/mixed |
| Device (`tun.device`) | str | `tun_3000` | 与 install.sh 注入 config.xml 的接口名保持一致 |
| MTU (`tun.mtu`) | int | 9000 | |
| Auto Route (`tun.auto-route`) | bool | true | |
| Strict Route (`tun.strict-route`) | bool | true | |
| Auto Detect Interface (`tun.auto-detect-interface`) | bool | true | |
| DNS Hijack (`tun.dns-hijack`) | multi-text | `any:53`, `tcp://any:53` | |

**Group D：DNS**

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| Enable (`dns.enable`) | bool | true | |
| Listen (`dns.listen`) | str | `0.0.0.0:53` | 保存时自动检测 53 端口冲突（sockstat），弹出警告提示 Unbound 占用 |
| IPv6 (`dns.ipv6`) | bool | true | |
| Enhanced Mode (`dns.enhanced-mode`) | select | fake-ip | fake-ip / redir-host / normal |
| Fake-IP Range (`dns.fake-ip-range`) | str | `198.18.0.1/16` | |
| Default Nameserver (`dns.default-nameserver`) | multi-text | `127.0.0.1:5355` | 与 Unbound 5355 配套 |
| Nameserver (`dns.nameserver`) | multi-text | `https://doh.pub/dns-query`, `https://dns.alidns.com/dns-query` | |
| Fallback (`dns.fallback`) | multi-text | (空) | |
| Fake-IP Filter (`dns.fake-ip-filter`) | multi-text | `+.lan`, `+.local`, `+.arpa` | |
| Use Hosts (`dns.use-hosts`) | bool | true | |
| Hosts (`dns.hosts`) | key-value table | (空) | |

**Group E：Sniffer**

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| Enable (`sniffer.enable`) | bool | true | |
| Force DNS Mapping (`sniffer.force-dns-mapping`) | bool | true | |
| Parse Pure IP (`sniffer.parse-pure-ip`) | bool | true | |
| Override Destination (`sniffer.override-destination`) | bool | true | |
| Sniff HTTP Ports | csv | `80, 8080-8880` | |
| Sniff TLS Ports | csv | `443, 8443` | |
| Sniff QUIC Ports | csv | `443, 8443` | |
| Skip Domains | multi-text | `+.push.apple.com` | |

**Group F：Auto Update（项目自定义，非 Mihomo 原生）**

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| GitHub Mirror | str | (空) | 加速地址前缀，如 `https://ghproxy.com/` |
| GitHub Token | password | (空) | 可选；用于 API 认证，提升速率限制至 5000 req/h |
| Auto Update GeoIP | bool | false | 每周 cron |
| Auto Update Dashboard UI | bool | false | 每月 cron |
| Auto Update mihomo Core | bool | false | 默认禁，含风险提示 |
| Health Check URL | str | `https://www.gstatic.com/generate_204` | Dashboard Health Check 使用 |
| Health Check Timeout (ms) | int | 3000 | |

### 3.3 Tab 2：Override —— 覆写片段编辑器

解决"订阅刷新覆盖用户定制"的痛点。用户维护单一 `override.yaml`，激活时自动合并到 `config.yaml`。

**约定 Key 设计**（单一文件，与 OpenClash 覆盖逻辑一致）：

```yaml
# override.yaml 示例
prepend-rules:              # 插到订阅 rules 之前（最高优先级）
  - DOMAIN-SUFFIX,my-internal.lan,DIRECT

append-rules:               # 追加到订阅 rules 之后
  - MATCH,Proxy

append-proxies:             # 追加私有节点到 proxies 列表末尾
  - name: my-private-vpn
    type: ss
    server: 1.2.3.4
    port: 8388
    ...

prepend-proxy-groups:       # 插到订阅 proxy-groups 之前
  - name: 🌍选择代理节点
    type: select
    proxies: [my-private-vpn]

append-proxy-groups:        # 追加到订阅 proxy-groups 之后

# 其他顶层 key（dns / sniffer / tun 等）走深度合并覆盖
```

**合并语义**（在 `mihomo_lib.inc.php::mergeAll()` 中手写实现）：

```
config.yaml = merge(base, override, profile)
  = base
    ⊕ override 中的约定 key 按位置插入：
      - override.prepend-rules → 插入 rules 列表头部
      - override.append-rules  → 追加到 rules 列表尾部
      - override.append-proxies → 追加到 proxies 列表
      - override.prepend-proxy-groups → 插入 proxy-groups 列表头部
      - override.append-proxy-groups  → 追加到 proxy-groups 列表尾部
    ⊕ profile 的 proxies / proxy-groups / rules（订阅生成，插入中间）
    ⊕ override 中其余顶层 key（如 dns.nameserver-policy）：深度合并覆盖
    ⊕ 冲突策略：同名 proxy-group 中 override 的 proxies 列表**追加**到 profile 的列表末尾，不覆盖
```

**UI**：说明文字 + 示例折叠区域 + YAML textarea（`override.yaml` 内容）+ [Save Override] [Validate Only] [Reset]。Validate Only 跑 `atomicConfigUpdate()` 的校验部分但不提交。Save 走 `atomicConfigUpdate()`。

### 3.4 Tab 3：Profiles —— 列表管理

表格列：Name / Source / Nodes / Last Updated / Status

**命名规则**：订阅生成的 profile 前缀 `sub-`（如 `sub-airport-a`），手动创建的 profile 无前缀。`meta.json` 中 `source_type` 字段区分 `subscription` / `manual`。

**操作**：
- **Activate**：写 `active.json` → `mergeBaseAndProfile()` 重新合成 config.yaml → `atomicConfigUpdate()` → `reloadMihomo()`
- **Refresh**：仅对 `source_type=subscription` 的 profile 显示；触发 `sub.sh <sub_id>` 后台执行，按钮 spinner + 轮询 `last_status` 直到 `done` 或 `failed`
- **View YAML**：modal 弹窗只读显示
- **Edit**：跳转到独立编辑路径 `?tab=profiles&edit=<name>`。**若 `source_type=subscription`，弹窗警告："编辑将导致此 Profile 与订阅源解绑（source_type 变为 manual），后续订阅更新将不再覆盖此文件。是否继续？"**
- **Delete**：二次确认；当前 active 禁止删除
- **Create Empty**：手动新建无订阅来源的 profile（`source_type=manual`）

### 3.5 Tab 4：YAML —— 当前激活 config.yaml

**只读视图**。提供 [Copy to Clipboard] [Download] 按钮。说明文字引导用户通过 Settings / Override / Profiles 修改源头，避免手改 config.yaml 后被 reload 覆盖。

### 3.6 Tab 5：Log —— mihomo.log 查看

保留现有状态监控模式，改进：
- [Pause Auto-refresh] [Clear Log] [Download Full Log]
- Level filter（前端 grep）、Lines 数量选择（100/200/500/1000）
- 复用现有 `status_mihomo_logs.php` + `?level=` / `?lines=` 参数

### 3.7 Tab 6：Updates —— 资源更新

三块：Mihomo Core / GeoIP Database / Dashboard UI。每块显示 Current / Latest 版本 + [Check] [Update] 按钮。

**统一更新流程**：
- [Check] 拉 GitHub API（优先 1h 缓存 + 可选 Token）
- [Update] 按钮点击后 UI 进入**锁定状态**（spinner + "Updating..."，禁止二次点击或离开页面）
- 通过新增 `status_mihomo_update.php?resource=<core|geoip|ui>` 轮询进度
- 前端收到 `done` 或 `failed` 后恢复 UI

**GeoIP 更新**：替换前 `cp Country.mmdb Country.mmdb.bak.<ts>`；走 `PUT /configs/geo` 热重载（需核实当前 mihomo 版本支持该 API，不支持则 fallback 到 reload）

**UI 更新**：目录级原子替换（`mv ui ui.bak.<ts> && mv ui-new ui`），失败可一键回滚

**内核更新**：完整备份 + SHA256 + smoke test + 轮询 10s + 自动回滚（保持 Section 1.5.2 逻辑）

UI 变体选择：zashboard / metacubexd / yacd。

### 3.8 Tab 间状态同步

每个 Tab 内 Save 完成后 dispatch `CustomEvent('mihomo:configChanged')`；YAML Tab 监听该事件刷新显示；Dashboard 页通过 status 轮询自然感知。

---

## 4. Backup 页详细设计

### 4.1 页面定位

独立顶级页。用途：换机迁移、灾难恢复、版本回滚。仅备份用户数据，不含大文件（Country.mmdb / ui / 二进制）。

### 4.2 布局

```
┌──────────────────────────────────────────────────────────────┐
│ Export Configuration                                         │
│ ⚠ Contains sensitive data (API secret, subscription URLs,   │
│   proxy credentials). Store securely.                       │
│ ☐ Encrypt with AES-256-CBC (password required)              │
│ [⬇ Download Backup]                                          │
├──────────────────────────────────────────────────────────────┤
│ Import Configuration                                         │
│ ☐ Backup file is encrypted (enter password)                 │
│ Conflict policy:  ○ Overwrite all                            │
│                   ● Merge (keep existing items not in backup)│
│ ☐ Restart mihomo after import                                │
│ [Choose File] [⬆ Import Backup]                              │
├──────────────────────────────────────────────────────────────┤
│ Recent Local Backups                                         │
│ Date              Size    Actions                            │
│ (列表: Download / Restore / Delete)                          │
│                                                              │
│ Auto-backup: ☐ Before each Override save                     │
│              ☐ Before each Profile activation                │
└──────────────────────────────────────────────────────────────┘
```

### 4.3 实现细节

**Export**：`tar -czf /tmp/mihomo-backup-<hostname>-<ts>.tar.gz -C /usr/local/etc/mihomo base.yaml override.yaml subs.json active.json profiles/` → 若勾选加密，`openssl enc -aes-256-cbc -pbkdf2 -pass pass:<password>` 二次处理 → `readfile()` 输出 → 删除 tmp。

**Import**：若加密，先 `openssl enc -d -aes-256-cbc -pbkdf2` 解密。Overwrite 策略：直接覆盖。**Merge 策略**：`subs.json` 按 id 合并；`profiles/*.yaml` 同名覆盖、本地独有保留；`base.yaml` / `override.yaml` 为**整文件覆盖**（UI 明确提示 "Base/Override 配置将被完全替换"）。校验合成结果通过 `mihomo -t` 才提交；失败自动回滚（导入前自动 export 一份 fallback backup）。

**Recent Local Backups**：存放在 `backups/` 目录，保留最近 10 份，超出自动删除最旧的。

---

## 5. Subscriptions 页详细设计

### 5.1 页面定位

数据源管理：维护订阅源 + 触发抓取 + 查看抓取日志。与 Profile 一对一（默认每个订阅生成同名 profile）。

### 5.2 布局

表格列：Enabled / Name / URL / Filter / Update Interval / Last Update / Last Status。每行操作：[Refresh Now] [Edit] [Delete]。[+ Add Subscription] 按钮。

底部：Subscription Log textarea（复用 `status_sub_logs.php` + `?lines=` 参数）。

### 5.3 Add / Edit 表单字段

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| Name | str | (必填) | 同时作为 profile 名（仅允许字母/数字/`-_`） |
| URL | str | (必填) | 支持 Clash / Mihomo / V2Ray 格式 |
| Custom User-Agent | str | `clash-verge/v1.7.0` | 部分机场按 UA 返回不同内容 |
| Enabled | bool | true | |
| Auto Update Interval | select | 6h | off / 1h / 6h / 12h / 24h |
| Include Keyword | csv | (空) | 节点名必须包含其一（如 `HK,SG`） |
| Exclude Keyword | csv | `剩余,流量,过期,官网,套餐` | 命中即丢弃 |

### 5.4 抓取流程（重写后的 sub.sh）

```bash
# sub.sh <sub_id>
# 1. 更新 subs.json 中 last_status = "updating"
# 2. 从 subs.json 解出 url/UA/filter
# 3. curl 下载到 /tmp/sub-<sub_id>.raw
# 4. 提取 proxies/proxy-groups/rules（仅过滤 proxies 节点名，不影响 proxy-groups 的正则匹配）
# 5. 应用 include/exclude 关键词过滤
# 6. 先写入 /tmp/sub-<sub_id>.yaml，跑 mihomo -t 校验语法
# 7. 校验通过 → mv 覆盖 profiles/sub-<name>.yaml；失败 → 保留旧 profile 不动
# 8. 更新 profiles/sub-<name>.meta.json（含 node_count + last_update）
# 9. 更新 subs.json 的 last_update + last_status = "done"（或 "failed" + 错误信息）
# 10. 如果 active → atomicConfigUpdate() + reloadMihomo
# 11. stdout/stderr 写 /var/log/mihomo_sub.log（每行带 [sub_id=...] 前缀）
```

**订阅格式说明**：优先保证 Clash/Mihomo 原生 YAML 格式的健壮性。V2Ray 原生格式（base64 编码的 VMess/VLESS 链接）需额外转换逻辑，首期不支持，UI 中明确提示用户使用 Clash/Mihomo 格式订阅链接。

### 5.5 Auto Update 实现

统一通过 OPNsense cron 框架：`actions_mihomo.conf` 注册一个 `[sub-update]` 动作，每小时跑 `sub_cron.sh`：

1. `sleep $((RANDOM % 30))` 随机延迟（防机场 WAF）
2. `flock -n /tmp/mihomo-sub-cron.lock` 防止并发（上次未完成则退出）
3. 遍历 `subs.json`，判断每条记录的 `last_update + update_interval_hours`，到期触发 `sub.sh <sub_id>`

不为每个订阅注册独立 cron 入口。

---

## 6. 迁移与向后兼容

### 6.1 现状

现有用户的 `/usr/local/etc/mihomo/config.yaml` 含全部配置。没有 `base.yaml` / `override.yaml` / `profiles/`。

### 6.2 升级路径

`install.sh` 检测 `base.yaml` 不存在 → 运行 `migrate.sh`：

0. **停止 mihomo 服务**：`configctl mihomo stop`（防止新旧配置同时运行导致端口冲突）
1. 备份当前状态：`tar -czf backups/pre-upgrade-<ts>.tar.gz .`
2. 解析 `config.yaml`：
   - 提取 general/tun/dns/sniffer/external-controller → 写入 `base.yaml`
   - 提取 proxies/proxy-groups/rules → 写入 `profiles/legacy.yaml`
   - 写 `profiles/legacy.meta.json`（`source_type = "manual"`）
   - 写 `active.json: {"profile": "legacy"}`
   - 创建空 `override.yaml`
3. 迁移旧订阅：`sub/env` 存在合法 URL → `subs.json` 新增 `id=migrated-1` 条目，提示用户手动 Refresh
4. 校验合成结果通过 `mihomo -t -f` → 写 `.migrated-v2` 标志文件 → 启动 mihomo
5. 不通过：保留旧 `config.yaml` 不动，**拒绝注册新菜单/新 PHP 页面**，UI 显示强拦截错误 "Migration failed, please resolve manually or restore from backup"

`migrate.sh` 幂等（检测 `.migrated-v2` 跳过）。

### 6.3 旧 UI 兼容

- 旧 URL `/services_mihomo.php` / `/sub.php` → 302 跳转到新页
- 三个 status 端点路径保留
- `actions_mihomo.conf` 中 `[sub-update]` 动作名称不变，仅改 command
- Dashboard 页顶部增加**可关闭横幅**（dismissible）："UI 已升级至新版本，原配置已自动迁移。如有问题请前往 Backup 页面恢复。" 持续展示 2 周降低老用户困惑

### 6.4 卸载兼容

`uninstall.sh` 增加清理 `base.yaml override.yaml subs.json active.json profiles/ backups/`。交互询问 `Do you want to keep user data? [y/N]`。

---

## 7. 非目标 / Out of Scope

明确**不做**的内容：
- 首次使用向导
- 流媒体解锁检测 / IP 归属地检测
- Fake-IP/Redir-Host 模式切换（项目锁定 TUN）
- 多内核切换（仅 mihomo）
- 自定义 Hosts 独立页（归入 Settings 表单的 DNS 分组）
- 自定义防火墙规则注入（OPNsense 原生防火墙处理）
- Chain Proxy / 游戏规则页
- 图表 / 折线图
- WebSocket 直连
- 嵌入 iframe 的 external-ui
- V2Ray 原生格式（base64 VMess/VLESS）订阅转换（首期仅支持 Clash/Mihomo YAML 格式）

---

## 8. 风险与未决

- **YAML 解析丢失注释/锚点**：PHP 将 YAML 解析为数组再 dump 会丢失注释和锚点引用（`&`/`*`）。`base.yaml` 由表单生成不受影响；`override.yaml` 和 `profile` 中的锚点如果跨文件引用会失效。实施时需评估是否改用 Symfony YAML 库的结构化合并（保留更多语义），或在前端明确提示限制。
- **mihomo 热重载稳定性**：`PUT /configs?force=true` 在涉及 TUN/DNS 变更时可能不稳定。实施时在 reload 后延迟 1-2s 再验证状态，避免误判失败触发不必要的 restart。
- **GeoIP 热重载 API 可用性**：`PUT /configs/geo` 在某些 mihomo 版本可能不支持，实施前需针对当前版本实测，不可用则 fallback 到完整 reload。
- **Health Check 异步队列**：后台脚本执行 Health Check 时需要确保不冲突 `atomicConfigUpdate()` 的文件锁。
- **GitHub Release FreeBSD-amd64 asset 命名**：需核实最新命名规范，写在 mihomo_lib 中（上游改名时需 patch）。
- **install.sh 升级路径**：迁移失败时拒绝注册新 UI（避免用户进入半残的新界面），需在 install.sh 中实现条件判断逻辑。
- **YAML 合并逻辑维护性**：手写合并函数随 Mihomo 配置字段增加可能膨胀。设计为单文件内按区块划分注释（`// === MERGE ===`），预留拆分空间。
