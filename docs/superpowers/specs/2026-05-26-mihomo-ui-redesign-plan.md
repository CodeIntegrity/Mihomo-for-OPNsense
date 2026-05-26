# Mihomo for OPNsense — UI 重设计实施计划

**日期**：2026-05-26
**状态**：待确认
**基于**：[设计文档](docs/superpowers/specs/2026-05-26-mihomo-ui-redesign-design.md)

---

## 阶段总览

| 阶段 | 名称 | 预估文件数 | 依赖 |
|------|------|-----------|------|
| P0 | 基础设施 — 公共库 + 菜单 + 安装/迁移脚本 | 5 | 无 |
| P1 | Dashboard 页 + 3 个新 status 端点 | 5 | P0 |
| P2 | Configuration 页 (6 Tab 单页) | 2 | P0 |
| P3 | Subscriptions 页 + sub.sh 重写 + cron | 4 | P0, P2 (Profiles Tab) |
| P4 | Backup 页 | 1 | P0 |
| P5 | 国际化 + 旧 URL 兼容 + 收尾 | 4 | P0-P4 |

---

## P0：基础设施

### P0.1 — `www/includes/mihomo_lib.inc.php` 公共库

所有新 PHP 页面的唯一 `require_once` 入口。按区块划分注释：

```
// === CONFIG PATHS ===
define('MIHOMO_DIR', '/usr/local/etc/mihomo');
define('MIHOMO_BASE_YAML', MIHOMO_DIR . '/base.yaml');
define('MIHOMO_OVERRIDE_YAML', MIHOMO_DIR . '/override.yaml');
define('MIHOMO_CONFIG_YAML', MIHOMO_DIR . '/config.yaml');
define('MIHOMO_SUBS_JSON', MIHOMO_DIR . '/subs.json');
define('MIHOMO_ACTIVE_JSON', MIHOMO_DIR . '/active.json');
define('MIHOMO_PROFILES_DIR', MIHOMO_DIR . '/profiles');
define('MIHOMO_BACKUPS_DIR', MIHOMO_DIR . '/backups');
define('MIHOMO_LOG', '/var/log/mihomo.log');
define('MIHOMO_SUB_LOG', '/var/log/mihomo_sub.log');

// === FILE LOCKING ===
// lockedWrite($file, $content, $timeout = 5): bool
// - fopen + flock(LOCK_EX) + fwrite + fclose
// - 超时抛异常，调用方 catch 后向用户返回友好提示

// === ATOMIC CONFIG UPDATE ===
// atomicConfigUpdate($newContent): array [success, message]
// - 写 /tmp/config.yaml.new → mihomo -t -f 校验 → mv 覆盖 config.yaml → reloadMihomo()
// - 任一步失败保留旧 config.yaml 不变
// - 规则：所有修改 config.yaml 的路径（Settings Save / Override Save / Profile Activate / 订阅刷新合并）必须走此函数

// === SERVICE CONTROL ===
// reloadMihomo(): array [success, message]
// - 默认 PUT /configs?force=true（热重载）
// - 失败 fallback 到 configctl mihomo restart
// - reload 后 sleep 1.5s 再验证状态（防误判）

// restartMihomo(): array [success, message]
// - configctl mihomo restart
// - 轮询状态最多 10s

// getMihomoStatus(): array [status, pid, uptime]
// - 解析 rc.d status 输出

// === API ===
// mihomoApiCall($path, $method = 'GET', $body = null): array [success, data/error]
// - 从 base.yaml 读取 external-controller + secret
// - stream_socket_client / file_get_contents 发送 HTTP 请求
// - 短连接（读 1-2 frame 即关闭）

// secretFromBase(): string
// - 从 base.yaml 读取 secret 值

// === CONFIG MERGE ===
// mergeAll($base, $override, $profile): array
// - 三层合并：base ⊕ override约定key(位置插入) ⊕ profile(proxies/proxy-groups/rules) ⊕ override其余key(深度合并)
// - 手写实现，不用第三方 YAML 库
// - 约定 key 处理：prepend-rules / append-rules / append-proxies / prepend-proxy-groups / append-proxy-groups

// === PROFILE MANAGEMENT ===
// readProfiles(): array — 扫描 profiles/*.yaml + *.meta.json
// activateProfile($name): array [success, message] — 写 active.json → mergeAll() → atomicConfigUpdate()
// readActiveProfile(): array|null — 读 active.json

// === SUBSCRIPTION MANAGEMENT ===
// readSubs(): array — 读 subs.json
// writeSubs($data): bool — lockedWrite subs.json
// getSubById($id): array|null

// === YAML HELPERS ===
// yamlParse($str): array — 手写简易解析（覆盖本场景需要的结构即可）
// yamlDump($arr): string — 手写简易 dump
// 注意：仅需支持本项目的 YAML 子集，不引入第三方库

// === BACKUP HELPERS ===
// createBackup($label = 'auto'): string|false — tar.gz 打包到 backups/
// listBackups(): array
// restoreBackup($filename): array [success, message]

// === MIGRATION CHECK ===
// isMigrated(): bool — 检查 .migrated-v2 标志文件
// getMigrationError(): string|null — 读取迁移失败的错误信息
```

**关键实现注意事项**：
- `yamlParse()`/`yamlDump()` 仅需处理 Mihomo 配置场景的 YAML 子集（嵌套映射、列表、字符串、数字、布尔），不要求完整 YAML 1.2 兼容。锚点/别名（`&`/`*`）在 parse 阶段展开为值副本，dump 时不再保留引用关系（风险项 8 已记录）。
- `mergeAll()` 的深度合并仅用于 override 中非约定 key 的顶层 key，不需要递归到任意深度。
- `mihomoApiCall()` 使用 `stream_socket_client` 短连接，避免长连接占用。

### P0.2 — `menu/Magic/Menu/Menu.xml` 菜单更新

将现有 2 项菜单更新为新 4 项结构：

```xml
<menu>
    <VPN>
        <Magic VisibleName="Mihomo" cssClass="fa fa-lock fa-fw">
            <mihomoDashboard VisibleName="Dashboard" order="10" url="/mihomo_dashboard.php"/>
            <mihomoConfiguration VisibleName="Configuration" order="20" url="/mihomo_configuration.php"/>
            <mihomoBackup VisibleName="Backup" order="30" url="/mihomo_backup.php"/>
            <mihomoSubscriptions VisibleName="Subscriptions" order="40" url="/mihomo_subscriptions.php"/>
        </Magic>
    </VPN>
</menu>
```

### P0.3 — `actions/actions_mihomo.conf` 扩展

保留现有 `[start]`/`[stop]`/`[restart]`/`[status]`，修改 `[sub-update]` command，新增资源更新 actions：

```ini
[sub-update]
command:/usr/local/etc/mihomo/sub/sub_cron.sh
parameters:
type:script_output
description:Mihomo subscription auto-update

[mihomo-update-geoip]
command:/usr/local/etc/mihomo/sub/update_geoip.sh
parameters:
type:script_output
description:Mihomo GeoIP database update

[mihomo-update-ui]
command:/usr/local/etc/mihomo/sub/update_ui.sh
parameters:
type:script_output
description:Mihomo Dashboard UI update

[mihomo-update-core]
command:/usr/local/etc/mihomo/sub/update_core.sh
parameters:
type:script_output
description:Mihomo core update
```

### P0.4 — `install.sh` 升级

在现有部署逻辑后增加：

1. **迁移检测**：检查 `/usr/local/etc/mihomo/base.yaml` 是否存在
   - 不存在 → 运行 `migrate.sh`
   - 存在 → 跳过迁移
2. **新目录创建**：`mkdir -p /usr/local/etc/mihomo/profiles /usr/local/etc/mihomo/backups`
3. **新文件部署**：复制 `www/mihomo_*.php`、`www/includes/`、新增的 `sub/` 脚本
4. **权限设置**：`chown -R root:www /usr/local/etc/mihomo/` + `chmod 750/640` 按设计文档 1.7.1
5. **菜单缓存清理**：删除 `/var/lib/php/tmp/opnsense_menu_cache.xml`
6. **迁移失败处理**：检测 `.migrated-v2` 标志，如迁移失败则拒绝注册新菜单/新 PHP 页面，保留旧文件不动
7. **语言文件部署**：复制 `lang/zh_CN/LC_MESSAGES/mihomo.mo` 到 OPNsense locale 路径

### P0.5 — `migrate.sh` 迁移脚本

按设计文档 Section 6.2 实现：

1. 幂等检查：`.migrated-v2` 存在则跳过
2. 停止 mihomo：`configctl mihomo stop`
3. 备份：`tar -czf backups/pre-upgrade-<ts>.tar.gz .`
4. 解析现有 `config.yaml`：
   - 提取 general/tun/dns/sniffer/external-controller 顶层 key → `base.yaml`
   - 提取 proxies/proxy-groups/rules → `profiles/legacy.yaml`
   - 写 `profiles/legacy.meta.json`（`source_type=manual`）
   - 写 `active.json: {"profile": "legacy"}`
   - 创建空 `override.yaml`
5. 迁移旧订阅：如果 `sub/env` 存在合法 URL → `subs.json` 新增条目
6. 校验：`mergeAll()` + `mihomo -t -f` 验证合成结果
7. 通过：写 `.migrated-v2` 标志 → 启动 mihomo
8. 失败：保留旧文件不动，写错误信息到 `/tmp/mihomo-migrate-error.txt`，退出非零

---

## P1：Dashboard 页

### P1.1 — `www/mihomo_dashboard.php`

按设计文档 Section 2 实现。布局：
- **Service Status 区块**：状态灯 + uptime + PID + Start/Stop/Restart 按钮 + "Open Dashboard UI" 链接
- **Active Profile 区块**：当前 profile 名 + 节点数 + 最后更新时间 + Switch/Refresh/Health Check 按钮
- **Realtime Metrics 区块**：4 个指标卡片（↑/↓ 速率、连接数、内存），2s 轮询
- **Recent Log Tail 区块**：最近 30 行日志 textarea，5s 轮询

数据来源：
- 状态 → `status_mihomo.php`（扩展 pid + uptime）| 2s
- Profile → 页面加载时读 `active.json` + `meta.json` | onload + 切换后
- 指标 → `status_mihomo_traffic.php`（新增）| 2s
- 日志 → `status_mihomo_logs.php?lines=30` | 5s

交互实现：
- Switch Profile：下拉列表 → POST activate → `activateProfile()` → reload → 刷新
- Refresh Subscription：`execBackgroundCommand("bash sub.sh <sub_id>")` → 按钮 spinner + 轮询 `last_status`
- Health Check：POST `action=health_check&mode=quick` → 轮询 `status_mihomo_health.php?uuid=<uuid>` → 结果显示
- 错误处理：指数退避（1s→2s→4s→max 10s）、`visibilitychange` 暂停/恢复轮询
- Open Dashboard UI：动态读取 external-controller 地址，localhost 时显示提示

### P1.2 — `www/status_mihomo.php` 扩展

在现有 JSON 返回中增加 `pid` 和 `uptime` 字段：

```php
// 解析 rc.d status 输出获取 pid
// uptime: ps -o etime= -p <pid> 或 /proc/<pid>/stat 计算
echo json_encode([
    'status' => 'running'|'stopped',
    'pid' => 12345,
    'uptime' => '2d 14h'
]);
```

### P1.3 — `www/status_mihomo_traffic.php`（新增）

后端差分速率计算：

```
1. 通过 mihomoApiCall('/traffic') 获取累计上下行字节
2. 通过 mihomoApiCall('/memory') 获取内存使用
3. 通过 mihomoApiCall('/connections') 获取连接数 + 累计连接
4. 读 /tmp/mihomo-traffic-state.json 获取上次累计值 + 时间戳
5. 计算 (current - last) / (now - last_ts) 得出速率
6. 更新 /tmp/mihomo-traffic-state.json
7. 返回 JSON: {upRate, downRate, upTotal, downTotal, memory, connections, connectionTotal}
```

### P1.4 — `www/status_mihomo_health.php`（新增）

异步 Health Check 进度轮询：

```
输入：?uuid=<uuid>
输出：{state: "running"|"done"|"failed", progress: {done, total}, result: {alive, dead, dead_list}}
```

读取 `/tmp/mihomo-health-<uuid>.json` 返回当前进度。

### P1.5 — `sub/mihomo_health_check.sh`（新增）

Health Check 后台脚本：

```bash
# mihomo_health_check.sh <uuid> <profile_name> <mode>
# 1. 读 profiles/<profile_name>.yaml 获取 proxy-groups 中的 url-test 组
# 2. 从 proxies 列表提取节点名（quick 模式仅测 url-test 组内节点，上限 10 个）
# 3. 批量 5 并发通过 mihomo API /proxies/<name>/delay 测延迟
# 4. 更新 /tmp/mihomo-health-<uuid>.json 进度
# 5. 完成标记 state=done
```

---

## P2：Configuration 页

### P2.1 — `www/mihomo_configuration.php`

按设计文档 Section 3 实现。6 个 Tab 单页（URL hash 路由）：

**Tab 1 — Settings（base.yaml 表单）**：
- Group A-F 表单字段（~40 个），按设计文档 3.2 表格逐字段实现
- `interface-name` 下拉：用 `ifconfig -l` 获取物理接口列表
- DNS listen 53 端口冲突检测：保存前 `sockstat -4l | grep :53`，若被 Unbound 占用弹警告
- 保存逻辑：读取现有 `base.yaml` → 覆盖表单管辖 key → 保留未管辖字段 → `mergeAll()` 合成 → `atomicConfigUpdate()`
- "Generate" 按钮为 secret 生成随机密钥

**Tab 2 — Override（override.yaml 编辑器）**：
- 说明文字 + 示例折叠区域（`<details>` 标签）
- YAML textarea 编辑 `override.yaml`
- [Save Override] [Validate Only] [Reset] 三个按钮
- Validate Only：走 `atomicConfigUpdate()` 的校验部分但不提交
- Save：完整 `atomicConfigUpdate()`

**Tab 3 — Profiles（列表管理）**：
- 表格：Name / Source / Nodes / Last Updated / Status
- 操作按钮：Activate / Refresh（仅 subscription）/ View YAML（modal）/ Edit / Delete
- Edit 对 subscription profile 弹警告："编辑将导致此 Profile 与订阅源解绑（source_type 变为 manual）"
- Delete：当前 active 禁止删除
- Create Empty：手动新建 `source_type=manual` 的空 profile

**Tab 4 — YAML（只读视图）**：
- 当前 `config.yaml` 内容只读 textarea
- [Copy to Clipboard] [Download] 按钮
- 引导文字指向 Settings/Override/Profiles

**Tab 5 — Log（日志查看）**：
- [Pause Auto-refresh] [Clear Log] [Download Full Log]
- Level filter（前端 grep）、Lines 数量选择
- 复用 `status_mihomo_logs.php?level=&lines=`

**Tab 6 — Updates（资源更新）**：
- 三块：Mihomo Core / GeoIP Database / Dashboard UI
- 每块：Current/Latest 版本 + [Check] [Update] 按钮
- [Check]：拉 GitHub API（1h 缓存 `/tmp/mihomo-latest-release.json` + 可选 Token）
- [Update]：UI 锁定状态 → 后台执行 → 轮询 `status_mihomo_update.php?resource=<core|geoip|ui>` → 完成/失败解除锁定
- UI 变体选择：zashboard / metacubexd / yacd

**Tab 间状态同步**：Save 后 dispatch `CustomEvent('mihomo:configChanged')`，YAML Tab 监听刷新。

### P2.2 — `www/status_mihomo_update.php`（新增）

资源更新进度轮询：

```
输入：?resource=<core|geoip|ui>
输出：{state: "checking"|"downloading"|"verifying"|"installing"|"done"|"failed", progress: 0-100, message: "..."}
```

读取 `/tmp/mihomo-update-<resource>.json` 状态文件。

---

## P3：Subscriptions 页

### P3.1 — `www/mihomo_subscriptions.php`

按设计文档 Section 5 实现：
- 表格列：Enabled / Name / URL / Filter / Update Interval / Last Update / Last Status
- 每行操作：[Refresh Now] [Edit] [Delete]
- [+ Add Subscription] 按钮 → 表单（Name/URL/UA/Enabled/Interval/Include/Exclude）
- 底部：Subscription Log textarea（复用 `status_sub_logs.php?lines=200`）

### P3.2 — `sub/sub.sh` 重写

按设计文档 5.4 参数化重写：

```bash
# sub.sh <sub_id>
# 1. lockedWrite 更新 subs.json 中 last_status = "updating"
# 2. 从 subs.json 解出 url/UA/filter
# 3. curl 下载到 /tmp/sub-<sub_id>.raw
# 4. 提取 proxies/proxy-groups/rules
# 5. 应用 include/exclude 关键词过滤（仅过滤 proxies 节点名）
# 6. 写入 /tmp/sub-<sub_id>.yaml，mihomo -t 校验
# 7. 校验通过 → mv 覆盖 profiles/sub-<name>.yaml
# 8. 更新 profiles/sub-<name>.meta.json（node_count + last_update）
# 9. 更新 subs.json last_update + last_status = "done"/"failed"
# 10. 如果 active → atomicConfigUpdate() + reloadMihomo()
# 11. stdout/stderr >> /var/log/mihomo_sub.log（每行 [sub_id=<id>] 前缀）
```

### P3.3 — `sub/sub_cron.sh`（新增）

Cron 入口脚本：

```bash
# 1. sleep $((RANDOM % 30)) 随机延迟
# 2. flock -n /tmp/mihomo-sub-cron.lock 防并发
# 3. 读取 subs.json
# 4. 遍历每条记录：如果 enabled && last_update + update_interval_hours <= now → sub.sh <sub_id>
```

### P3.4 — `sub/update_core.sh`（新增）

按设计文档 1.5.2 实现内核更新流程：
1. 读 `/tmp/mihomo-latest-release.json`（1h 缓存）
2. 下载 freebsd-amd64.gz + .sha256
3. SHA256 校验 → gunzip → smoke test（`mihomo -v`）
4. 备份 → 原子 mv → restart → 轮询 10s
5. 未恢复则自动回滚

进度写入 `/tmp/mihomo-update-core.json`。

### P3.5 — `sub/update_geoip.sh` + `sub/update_ui.sh`（新增）

- `update_geoip.sh`：拉取 Country.mmdb → 备份 → 替换 → `PUT /configs/geo` 热重载（不支持则 reload）
- `update_ui.sh`：拉取 zip → 解压到 `/tmp/mihomo-ui-new` → `mv ui ui.bak.<ts> && mv /tmp/mihomo-ui-new ui`

---

## P4：Backup 页

### P4.1 — `www/mihomo_backup.php`

按设计文档 Section 4 实现：

**Export**：
- 警告文字 + 加密选项（AES-256-CBC password）
- `tar -czf /tmp/mihomo-backup-<hostname>-<ts>.tar.gz base.yaml override.yaml subs.json active.json profiles/`
- 可选 `openssl enc -aes-256-cbc -pbkdf2` 加密
- `readfile()` 输出 → 删除 tmp

**Import**：
- 加密文件输密码解密
- Overwrite/Merge 策略选择
- Merge：`subs.json` 按 id 合并；`profiles/*.yaml` 同名覆盖、独有保留；`base.yaml`/`override.yaml` 整文件覆盖
- 导入前自动 export 一份 fallback backup
- `mihomo -t` 校验通过才提交

**Recent Local Backups**：
- 扫描 `backups/` 目录，表格显示：Date / Size / Actions (Download/Restore/Delete)
- Auto-backup 开关：Overide save 前 / Profile activation 前

---

## P5：国际化 + 兼容 + 收尾

### P5.1 — `lang/zh_CN/LC_MESSAGES/mihomo.po` + 编译 `.mo`

- 从所有新 PHP 文件中提取 `gettext("...")` 字符串
- 编写中文 `.po` 文件
- 编译为 `.mo`（`msgfmt`）
- 同时生成 `.pot` 模板

### P5.2 — 旧 URL 兼容

- `/services_mihomo.php` → 302 跳转 `mihomo_dashboard.php`
- `/sub.php` → 302 跳转 `mihomo_subscriptions.php`
- 旧文件保留但改为跳转脚本（不删除，防止书签失效）

### P5.3 — `www/status_mihomo_logs.php` 增强

增加查询参数支持：
- `?lines=100` — 返回最近 N 行
- `?level=error` — 前端不可用时后端 grep 过滤（可选，默认前端过滤）
- 日志路径不变（`/var/log/mihomo.log`）

### P5.4 — `plugins/mihomo.inc` 保持

现有插件逻辑基本不变，仅确认 `mihomo_services()` 注册的 pidfile 路径正确。

### P5.5 — `docs/` 目录整理

- 将设计文档保留在 `docs/superpowers/specs/`
- 将本实施计划放入同目录

---

## 实施顺序与依赖图

```
P0.1 (mihomo_lib.inc.php)
 ├── P0.2 (Menu XML)
 ├── P0.3 (actions conf 扩展)
 ├── P0.4 (install.sh 升级) ← 依赖 P0.5
 ├── P0.5 (migrate.sh)
 │
 ├── P1.1 (Dashboard) ← 依赖 P1.2, P1.3, P1.4
 │   ├── P1.2 (status_mihomo.php 扩展)
 │   ├── P1.3 (status_mihomo_traffic.php)
 │   ├── P1.4 (status_mihomo_health.php)
 │   └── P1.5 (mihomo_health_check.sh)
 │
 ├── P2.1 (Configuration 6-Tab) ← 依赖 P2.2
 │   └── P2.2 (status_mihomo_update.php)
 │
 ├── P3.1 (Subscriptions 页) ← 依赖 P3.2
 │   ├── P3.2 (sub.sh 重写)
 │   ├── P3.3 (sub_cron.sh)
 │   ├── P3.4 (update_core.sh)
 │   └── P3.5 (update_geoip.sh + update_ui.sh)
 │
 ├── P4.1 (Backup 页)
 │
 └── P5.1-P5.5 (收尾)
```

**建议执行顺序**：P0 → P1 → P2 → P3 → P4 → P5。P1-P4 可部分并行（不同人负责不同页面时），但单人开发建议串行以复用 Patterns。

---

## 关键技术风险与缓解

| # | 风险 | 影响 | 缓解 |
|---|------|------|------|
| R1 | YAML 解析丢失注释/锚点 | override.yaml 和 profile 中锚点跨文件引用失效 | parse 阶段展开锚点为值副本；前端提示限制 |
| R2 | `PUT /configs?force=true` 在 TUN/DNS 变更时不稳定 | reload 失败触发不必要的 restart | reload 后 delay 1.5s 再验证状态 |
| R3 | `PUT /configs/geo` 可能在当前 mihomo 版本不可用 | GeoIP 热重载失败 | 实施前实测，不支持则 fallback 到 reload |
| R4 | GitHub API 限流（60 req/h 未认证） | 更新检查频繁触发限流 | 1h 缓存 + 可选 Token |
| R5 | 手写 YAML 合并随 Mihomo 字段增加膨胀 | 维护成本 | 单文件内按区块划分，预留拆分空间 |
| R6 | 迁移失败导致用户进入半残界面 | 用户体验差 | 失败时拒绝注册新菜单，保留旧文件不动 |
| R7 | Cron 与 Web UI 并发写入截断 config.yaml | 配置损坏 | `lockedWrite()` + `flock()` 全局保护 |
| R8 | install.sh 中 awk 修改 config.xml 的逻辑与新结构冲突 | 安装失败 | 迁移检测放在 awk 修改之前，先迁移再处理 config.xml |

---

## 文件清单

### 新建文件（20 个）

```
www/
├── mihomo_dashboard.php           # P1.1
├── mihomo_configuration.php       # P2.1
├── mihomo_backup.php              # P4.1
├── mihomo_subscriptions.php       # P3.1
├── status_mihomo_traffic.php      # P1.3
├── status_mihomo_health.php       # P1.4
├── status_mihomo_update.php       # P2.2
└── includes/
    └── mihomo_lib.inc.php         # P0.1

conf/sub/
├── sub.sh                         # P3.2 (重写)
├── sub_cron.sh                    # P3.3
├── mihomo_health_check.sh         # P1.5
├── update_core.sh                 # P3.4
├── update_geoip.sh                # P3.5
└── update_ui.sh                   # P3.5

lang/zh_CN/LC_MESSAGES/
├── mihomo.po                      # P5.1
└── mihomo.mo                      # P5.1 (编译产物)

migrate.sh                         # P0.5 (项目根目录)
```

### 修改文件（7 个）

```
menu/Magic/Menu/Menu.xml           # P0.2
actions/actions_mihomo.conf        # P0.3
install.sh                         # P0.4
www/status_mihomo.php              # P1.2
www/status_mihomo_logs.php         # P5.3
www/services_mihomo.php            # P5.2 (改为302跳转)
www/sub.php                        # P5.2 (改为302跳转)
```

### 不修改文件

```
rc.d/mihomo                        # 保持不变
plugins/mihomo.inc                 # 基本不变 (P5.4)
rc.conf/mihomo                     # 保持不变
conf/config.yaml                   # 保留作为默认模板参考
bin/mihomo                         # 保持不变
```

---

## 验证检查点

每阶段完成后验证：
1. **P0**：`install.sh` 干净安装 → Dashboard 页面可访问 → 公共库函数单元测试通过
2. **P1**：Dashboard 状态轮询正常 → 指标卡片数据正确 → 错误处理/退避生效
3. **P2**：Settings 表单保存 → mergeAll 合成正确 → config.yaml 校验通过 → Profiles 切换生效
4. **P3**：订阅添加/抓取/过滤 → profile 生成 → 激活生效 → cron 定时触发
5. **P4**：导出 tar.gz → 导入恢复 → 加密/解密正常
6. **P5**：gettext 翻译生效 → 旧 URL 跳转正常 → 迁移脚本幂等
