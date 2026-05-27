# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概述

Mihomo for OPNsense — 在 OPNsense 防火墙上集成 Mihomo（透明代理），通过 OPNsense Web UI（MVC 模式）管理配置、Profile 切换、订阅、备份、内核与资源更新。仅在 x86_64 + OPNsense 26.1.6 测试通过。

> **本项目不考虑与 v1（raw-PHP UI）的兼容**：无迁移脚本、无 302 跳转、无旧文件保留。当前仓库只包含 v2 实现。

## 技术栈

- **PHP** — OPNsense MVC 控制器（Phalcon），Volt 模板视图
- **Python 3** — configd 后端脚本（YAML 合并、订阅抓取、内核/GeoIP/UI 更新、健康检查）
- **POSIX sh / bash** — install.sh / uninstall.sh / sub_cron.sh
- **FreeBSD rc.d** — 服务管理脚本，通过 `/usr/sbin/daemon` 包裹进程
- **JS** — vanilla JS + OPNsense 自带 jQuery + Bootstrap，无外部框架

## 端口分配

| 端口 | 服务 |
| ------ | ------ |
| 53 | Mihomo DNS 劫持入口 |
| 5355 | Unbound DNS（OPNsense 默认 DNS 改到此端口） |
| 7890 | Mihomo HTTP 代理 |
| 7891 | Mihomo SOCKS5 代理 |
| 9090 | Mihomo API / Dashboard UI |

## 仓库结构

```text
Mihomo-for-OPNsense/
├── bin/                    — 静态打包的 mihomo 二进制（FreeBSD-amd64 ELF）
├── conf/                   — 默认配置模板：base.yaml / override.yaml / Country.mmdb / ui/
├── docs/superpowers/specs/ — 设计 + 实施计划文档
├── lang/zh_CN/LC_MESSAGES/ — mihomo.po (中文) + mihomo.mo (编译产物)
├── plugins/mihomo.inc      — OPNsense 服务注册（仪表盘 + syslog + WAN IP 变化重启)
├── rc.d/mihomo             — FreeBSD rc.d 脚本
├── rc.conf/mihomo          — rc.conf.d 启用配置
├── src/opnsense/           — MVC 全量代码（详见下方）
├── install.sh              — 部署脚本
└── uninstall.sh            — 清理脚本
```

### MVC 文件布局（`src/opnsense/`）

```text
mvc/app/
├── controllers/OPNsense/Mihomo/
│   ├── IndexController.php             — /ui/mihomo/ → dashboard 302
│   ├── DashboardController.php         — 渲染 dashboard.volt
│   ├── ConfigurationController.php     — 渲染 configuration.volt + 注入 Forms XML
│   ├── Api/MihomoFileTrait.php         — 共享 Trait：lockedWrite/atomicWrite/configdRun/atomicConfigUpdate/mihomoApiCall/readProfiles/createBackup
│   ├── Api/ServiceController.php       — service/{status,start,stop,restart,reconfigure}
│   ├── Api/SettingsController.php      — ApiMutableModelControllerBase；set 后自动 reconfigure
│   ├── Api/SubscriptionsController.php — ApiMutableModelControllerBase + refresh/log
│   ├── Api/OverrideController.php      — override.yaml CRUD + validate + composedYaml
│   ├── Api/ProfilesController.php      — 列表/激活/refresh/createEmpty/setYaml（含订阅解绑保护）
│   ├── Api/UpdateController.php        — check/run/progress（GitHub 1h 缓存 + Token + Mirror）
│   ├── Api/BackupController.php        — export/import/list/download/restore/delete（AES-256-CBC 可选）
│   ├── Api/DashboardController.php     — traffic/logs/healthCheck/healthProgress
│   └── forms/
│       ├── general.xml controller.xml tun.xml dns.xml sniffer.xml update.xml — Settings 各 Group
│       └── dialogSubscription.xml      — Subscription 编辑对话框（含 grid_view 自动派生列）
├── models/OPNsense/Mihomo/
│   ├── Mihomo.php / Mihomo.xml         — Settings（~40 字段）+ Subscription ArrayField + state.active_profile
│   ├── ACL/ACL.xml                     — page-mihomo-dashboard / page-mihomo-configuration
│   └── Menu/Menu.xml                   — VPN > Mihomo > Dashboard | Configuration
└── views/OPNsense/Mihomo/
    ├── dashboard.volt                  — 4 区块（状态/Profile/指标/日志）+ 自包含 JS 轮询
    └── configuration.volt              — 8 Tab（Settings/Subscriptions/Profiles/Override/YAML/Log/Updates/Backup）+ Apply 按钮 + Subscription Dialog

scripts/mihomo/
├── reconfigure.py                      — configd [reconfigure] 入口：渲染 base.yaml → 三层合并 → mihomo -t → reload（PUT /configs?force=true）→ restart fallback
├── sub.sh                              — 订阅抓取 worker（Python + py-yaml）
├── sub_cron.sh                         — cron 入口（POSIX sh + jitter + flock）
├── mihomo_health_check.sh              — 健康检查 worker（异步队列 + 进度文件）
├── update_core.sh                      — 内核更新（SHA256 + smoke test + 自动回滚）
├── update_geoip.sh                     — GeoIP 更新（PUT /configs/geo + reconfigure fallback）
└── update_ui.sh                        — UI 更新（zashboard/metacubexd/yacd，zip/tgz/tar.xz）

service/conf/actions.d/actions_mihomo.conf  — 11 个 configd action（长任务用 daemon -f 后台化 + 正则参数验证）
```

## 服务控制四层架构

```text
Web UI (Volt + JS)
  → /api/mihomo/<resource>/<action>           (Phalcon Controller, 同步)
    → configctl mihomo <action> [args]        (configd action, 短/长任务区分)
      → /usr/sbin/daemon -f <script.py> ...   (长任务后台化，仅 sub-refresh/update-*/health-check)
        OR
      → <script.py> 直接同步                  (短任务：reconfigure / start / stop / restart / status)
        → /usr/local/etc/rc.d/mihomo          (FreeBSD rc.d → daemon → /usr/local/bin/mihomo)
```

**configd 动作清单**（`src/opnsense/service/conf/actions.d/actions_mihomo.conf`）：

| Action | 同步/异步 | 参数验证 |
| --- | --- | --- |
| start / stop / restart / status | 同步 | 无 |
| reconfigure | 同步 | 无 |
| sub-update（cron 入口） | 同步 | 无 |
| sub-refresh | `daemon -f` 异步 | `[0-9a-f-]{36}` (OPNsense UUID) |
| update-core / update-geoip | `daemon -f` 异步 | 无 |
| update-ui | `daemon -f` 异步 | `(zashboard\|metacubexd\|yacd)` |
| health-check | `daemon -f` 异步 | `[a-f0-9]{16,64},[a-zA-Z0-9_-]{1,64},(quick\|full)` |

## 配置分层模型

`config.yaml = merge(base, override, profile)` — 由 `reconfigure.py` 统一合成：

- **base.yaml** — 由 Settings 表单从 OPNsense `config.xml` 渲染（general/controller/tun/dns/sniffer + 自定义 update 组）
- **override.yaml** — 用户覆写片段（订阅刷新不会覆盖）。约定键：
  - `prepend-rules` / `append-rules` — 插入/追加规则
  - `append-proxies` — 追加自定义代理节点
  - `prepend-proxy-groups` / `append-proxy-groups` — 插入/追加 proxy-groups
  - 其余顶层键深度合并
- **profile** — `profiles/<name>.yaml`，订阅生成（`sub-<name>.yaml`）或手动创建（无前缀）。仅包含 `proxies` / `proxy-groups` / `rules` / `proxy-providers` / `rule-providers`
- **state.active_profile** — 存于 OPNsense config.xml，指向当前激活的 profile 文件名

**配置应用**：所有写路径（Settings Save / Override Save / Profile Activate / 订阅刷新合并）统一走 `MihomoFileTrait::atomicConfigUpdate()` → `configctl mihomo reconfigure`。reconfigure 内：

1. 读 config.xml 渲染 base.yaml
2. 三层合并
3. 写 `/tmp/mihomo-config.yaml.new`
4. `mihomo -t -f` 校验
5. 成功后 `os.replace` 到 `/usr/local/etc/mihomo/config.yaml`（保留 `.bak.<ts>`）
6. `PUT /configs?force=true` 热重载；失败 fallback 到 `rc.d/mihomo onerestart`

## 订阅机制

- 订阅记录存于 OPNsense `/conf/config.xml`（`OPNsense/Mihomo/mihomo/subscriptions/subscription` ArrayField）
- 字段：`enabled, name, url, user_agent, interval(hours), include_keyword, exclude_keyword, last_update, last_status(idle/updating/done/failed)`
- 名称约束：`[a-zA-Z0-9_-]+`，生成的 profile 名为 `sub-<name>.yaml`
- `sub.sh <uuid>` 抓取流程：
  1. 每 UUID `flock /tmp/mihomo-sub-<uuid>.lock` 防并发
  2. 在 `/conf/config.xml` 上 LOCK_EX 修改 `last_status=updating`
  3. urllib 下载到内存，YAML 解析
  4. 关键词过滤 proxies 节点名，同步重写 proxy-groups[].proxies 引用（保留 DIRECT/REJECT/跨组引用）
  5. 合并到 base.yaml 后用 `mihomo -t -f` 验证
  6. 通过则 `os.replace` 到 `profiles/sub-<name>.yaml`，写 `.meta.json`
  7. 更新 config.xml 的 `last_status=done` + `last_update`（ISO 8601 UTC）
  8. 若激活 profile 是本订阅，触发 `configctl mihomo reconfigure`
- `sub_cron.sh` 由 OPNsense cron 调用：jitter 0-30s + 全局 flock + Python 扫 config.xml + 对到期订阅逐个调用 sub.sh

## 资源更新

| 资源 | GitHub 仓库 | 当前版本检测 | 更新方式 |
| --- | --- | --- | --- |
| Mihomo Core | `MetaCubeX/mihomo` | `mihomo -v` | 下载 .gz → SHA256 → gunzip → smoke test → 备份 → 原子 mv → restart → 10s 内未恢复回滚 |
| GeoIP | `MetaCubeX/meta-rules-dat` | mtime 日期 | 下载 Country.mmdb → 备份 → 原子 mv → `PUT /configs/geo` 优先，fallback reconfigure |
| Dashboard UI | `Zephyruso/zashboard` / `MetaCubeX/metacubexd` / `haishanh/yacd` | `ui/.version-<variant>` 文件 | 下载 zip/tgz/tar.xz → 路径穿越校验后解压 → 备份原 ui/ → 整目录 mv 替换 |

GitHub API：所有 release 元数据缓存 `/tmp/mihomo-release-cache-*.json`，TTL 1h。可选 GitHub Token（提至 5000 req/h）+ GitHub Mirror 前缀。

更新进度：每个脚本写入 `/tmp/mihomo-update-<resource>.json`，前端通过 `/api/mihomo/update/progress` 轮询。

## 文件安全

- 权限：所有 `/usr/local/etc/mihomo/` 下文件 `640 root:www`、目录 `750`
- 并发：
  - `MihomoFileTrait::lockedWrite()` — flock LOCK_EX + 5s 超时
  - `reconfigure.py::_acquire_lock()` — `/tmp/mihomo-reconfigure.lock`（非阻塞，并发触发直接退出）
  - `sub.sh` 每 UUID 独立锁 + 写 config.xml 时与 OPNsense 共享 LOCK_EX 同步
- 原子写入：所有 config.yaml / base.yaml / override.yaml / profile.yaml 修改路径都走 tmp + rename

## Dashboard 数据流

| 区块 | 端点 | 频率 | 备注 |
| --- | --- | --- | --- |
| Service Status | `/api/mihomo/service/status` | 2s | 解析 `rc.d/mihomo status` + `ps -o etimes=` 算 uptime；提取 mihomo child PID（非 daemon wrapper） |
| Active Profile | `/api/mihomo/profiles/active` | onload / 切换后 | 读 `profiles/<active>.meta.json` |
| Realtime Metrics | `/api/mihomo/dashboard/traffic` | 2s | **后端差分**速率（`/tmp/mihomo-traffic-state.json` 暂存）；避免浏览器休眠失真 |
| Recent Log Tail | `/api/mihomo/dashboard/logs?lines=30` | 5s | `tail -n` |
| Health Check | POST `/dashboard/healthCheck` → poll `/dashboard/healthProgress?uuid=` | 2s | 异步队列，进度文件 `/tmp/mihomo-health-<uuid>.json`，90s 无更新视为失败 |

**轮询异常处理**：指数退避（1s→2s→4s→max 10s）+ "Reconnecting..." 横幅；`visibilitychange` 事件暂停/恢复轮询。

## 国际化

gettext 标准（对齐 OPNsense helloworld 示例）：

- Volt 模板：`{{ lang._('...') }}`
- PHP 控制器：`gettext('...')`
- Forms XML / Menu.xml / ACL.xml：框架自动调用 gettext

翻译文件：`lang/zh_CN/LC_MESSAGES/mihomo.po` → 编译为 `mihomo.mo`，install.sh 部署到 `/usr/local/share/locale/zh_CN/LC_MESSAGES/`。

## 修改指引

- **新增 Settings 字段**：改 `mvc/app/models/OPNsense/Mihomo/Mihomo.xml`（添加字段）+ 对应 Forms XML（添加 `<field>`）+ `reconfigure.py` 的 `render_base_from_xml`（XML 标签 → YAML key 映射）
- **新增菜单项**：改 `mvc/app/models/OPNsense/Mihomo/Menu/Menu.xml`
- **新增 API 端点**：在 `Api/<Existing>Controller.php` 加 `<name>Action()` 方法即可（OPNsense 路由自动派生）
- **新增 configd action**：改 `service/conf/actions.d/actions_mihomo.conf` + 对应脚本；长任务用 `daemon -f` 包裹；用户输入参数必须有正则验证
- **新增 Configuration Tab**：改 `views/OPNsense/Mihomo/configuration.volt` 的 nav-tabs + tab-content，配套加 API 控制器
- **修改默认配置模板**：改 `conf/` 下的 base.yaml/override.yaml 等
- **修改部署逻辑**：改 `install.sh`，注意 awk 对 `/conf/config.xml` 的 tun 接口/防火墙规则/Unbound 端口操作

## 技术约束

- **OPNsense MVC 模式**：UI 用 Volt + `layout_partials/` 官方 partial（`base_form` / `base_dialog` / `base_apply_button`）
- **API 端点规范**：`/api/mihomo/<resource>/<action>`，标准 CRUD `searchItem|getItem|setItem|addItem|delItem|toggleItem`，业务动作直接命名
- **特权操作经 configd**：所有写 mihomo 配置/启停服务 → `MihomoFileTrait::configdRun()`，禁止 PHP 直接 `exec` 启动特权命令
- **JS 仅 vanilla + jQuery**：不引入框架或图表库
- **不引入 WebSocket**：PHP 短轮询代理 Mihomo API
- **不引入第三方 PHP YAML 库**：YAML 操作全部在 Python 端（py-yaml）
- **仅 x86_64 + OPNsense 26.1.6 测试通过**
- **长时操作必须后台化**：用 `daemon -f` 包裹，PHP 立即返回，前端轮询进度文件

## 设计/实施文档

- 设计：[docs/superpowers/specs/2026-05-26-mihomo-ui-redesign-design.md](docs/superpowers/specs/2026-05-26-mihomo-ui-redesign-design.md)
- 实施计划：[docs/superpowers/specs/2026-05-26-mihomo-ui-redesign-plan.md](docs/superpowers/specs/2026-05-26-mihomo-ui-redesign-plan.md)

实施状态（2026-05-27）：P0（骨架）/ P1（Dashboard）/ P2（Configuration 8 Tab）/ P3（Subscriptions + Update 脚本）/ P5（i18n + 收尾）全部完成。所有改动在 OPNsense VM 上的端到端验证尚未进行。
