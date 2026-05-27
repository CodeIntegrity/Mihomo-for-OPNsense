# Mihomo for OPNsense — UI 重设计实施计划

**日期**：2026-05-26
**状态**：待确认
**基于**：[设计文档](docs/superpowers/specs/2026-05-26-mihomo-ui-redesign-design.md)

---

## 阶段总览

| 阶段 | 名称 | 预估文件数 | 依赖 |
|------|------|-----------|------|
| P0 | MVC 骨架 — 模型 XML + ACL + Menu + 共享 Trait + Forms XML + 安装/迁移 | 12 | 无 |
| P1 | Dashboard — Controller + Volt + Api/Dashboard 自定义端点 | 5 | P0 |
| P2 | Configuration — 8 Tab Volt + 各 Api 控制器（Settings/Override/Profiles/YAML/Log/Updates/Backup） | 10 | P0 |
| P3 | Subscriptions Tab 配套：ApiMutableModelControllerBase + sub.sh 重写 + cron + 抓取脚本 | 6 | P0, P2 |
| P4 | Backup Tab 配套：自定义控制器 + tar/openssl 助手 | 1 | P0, P2 |
| P5 | i18n + 旧 URL 兼容 + 收尾 | 4 | P0-P4 |

> 全部代码迁入 OPNsense MVC 路径（`src/opnsense/mvc/app/...`），旧 `www/*.php` 仅保留 302 跳转占位。详见设计文档 Section 1.8。

---

## P0：基础设施（MVC 骨架）

> **重要**：本计划全面采用 OPNsense MVC 模式（参考 helloworld + using_grids 官方示例）。旧 `www/includes/mihomo_lib.inc.php` 概念分解为：① OPNsense 模型 XML 自动处理 Settings/Subscriptions 字段；② 共享 PHP Trait 提供文件操作与 YAML 合并；③ `configctl mihomo reconfigure` 收口所有写后 reload 动作。

### P0.1 — 模型与 ACL（OPNsense config.xml 映射）

**`src/opnsense/mvc/app/models/OPNsense/Mihomo/Mihomo.php`**

```php
<?php
namespace OPNsense\Mihomo;
use OPNsense\Base\BaseModel;
class Mihomo extends BaseModel {}
```

**`src/opnsense/mvc/app/models/OPNsense/Mihomo/Mihomo.xml`**

模型节点（仅列出顶层结构，字段类型映射见设计文档 3.2 表）：

```xml
<model>
    <mount>//OPNsense/Mihomo</mount>
    <description>Mihomo proxy integration for OPNsense</description>
    <items>
        <general>      <!-- Group A: General — port/socks-port/mode/log-level/... -->
        </general>
        <controller>   <!-- Group B: External Controller — external-controller/secret/external-ui -->
        </controller>
        <tun>          <!-- Group C: TUN — enable/stack/device/mtu/auto-route/strict-route/dns-hijack -->
        </tun>
        <dns>          <!-- Group D: DNS — enable/listen/enhanced-mode/fake-ip-range/nameserver/fallback/... -->
        </dns>
        <sniffer>      <!-- Group E: Sniffer — enable/force-dns-mapping/parse-pure-ip/sniff -->
        </sniffer>
        <update>       <!-- Group F: Auto Update — github_mirror/github_token/auto_update/health_check_url/timeout -->
        </update>
        <subscriptions>
            <subscription type="ArrayField">
                <enabled type="BooleanField"><default>1</default></enabled>
                <name type="HostnameField"><Required>Y</Required></name>
                <url type="UrlField"><Required>Y</Required></url>
                <user_agent type="TextField"><default>clash-verge/v1.7.0</default></user_agent>
                <interval type="IntegerField"><default>6</default></interval>
                <include_keyword type="TextField"/>
                <exclude_keyword type="TextField"><default>剩余,流量,过期,官网,套餐</default></exclude_keyword>
                <last_update type="TextField"/>
                <last_status type="OptionField">
                    <OptionValues>
                        <idle>Idle</idle><updating>Updating</updating>
                        <done>Done</done><failed>Failed</failed>
                    </OptionValues>
                </last_status>
            </subscription>
        </subscriptions>
    </items>
</model>
```

**`src/opnsense/mvc/app/models/OPNsense/Mihomo/ACL/ACL.xml`**

```xml
<acl>
    <page-mihomo-dashboard>
        <name>Mihomo: Dashboard</name>
        <patterns>
            <pattern>ui/mihomo/dashboard*</pattern>
            <pattern>api/mihomo/service/*</pattern>
            <pattern>api/mihomo/dashboard/*</pattern>
        </patterns>
    </page-mihomo-dashboard>
    <page-mihomo-configuration>
        <name>Mihomo: Configuration</name>
        <patterns>
            <pattern>ui/mihomo/configuration*</pattern>
            <pattern>api/mihomo/settings/*</pattern>
            <pattern>api/mihomo/subscriptions/*</pattern>
            <pattern>api/mihomo/override/*</pattern>
            <pattern>api/mihomo/profiles/*</pattern>
            <pattern>api/mihomo/backup/*</pattern>
            <pattern>api/mihomo/update/*</pattern>
        </patterns>
    </page-mihomo-configuration>
</acl>
```

### P0.2 — Menu XML（OPNsense MVC 路径）

**`src/opnsense/mvc/app/models/OPNsense/Mihomo/Menu/Menu.xml`**

```xml
<menu>
    <VPN>
        <Mihomo VisibleName="Mihomo" cssClass="fa fa-shield fa-fw">
            <Dashboard VisibleName="Dashboard" order="10" url="/ui/mihomo/dashboard"/>
            <Configuration VisibleName="Configuration" order="20" url="/ui/mihomo/configuration"/>
        </Mihomo>
    </VPN>
</menu>
```

> 旧版 `menu/Magic/Menu/Menu.xml` 路径废弃。部署后需删除 `/tmp/opnsense_menu_cache.xml` 以刷新菜单。

### P0.3 — Forms XML（Settings Tab 字段定义）

**`src/opnsense/mvc/app/controllers/OPNsense/Mihomo/forms/general.xml`**（示例）

```xml
<form>
    <field>
        <id>general.port</id>
        <label>HTTP Port</label>
        <type>text</type>
        <help>HTTP proxy port (default 7890).</help>
    </field>
    <field>
        <id>general.mode</id>
        <label>Mode</label>
        <type>dropdown</type>
        <help>Proxy routing mode.</help>
    </field>
    <!-- ... 其他 Group A 字段 -->
</form>
```

为 Group A-F 各创建一个 Forms XML：`general.xml` / `controller.xml` / `tun.xml` / `dns.xml` / `sniffer.xml` / `update.xml`。Subscriptions 编辑对话框：`dialogSubscription.xml`（含 `grid_view` 标签自动派生表格列）。

### P0.4 — 共享 Trait / Helper（YAML + 文件操作）

**`src/opnsense/mvc/app/controllers/OPNsense/Mihomo/Api/MihomoFileTrait.php`**

提供给所有自定义控制器使用：

```php
// lockedWrite($file, $content): bool         — flock + fwrite
// atomicConfigUpdate($newYaml): array         — tmp + mihomo -t + mv + reload
// renderBaseYaml(): string                    — 读 config.xml 模型字段 → 输出 base.yaml 文本
// mergeAll($base, $override, $profile): array — 三层合并（手写）
// yamlParse($str): array / yamlDump($arr): string
// readProfiles(): array / activateProfile($name): array
// createBackup($label): string|false / listBackups(): array / restoreBackup($file): array
// mihomoApiCall($path, $method, $body): array
```

### P0.5 — configd actions

**`src/opnsense/service/conf/actions.d/actions_mihomo.conf`**

```ini
[start]
command:/usr/local/etc/rc.d/mihomo onestart
parameters:
type:script
description:Start mihomo

[stop]
command:/usr/local/etc/rc.d/mihomo onestop
parameters:
type:script
description:Stop mihomo

[restart]
command:/usr/local/etc/rc.d/mihomo onerestart
parameters:
type:script
description:Restart mihomo

[status]
command:/usr/local/etc/rc.d/mihomo status
parameters:
type:script_output
description:Mihomo status

[reconfigure]
command:/usr/local/opnsense/scripts/mihomo/reconfigure.py
parameters:
type:script_output
description:Render base.yaml from config.xml + merge + atomic apply + reload

[sub-update]
command:/usr/local/opnsense/scripts/mihomo/sub_cron.sh
parameters:
type:script_output
description:Subscription auto-update entry (cron)

[sub-refresh]
command:/usr/local/opnsense/scripts/mihomo/sub.sh
parameters:%s
type:script_output
description:Refresh single subscription by id

[update-core]
command:/usr/local/opnsense/scripts/mihomo/update_core.sh
parameters:
type:script_output
description:Update mihomo core binary

[update-geoip]
command:/usr/local/opnsense/scripts/mihomo/update_geoip.sh
parameters:
type:script_output
description:Update GeoIP database

[update-ui]
command:/usr/local/opnsense/scripts/mihomo/update_ui.sh
parameters:%s
type:script_output
description:Update Dashboard UI variant
```

### P0.6 — `install.sh` / Makefile 升级

- 旧 `www/*.php`（除 302 跳转占位）一律删除；新 MVC 文件按 OPNsense 标准插件目录树部署
- 新增 `scripts/mihomo/reconfigure.py`：configd `[reconfigure]` 入口（读 config.xml → 渲染 base.yaml → mergeAll → atomicConfigUpdate）
- 迁移检测仍走 P0.7 `migrate.sh`，不存在 `base.yaml` 时执行
- 部署完成后 `rm -f /tmp/opnsense_menu_cache.xml` 刷新菜单缓存
- 部署 `lang/zh_CN/LC_MESSAGES/mihomo.mo` 到 OPNsense locale 路径

### P0.7 — `migrate.sh` 迁移脚本

按设计文档 Section 6.2 实现（不变）：旧 `config.yaml` → 写 `base.yaml` / `profiles/legacy.yaml` / `active.json` / `override.yaml`，并把现有 base.yaml 字段反向同步到 OPNsense config.xml（首次升级一次性写入，后续以 config.xml 为单一可信源）。

---

## P1：Dashboard 页

> 全量 MVC：`DashboardController` 渲染 Volt，`Api/DashboardController` + `Api/ServiceController` 提供 JSON 端点。

### P1.1 — `mvc/app/controllers/OPNsense/Mihomo/DashboardController.php` + `views/.../dashboard.volt`

按设计文档 Section 2 实现。Volt 布局使用 `<div class="content-box">` 包裹各区块：

- **Service Status 区块**：状态灯 + uptime + PID + Start/Stop/Restart 按钮 + "Open Dashboard UI" 链接
- **Active Profile 区块**：当前 profile 名 + 节点数 + 最后更新时间 + Switch/Refresh/Health Check 按钮
- **Realtime Metrics 区块**：4 个指标卡片（↑/↓ 速率、连接数、内存），2s 轮询
- **Recent Log Tail 区块**：最近 30 行日志 textarea，5s 轮询

数据来源（统一 `/api/mihomo/...`）：

- 状态 → `/api/mihomo/service/status`（含 pid + uptime）| 2s
- Profile → `/api/mihomo/profiles/active` | onload + 切换后
- 指标 → `/api/mihomo/dashboard/traffic` | 2s
- 日志 → `/api/mihomo/dashboard/logs?lines=30` | 5s

交互实现：

- Switch Profile：POST `/api/mihomo/profiles/activate/<name>` → 内部 `configctl mihomo reconfigure` → 刷新
- Refresh Subscription：POST `/api/mihomo/subscriptions/refresh/<uuid>` → 内部 `configctl mihomo sub-refresh <id>` → 按钮 spinner + 轮询 `last_status`
- Health Check：POST `/api/mihomo/dashboard/healthCheck` → 轮询 `/api/mihomo/dashboard/healthProgress?uuid=<uuid>` → 结果显示
- 错误处理：指数退避（1s→2s→4s→max 10s）、`visibilitychange` 暂停/恢复轮询
- Open Dashboard UI：动态读取 external-controller 地址，localhost 时显示提示

### P1.2 — `Api/ServiceController.php`（service/status / start / stop / restart / reconfigure）

```php
public function statusAction()
{
    // configctl mihomo status → 解析 pid + uptime
    return ['status' => 'running'|'stopped', 'pid' => ..., 'uptime' => ...];
}
public function startAction()   { /* POST → configctl mihomo start */ }
public function stopAction()    { /* POST → configctl mihomo stop */ }
public function restartAction() { /* POST → configctl mihomo restart */ }
public function reconfigureAction() { /* POST → configctl mihomo reconfigure；apply 按钮统一入口 */ }
```

### P1.3 — `Api/DashboardController.php::trafficAction()`（新增）

后端差分速率计算（逻辑不变，迁入 MVC）：

```
1. mihomoApiCall('/traffic')           — 累计上下行字节
2. mihomoApiCall('/memory')            — 内存使用
3. mihomoApiCall('/connections')       — 连接数 + 累计
4. 读 /tmp/mihomo-traffic-state.json   — 上次累计值 + 时间戳
5. 计算 (current - last) / (now - last_ts)
6. 更新 /tmp/mihomo-traffic-state.json
7. 返回 JSON: {upRate, downRate, upTotal, downTotal, memory, connections, connectionTotal}
```

### P1.4 — `Api/DashboardController.php::healthProgressAction()`（新增）

异步 Health Check 进度轮询：

```
GET /api/mihomo/dashboard/healthProgress?uuid=<uuid>
返回：{state: "running"|"done"|"failed", progress: {done, total}, result: {alive, dead, dead_list}}
```

读取 `/tmp/mihomo-health-<uuid>.json` 返回当前进度。

### P1.5 — `scripts/mihomo/mihomo_health_check.sh`（新增）

Health Check 后台脚本（逻辑不变，仅迁路径）：

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

> 全量 MVC：`ConfigurationController` 渲染 `configuration.volt`（包含 8 Tab，使用 `base_tabs_header` / `base_tabs_content` partial）。每个 Tab 内部使用对应的 partial：Settings/Subscriptions 走 `base_form` / `base_bootgrid_table`，Override/YAML/Log 走自定义 Volt 块，Updates/Backup 走 `base_form` + 自定义按钮组。

### P2.1 — `views/OPNsense/Mihomo/configuration.volt` + `ConfigurationController`

按设计文档 Section 3 实现。8 个 Tab 单页（OPNsense Volt 框架原生 hash 路由），顺序：Settings → Subscriptions → Profiles → Override → YAML → Log → Updates → Backup。

`ConfigurationController::indexAction()`：

```php
$this->view->formGeneral       = $this->getForm("general");
$this->view->formController    = $this->getForm("controller");
$this->view->formTun           = $this->getForm("tun");
$this->view->formDns           = $this->getForm("dns");
$this->view->formSniffer       = $this->getForm("sniffer");
$this->view->formUpdate        = $this->getForm("update");
$this->view->formGridSub       = $this->getFormGrid("dialogSubscription");
$this->view->formDialogSub     = $this->getForm("dialogSubscription");
$this->view->pick("OPNsense/Mihomo/configuration");
```

Volt 模板骨架：

```volt
{{ partial('layout_partials/base_tabs_header', {'tabs': [
   ['settings',      lang._('Settings')],
   ['subscriptions', lang._('Subscriptions')],
   ['profiles',      lang._('Profiles')],
   ['override',      lang._('Override')],
   ['yaml',          lang._('YAML')],
   ['log',           lang._('Log')],
   ['updates',       lang._('Updates')],
   ['backup',        lang._('Backup')]
]}) }}
{{ partial('layout_partials/base_tabs_content', {'tabs': [...]}) }}
{{ partial('layout_partials/base_apply_button', {'data_endpoint': '/api/mihomo/service/reconfigure'}) }}
```

**Tab 1 — Settings**：6 个 Forms XML（Group A-F）拼接，每组用 `base_form` partial 渲染。保存通过 `/api/mihomo/settings/set`（`ApiMutableModelControllerBase` 自动支持），保存后 apply 按钮触发 `reconfigure`。`interface-name` 下拉数据由控制器注入候选；DNS 53 端口冲突检测在 reconfigure 脚本中进行。

**Tab 2 — Subscriptions**：使用 `base_bootgrid_table` + `base_dialog`，绑定 API：

```js
$("#" + formGridSub['table_id']).UIBootgrid({
    search:  '/api/mihomo/subscriptions/searchItem/',
    get:     '/api/mihomo/subscriptions/getItem/',
    set:     '/api/mihomo/subscriptions/setItem/',
    add:     '/api/mihomo/subscriptions/addItem/',
    del:     '/api/mihomo/subscriptions/delItem/',
    toggle:  '/api/mihomo/subscriptions/toggleItem/'
});
```

每行附加 [Refresh Now] 自定义按钮 → POST `/api/mihomo/subscriptions/refresh/<uuid>`（控制器调用 `configctl mihomo sub-refresh <id>`）。底部 Subscription Log textarea：`/api/mihomo/subscriptions/log?lines=200`。

**Tab 3 — Profiles（自定义控制器 + UIBootgrid）**：表格列 Name / Source / Nodes / Last Updated / Status。操作按钮 Activate / Refresh / View YAML（modal）/ Edit / Delete。Edit 对 subscription profile 弹解绑警告。Delete 当前 active 禁止。Create Empty 手动新建 `source_type=manual`。

**Tab 4 — Override**：YAML textarea + `<details>` 示例。三个按钮：Save Override / Validate Only / Reset → 调用 `/api/mihomo/override/set` / `/validate` / `/reset`。

**Tab 5 — YAML**：只读 textarea 显示 `/api/mihomo/override/composedYaml` 返回内容；[Copy to Clipboard] [Download] 按钮。

**Tab 6 — Log**：textarea 显示 `/api/mihomo/dashboard/logs?level=&lines=`；[Pause Auto-refresh] [Clear Log] [Download Full Log] 按钮。

**Tab 7 — Updates**：三块（Core / GeoIP / UI），每块通过 `base_form` 显示 Current/Latest 版本（控制器注入）+ [Check]/[Update] 按钮。Check → `/api/mihomo/update/check?resource=<r>`（1h 缓存）。Update → POST `/api/mihomo/update/run?resource=<r>` → UI 锁定 → 轮询 `/api/mihomo/update/progress?resource=<r>` → 完成/失败解锁。UI 变体（zashboard/metacubexd/yacd）通过 update.xml Forms 字段选择。

**Tab 8 — Backup**：Export 区块（加密选项 + Download Backup）→ `/api/mihomo/backup/export`。Import 区块（密码 + Overwrite/Merge）→ POST `/api/mihomo/backup/import`。Recent Local Backups 表格 → `/api/mihomo/backup/list` + Download/Restore/Delete 行操作。Auto-backup 开关存入 Settings model 的 `update.auto_backup_*` 字段。

**Tab 间状态同步**：保存后由 OPNsense 框架 apply 按钮统一触发 reconfigure；Volt 监听 `mihomo:configChanged` 事件刷新 YAML Tab；Subscriptions Tab 刷新订阅后派发事件，Profiles Tab 同步刷新列表。

### P2.2 — `Api/OverrideController.php`（自定义）

操作 `override.yaml` 文件：

```php
public function getAction()         { /* 读 override.yaml */ }
public function setAction()         { /* POST override.yaml 内容 → lockedWrite */ }
public function validateAction()    { /* POST → tmp + mergeAll + mihomo -t -f；不提交 */ }
public function resetAction()       { /* 清空 override.yaml */ }
public function composedYamlAction(){ /* 返回当前合成 config.yaml 文本 */ }
```

### P2.3 — `Api/ProfilesController.php`（自定义）

```php
public function searchAction()       { /* 扫描 profiles/*.yaml + .meta.json */ }
public function getAction($uuid)     { /* 读单个 meta.json + yaml */ }
public function activateAction($uuid){ /* 写 active.json → configctl mihomo reconfigure */ }
public function deleteAction($uuid)  { /* 当前 active 禁止；删 yaml + meta.json */ }
public function refreshAction($uuid) { /* 仅 subscription 类型；configctl mihomo sub-refresh <sub_id> */ }
public function createEmptyAction()  { /* 新建空 manual profile */ }
public function viewYamlAction($uuid){ /* 返回 profile yaml 文本 */ }
```

### P2.4 — `Api/UpdateController.php`（自定义）

```php
public function checkAction()      { /* GET ?resource=<r>；1h 缓存 GitHub API */ }
public function runAction()        { /* POST → execBackgroundCommand("configctl mihomo update-<r>") */ }
public function progressAction()   { /* GET ?resource=<r>；读 /tmp/mihomo-update-<r>.json */ }
```

### P2.5 — `Api/BackupController.php`（自定义）

```php
public function exportAction()   { /* POST encrypt?/password? → tar.gz [+ openssl enc] → 返回二进制 */ }
public function importAction()   { /* multipart upload → 解密 → strategy=overwrite|merge → mihomo -t → 应用 */ }
public function listAction()     { /* GET 扫描 backups/ */ }
public function downloadAction() { /* GET ?file= → readfile */ }
public function restoreAction()  { /* POST ?file= → 走 import 的应用路径 */ }
public function deleteAction()   { /* POST ?file= → unlink */ }
```

---

## P3：Subscriptions Tab 配套（控制器 + 后端脚本）

> Subscriptions Tab UI 见 P2.1 Tab 2。本节覆盖 ApiMutableModelControllerBase 子类与后端抓取脚本。

### P3.1 — `Api/SubscriptionsController.php`

```php
class SubscriptionsController extends ApiMutableModelControllerBase
{
    protected static $internalModelClass = 'OPNsense\\Mihomo\\Mihomo';
    protected static $internalModelName  = 'mihomo';

    public function searchItemAction()  { return $this->searchBase("subscriptions.subscription", null, "name"); }
    public function getItemAction($uuid = null) { return $this->getBase("subscription", "subscriptions.subscription", $uuid); }
    public function setItemAction($uuid)        { return $this->setBase("subscription", "subscriptions.subscription", $uuid); }
    public function addItemAction()             { return $this->addBase("subscription", "subscriptions.subscription"); }
    public function delItemAction($uuid)        { return $this->delBase("subscriptions.subscription", $uuid); }
    public function toggleItemAction($uuid, $enabled = null) {
        return $this->toggleBase("subscriptions.subscription", $uuid, $enabled);
    }

    public function refreshAction($uuid)  { /* POST → configctl mihomo sub-refresh <uuid> 后台 */ }
    public function logAction()           { /* GET ?lines= → tail /var/log/mihomo_sub.log */ }
}
```

### P3.2 — `scripts/mihomo/sub.sh` 重写

按设计文档 5.4 参数化重写，路径从 `/usr/local/etc/mihomo/sub/sub.sh` 迁到 `/usr/local/opnsense/scripts/mihomo/sub.sh`：

```bash
# sub.sh <sub_uuid>
# 1. 通过 configctl mihomo sub-update 读取订阅 UUID（OPNsense config.xml）
# 2. 更新 subscription.last_status = "updating"（写 config.xml）
# 3. curl 下载到 /tmp/sub-<uuid>.raw
# 4. 提取 proxies/proxy-groups/rules
# 5. 应用 include/exclude 关键词过滤（仅过滤 proxies 节点名）
# 6. 写入 /tmp/sub-<uuid>.yaml，mihomo -t 校验
# 7. 校验通过 → mv 覆盖 profiles/sub-<name>.yaml
# 8. 更新 profiles/sub-<name>.meta.json（node_count + last_update）
# 9. 更新 config.xml 中该 subscription 的 last_update + last_status = "done"/"failed"
# 10. 如果 active → configctl mihomo reconfigure
# 11. stdout/stderr >> /var/log/mihomo_sub.log（每行 [sub_id=<uuid>] 前缀）
```

### P3.3 — `scripts/mihomo/sub_cron.sh`（新增）

Cron 入口脚本（由 `[sub-update]` configd action 触发）：

```bash
# 1. sleep $((RANDOM % 30)) 随机延迟
# 2. flock -n /tmp/mihomo-sub-cron.lock 防并发
# 3. 读取 OPNsense config.xml 中所有 subscription 节点
# 4. 遍历每条：如果 enabled && last_update + interval*3600 <= now → sub.sh <uuid>
```

### P3.4 — `scripts/mihomo/update_core.sh`（新增）

按设计文档 1.5.2 实现内核更新流程：
1. 读 `/tmp/mihomo-latest-release.json`（1h 缓存）
2. 下载 freebsd-amd64.gz + .sha256
3. SHA256 校验 → gunzip → smoke test（`mihomo -v`）
4. 备份 → 原子 mv → restart → 轮询 10s
5. 未恢复则自动回滚

进度写入 `/tmp/mihomo-update-core.json`（供 `Api/UpdateController::progressAction()` 读取）。

### P3.5 — `scripts/mihomo/update_geoip.sh` + `update_ui.sh`（新增）

- `update_geoip.sh`：拉取 Country.mmdb → 备份 → 替换 → `PUT /configs/geo` 热重载（不支持则 `configctl mihomo reconfigure`）
- `update_ui.sh <variant>`：拉取 zip → 解压到 `/tmp/mihomo-ui-new` → `mv ui ui.bak.<ts> && mv /tmp/mihomo-ui-new ui`

---

## P4：Backup Tab 配套

> Backup Tab UI 见 P2.1 Tab 8；控制器见 P2.5 `Api/BackupController`。所需脚本工具（`tar` / `openssl enc` / `mihomo -t` 校验）均为系统内建命令，无新增脚本文件。

### P4.1 — 占位

本节保留以维持依赖图编号。

---

## P5：国际化 + 兼容 + 收尾

### P5.1 — `lang/zh_CN/LC_MESSAGES/mihomo.po` + 编译 `.mo`

- 从所有 Volt 模板、Forms XML、PHP 控制器、Menu.xml、ACL.xml 提取字符串
- 提取工具：`xgettext` 扫描 `*.volt` / `*.php` / `*.xml`
- 编写中文 `.po` 文件
- 编译为 `.mo`（`msgfmt`）
- 同时生成 `.pot` 模板

### P5.2 — 旧 URL 兼容

- `www/services_mihomo.php` → 302 跳转 `/ui/mihomo/dashboard`
- `www/sub.php` → 302 跳转 `/ui/mihomo/configuration#subscriptions`
- 仅保留这两个最小化跳转占位（< 5 行 PHP），其他旧 `www/*.php` 全部删除
- 旧 status 端点不保留（前端已切到 `/api/mihomo/...`）

### P5.3 — 日志查询能力

由 `Api/DashboardController::logsAction()` 提供（迁入 MVC）：

```
GET /api/mihomo/dashboard/logs?lines=100&level=error
```

日志路径不变（`/var/log/mihomo.log` 与 `/var/log/mihomo_sub.log`）。

### P5.4 — `plugins/mihomo.inc` 保持

现有插件逻辑基本不变（服务注册 + WAN IP 变化重启 + syslog），仅确认 `mihomo_services()` 注册的 pidfile 路径正确。

### P5.5 — `docs/` 目录整理

- 设计文档保留在 `docs/superpowers/specs/`
- 本实施计划放入同目录

---

## 实施顺序与依赖图

```
P0.1 (Model XML + ACL.xml)
 ├── P0.2 (Menu.xml — Dashboard + Configuration)
 ├── P0.3 (Forms XML × 7：general/controller/tun/dns/sniffer/update/dialogSubscription)
 ├── P0.4 (共享 Trait — YAML 合并/文件锁/createBackup/mihomoApiCall)
 ├── P0.5 (actions_mihomo.conf — start/stop/restart/status/reconfigure/sub-update/sub-refresh/update-*)
 ├── P0.6 (install.sh / Makefile：MVC 部署 + 菜单缓存清理)
 ├── P0.7 (migrate.sh — 旧 config.yaml → config.xml + base.yaml + profiles/legacy.yaml)
 │
 ├── P1.1 (DashboardController + dashboard.volt) ← 依赖 P1.2-P1.5
 │   ├── P1.2 (Api/ServiceController — status/start/stop/restart/reconfigure)
 │   ├── P1.3 (Api/DashboardController::trafficAction)
 │   ├── P1.4 (Api/DashboardController::healthProgressAction)
 │   └── P1.5 (scripts/mihomo/mihomo_health_check.sh)
 │
 ├── P2.1 (ConfigurationController + configuration.volt 8-Tab) ← 依赖 P2.2-P2.5、P3.1
 │   ├── P2.2 (Api/OverrideController)
 │   ├── P2.3 (Api/ProfilesController)
 │   ├── P2.4 (Api/UpdateController)
 │   └── P2.5 (Api/BackupController)
 │
 ├── P3.x (Subscriptions 配套)
 │   ├── P3.1 (Api/SubscriptionsController — ApiMutableModelControllerBase)
 │   ├── P3.2 (scripts/mihomo/sub.sh 重写 — 改读 config.xml)
 │   ├── P3.3 (scripts/mihomo/sub_cron.sh)
 │   ├── P3.4 (scripts/mihomo/update_core.sh)
 │   └── P3.5 (scripts/mihomo/update_geoip.sh + update_ui.sh)
 │
 ├── P4.x (Backup — UI 见 P2.1，控制器见 P2.5)
 │
 └── P5.1-P5.5 (i18n + 旧 URL 跳转 + plugins.inc + docs)
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

### 新建文件（OPNsense MVC 布局）

```
src/opnsense/mvc/app/
├── controllers/OPNsense/Mihomo/
│   ├── IndexController.php                              # P0 (路由)
│   ├── DashboardController.php                          # P1.1
│   ├── ConfigurationController.php                      # P2.1
│   ├── Api/MihomoFileTrait.php                          # P0.4 共享
│   ├── Api/ServiceController.php                        # P1.2
│   ├── Api/DashboardController.php                      # P1.3 + P1.4
│   ├── Api/SettingsController.php                       # P0.1 (ApiMutableModelControllerBase)
│   ├── Api/SubscriptionsController.php                  # P3.1 (ApiMutableModelControllerBase)
│   ├── Api/OverrideController.php                       # P2.2
│   ├── Api/ProfilesController.php                       # P2.3
│   ├── Api/UpdateController.php                         # P2.4
│   ├── Api/BackupController.php                         # P2.5
│   └── forms/
│       ├── general.xml / controller.xml / tun.xml /
│       ├── dns.xml / sniffer.xml / update.xml           # P0.3 (Settings 各 Group)
│       └── dialogSubscription.xml                       # P0.3 (Subscriptions 编辑对话框)
├── models/OPNsense/Mihomo/
│   ├── Mihomo.php / Mihomo.xml                          # P0.1
│   ├── ACL/ACL.xml                                      # P0.1
│   └── Menu/Menu.xml                                    # P0.2
└── views/OPNsense/Mihomo/
    ├── dashboard.volt                                   # P1.1
    └── configuration.volt                               # P2.1

src/opnsense/scripts/mihomo/
├── reconfigure.py                                       # P0.5 (configd [reconfigure] 入口)
├── sub.sh                                               # P3.2 (重写)
├── sub_cron.sh                                          # P3.3
├── mihomo_health_check.sh                               # P1.5
├── update_core.sh                                       # P3.4
├── update_geoip.sh                                      # P3.5
└── update_ui.sh                                         # P3.5

src/opnsense/service/conf/actions.d/
└── actions_mihomo.conf                                  # P0.5 (重写)

lang/zh_CN/LC_MESSAGES/
├── mihomo.po                                            # P5.1
└── mihomo.mo                                            # P5.1 (编译产物)

migrate.sh                                               # P0.7 (项目根目录)
```

### 修改文件

```
install.sh                                               # P0.6 — MVC 部署 + 菜单缓存清理
plugins/mihomo.inc                                       # P5.4 — pidfile 路径确认
www/services_mihomo.php                                  # P5.2 — 改为 302 跳转占位 (< 5 行)
www/sub.php                                              # P5.2 — 改为 302 跳转占位 (< 5 行)
```

### 删除文件

```
menu/Magic/Menu/Menu.xml                                 # 替换为 mvc/app/models/.../Menu/Menu.xml
www/mihomo_configuration.php                             # 不再存在；改用 Volt
www/mihomo_dashboard.php                                 # 不再存在
www/status_mihomo.php / status_mihomo_logs.php /
www/status_sub_logs.php                                  # 全部迁入 /api/mihomo/...
www/includes/mihomo_lib.inc.php                          # 解构为 MihomoFileTrait + 模型
actions/actions_mihomo.conf                              # 路径变更到 src/opnsense/service/conf/actions.d/
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
