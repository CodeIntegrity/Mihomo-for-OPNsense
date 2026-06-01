# 仪表盘「运行状态」实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把仪表盘第 4 张卡「最近日志」替换为 OpenClash 风格的「运行状态」卡——经 Mihomo 代理查询的出口 IP + 4 站点访问检查。

**Architecture:** 纯 PHP 控制器内用 curl 经代理端口（127.0.0.1:`mixed_port` 或 `port`）实测，新增两个无副作用 GET 端点 `egressIp`/`accessCheck`，前端复用现有 `poller()` 轮询渲染。不碰 configd、不写 Python、不提权。

**Tech Stack:** PHP (Phalcon MVC, libcurl + curl_multi)、Volt 模板、vanilla JS + jQuery、Python unittest 契约测试。

**设计依据：** [docs/superpowers/specs/2026-05-31-dashboard-running-status-design.md](../specs/2026-05-31-dashboard-running-status-design.md)

---

## 关键约定（所有任务通用）

- **本地无 PHP**：`php -l` 必须经 SSH 在服务器跑（`mcp__ssh-mcp-server__execute-command`）。本地只跑 Python 契约测试。
- **契约测试命令**：`python3 -m unittest tests.test_contracts -v`（本地，`/usr/bin/python3`，无 pytest）。
- **已知无关失败**：`test_language_catalog_is_merged...` 当前就失败（install.sh 的 `OPNsense.mo` 断言，与本功能无关）。本计划只要求**新增的测试通过**且**不新增**其他失败。
- **部署**：本地改完 → `mcp__ssh-mcp-server__upload` 到服务器对应路径 → 服务器 `php -l` → Chrome MCP 冒烟。
- **Volt 缓存**：改 `.volt` 后部署需清 `/var/lib/php/cache/*.volt.php`，否则渲染旧模板。
- **端口字段铁律**：只有 `port`（默认 7890）和 `mixed_port`（默认 0）。**绝不出现 `http_port`**。
- **errorCode 枚举**（固定四值）：`proxy_disabled` / `proxy_unreachable` / `timeout` / `upstream_error`。

## 文件结构

| 文件 | 职责 | 改动类型 |
| --- | --- | --- |
| `src/opnsense/mvc/app/controllers/OPNsense/Mihomo/Api/MihomoFileTrait.php` | 新增 `resolveProxyPort()`（解析端口）、`proxiedCurl()`（单次经代理 curl，返回归一化结果含 errorCode） | Modify |
| `src/opnsense/mvc/app/controllers/OPNsense/Mihomo/Api/DashboardController.php` | 新增 `egressIpAction()`、`accessCheckAction()`；类顶部新增站点常量 | Modify |
| `src/opnsense/mvc/app/views/OPNsense/Mihomo/dashboard.volt` | 删日志卡 HTML/样式/logPoller；新增运行状态卡 + 渲染 JS + 两 poller + 隐私遮罩 | Modify |
| `tests/test_contracts.py` | 在 `MihomoContractsTest` 末尾新增 `test_dashboard_running_status_replaces_log_tail` | Modify |

> 任务顺序：先后端 helper（Task 1-2）→ 控制器端点（Task 3-4）→ 前端卡片（Task 5-7）→ 契约测试与部署验证（Task 8-10）。每个 Task 独立可提交。

---

## Task 1: `resolveProxyPort()` —— 代理端口解析

在 `MihomoFileTrait` 加一个纯函数：按 `mixed_port > 0 → port > 0 → 0` 顺序返回端口；都为 0 返回 0（表示禁用）。

**Files:**
- Modify: `src/opnsense/mvc/app/controllers/OPNsense/Mihomo/Api/MihomoFileTrait.php`（在 `mihomoApiCall()` 之后、约 327 行 `}` 后插入）
- Test: 经 Task 8 的契约测试间接覆盖（PHP 无本地单测框架，此处靠 `php -l` + 端点冒烟）

- [ ] **Step 1: 在 `mihomoApiCall()` 方法之后插入 `resolveProxyPort()`**

定位锚点：`MihomoFileTrait.php` 中 `mihomoApiCall()` 的结束（返回数组后的 `}`，约 327 行）。在其后插入：

```php
    /**
     * Resolve the HTTP proxy port to route checks through Mihomo.
     * Priority: mixed_port (>0, serves HTTP too) → port (>0) → 0 (disabled).
     * Field names per Mihomo.xml: there is no `http_port`.
     */
    protected function resolveProxyPort()
    {
        $cfg = Config::getInstance()->object();
        $general = $cfg->OPNsense->Mihomo->mihomo->general ?? null;
        $mixed = (int)($general->mixed_port ?? 0);
        if ($mixed > 0) {
            return $mixed;
        }
        $port = (int)($general->port ?? 0);
        if ($port > 0) {
            return $port;
        }
        return 0;
    }
```

- [ ] **Step 2: 服务器 `php -l` 验证语法**

先 upload，再 lint：

```
mcp__ssh-mcp-server__upload  src/.../MihomoFileTrait.php → /usr/local/opnsense/mvc/app/controllers/OPNsense/Mihomo/Api/MihomoFileTrait.php
mcp__ssh-mcp-server__execute-command  sh -c 'php -l /usr/local/opnsense/mvc/app/controllers/OPNsense/Mihomo/Api/MihomoFileTrait.php'
```

Expected: `No syntax errors detected`

- [ ] **Step 3: Commit**

```bash
git add src/opnsense/mvc/app/controllers/OPNsense/Mihomo/Api/MihomoFileTrait.php
git commit -m "feat: resolveProxyPort() — 按 mixed_port>port 解析代理端口"
```

---

## Task 2: `proxiedCurl()` —— 经代理单次请求 + errorCode 归一化

加一个共用 curl 辅助：给定 url + 选项，经代理端口请求，把 curl 错误归一化为统一 errorCode。`egressIp` 直接用它；`accessCheck` 复用同一套 errorCode 映射逻辑（Task 4 用 curl_multi，但错误分类共享 `curlErrorCode()`）。

**Files:**
- Modify: `src/opnsense/mvc/app/controllers/OPNsense/Mihomo/Api/MihomoFileTrait.php`（紧接 Task 1 的 `resolveProxyPort()` 之后）

- [ ] **Step 1: 插入 `curlErrorCode()` + `proxiedCurl()`**

在 `resolveProxyPort()` 之后插入：

```php
    /**
     * Map a libcurl errno to our stable errorCode enum.
     * Connection-class errors → proxy_unreachable; timeouts → timeout.
     */
    protected function curlErrorCode($errno)
    {
        return $errno === CURLE_OPERATION_TIMEOUTED ? 'timeout' : 'proxy_unreachable';
    }

    /**
     * Perform one HTTP GET through the Mihomo proxy.
     * Returns: ['ok'=>bool, 'status'=>int, 'body'=>string|null,
     *           'ms'=>int|null, 'errorCode'=>string|null]
     * On disabled proxy (port 0) returns ok=false, errorCode=proxy_disabled.
     */
    protected function proxiedCurl($url, $timeout = 5, array $extra = [])
    {
        $port = $this->resolveProxyPort();
        if ($port <= 0) {
            return ['ok' => false, 'status' => 0, 'body' => null,
                    'ms' => null, 'errorCode' => 'proxy_disabled'];
        }
        $ch = curl_init($url);
        curl_setopt_array($ch, [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_PROXY          => '127.0.0.1',
            CURLOPT_PROXYPORT      => $port,
            CURLOPT_PROXYTYPE      => CURLPROXY_HTTP,
            CURLOPT_CONNECTTIMEOUT => 3,
            CURLOPT_TIMEOUT        => $timeout,
            CURLOPT_FOLLOWLOCATION => true,
            CURLOPT_MAXREDIRS      => 3,
            CURLOPT_SSL_VERIFYPEER => true,
            CURLOPT_USERAGENT      => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
                . 'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36',
        ] + $extra);
        $body  = curl_exec($ch);
        $errno = curl_errno($ch);
        $code  = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
        $secs  = (float)curl_getinfo($ch, CURLINFO_TOTAL_TIME);
        curl_close($ch);

        if ($errno !== 0) {
            return ['ok' => false, 'status' => 0, 'body' => null,
                    'ms' => null, 'errorCode' => $this->curlErrorCode($errno)];
        }
        $ok = $code >= 200 && $code < 400;
        return [
            'ok'        => $ok,
            'status'    => $code,
            'body'      => is_string($body) ? $body : null,
            'ms'        => (int)round($secs * 1000),
            'errorCode' => $ok ? null : 'upstream_error',
        ];
    }
```

- [ ] **Step 2: 服务器 `php -l` 验证**

upload + `php -l`（同 Task 1 Step 2）。Expected: `No syntax errors detected`

- [ ] **Step 3: Commit**

```bash
git add src/opnsense/mvc/app/controllers/OPNsense/Mihomo/Api/MihomoFileTrait.php
git commit -m "feat: proxiedCurl() + curlErrorCode() — 经代理请求与错误码归一化"
```

---

## Task 3: `egressIpAction()` —— 出口 IP 端点

经代理打 `https://api.ip.sb/geoip`，归一化为 `{ok, ip, country, isp}` 或 `{ok:false, errorCode}`。

**Files:**
- Modify: `src/opnsense/mvc/app/controllers/OPNsense/Mihomo/Api/DashboardController.php`（在 `healthProgressAction()` 之后、类结束 `}` 之前，约 185 行）

- [ ] **Step 1: 在类末尾（`healthProgressAction()` 之后）插入端点**

```php
    /** GET /api/mihomo/dashboard/egressIp — egress public IP via proxy. */
    public function egressIpAction()
    {
        $r = $this->proxiedCurl('https://api.ip.sb/geoip', 5);
        if (!$r['ok']) {
            return ['ok' => false, 'errorCode' => $r['errorCode']];
        }
        $j = json_decode((string)$r['body'], true);
        if (!is_array($j)) {
            return ['ok' => false, 'errorCode' => 'upstream_error'];
        }
        return [
            'ok'      => true,
            'ip'      => (string)($j['ip'] ?? ''),
            'country' => (string)($j['country'] ?? ''),
            'isp'     => (string)($j['isp'] ?? $j['organization'] ?? ''),
        ];
    }
```

- [ ] **Step 2: 服务器 `php -l` 验证 DashboardController.php**

```
upload DashboardController.php → /usr/local/.../Api/DashboardController.php
php -l /usr/local/.../Api/DashboardController.php
```

Expected: `No syntax errors detected`

- [ ] **Step 3: 端点冒烟（服务运行时）**

```
mcp__ssh-mcp-server__execute-command  sh -c 'curl -s -u <key>:<secret> http://127.0.0.1/api/mihomo/dashboard/egressIp'
```

Expected: JSON 含 `"ok":true` + `"ip"`，或 `"ok":false` + 四个 errorCode 之一。**不得** 500。
（若鉴权不便，改为 Task 9 的 Chrome MCP `list_network_requests` 验证。）

- [ ] **Step 4: Commit**

```bash
git add src/opnsense/mvc/app/controllers/OPNsense/Mihomo/Api/DashboardController.php
git commit -m "feat: egressIp 端点 — 经代理查出口 IP + 地理位置"
```

---

## Task 4: `accessCheckAction()` —— 4 站点并发访问检查

类顶部加站点常量，用 `curl_multi_*` 并发，每站点固定参数，复用 `curlErrorCode()` 分类。

**Files:**
- Modify: `src/opnsense/mvc/app/controllers/OPNsense/Mihomo/Api/DashboardController.php`（常量加在 `$TRAFFIC_STATE_FILE` 之后约 21 行；方法加在 `egressIpAction()` 之后）

- [ ] **Step 1: 在类内 `$TRAFFIC_STATE_FILE` 声明之后加站点常量**

```php
    /** Access-check targets (fixed set, mirrors OpenClash defaults). */
    private static $CHECK_SITES = [
        ['key' => 'baidu',   'name' => '百度',        'url' => 'https://www.baidu.com'],
        ['key' => 'netease', 'name' => '网易云音乐',  'url' => 'https://music.163.com'],
        ['key' => 'github',  'name' => 'GitHub',      'url' => 'https://github.com'],
        ['key' => 'youtube', 'name' => 'YouTube',     'url' => 'https://www.youtube.com'],
    ];
```

- [ ] **Step 2: 在 `egressIpAction()` 之后插入 `accessCheckAction()`**

```php
    /** GET /api/mihomo/dashboard/accessCheck — per-site connectivity via proxy. */
    public function accessCheckAction()
    {
        $port = $this->resolveProxyPort();
        if ($port <= 0) {
            $results = [];
            foreach (self::$CHECK_SITES as $s) {
                $results[] = ['key' => $s['key'], 'name' => $s['name'], 'ok' => false,
                              'status' => 0, 'ms' => null, 'errorCode' => 'proxy_disabled'];
            }
            return ['ok' => true, 'results' => $results];
        }

        $ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            . '(KHTML, like Gecko) Chrome/120.0 Safari/537.36';
        $mh = curl_multi_init();
        $handles = [];
        foreach (self::$CHECK_SITES as $s) {
            $ch = curl_init($s['url']);
            curl_setopt_array($ch, [
                CURLOPT_RETURNTRANSFER => true,
                CURLOPT_NOBODY         => false,
                CURLOPT_RANGE          => '0-0',
                CURLOPT_PROXY          => '127.0.0.1',
                CURLOPT_PROXYPORT      => $port,
                CURLOPT_PROXYTYPE      => CURLPROXY_HTTP,
                CURLOPT_CONNECTTIMEOUT => 3,
                CURLOPT_TIMEOUT        => 5,
                CURLOPT_FOLLOWLOCATION => true,
                CURLOPT_MAXREDIRS      => 3,
                CURLOPT_SSL_VERIFYPEER => true,
                CURLOPT_USERAGENT      => $ua,
            ]);
            curl_multi_add_handle($mh, $ch);
            $handles[$s['key']] = $ch;
        }

        $running = null;
        do {
            curl_multi_exec($mh, $running);
            curl_multi_select($mh, 1.0);
        } while ($running > 0);

        $results = [];
        foreach (self::$CHECK_SITES as $s) {
            $ch    = $handles[$s['key']];
            $errno = curl_errno($ch);
            $code  = (int)curl_getinfo($ch, CURLINFO_HTTP_CODE);
            $secs  = (float)curl_getinfo($ch, CURLINFO_TOTAL_TIME);
            curl_multi_remove_handle($mh, $ch);
            curl_close($ch);

            if ($errno !== 0) {
                $results[] = ['key' => $s['key'], 'name' => $s['name'], 'ok' => false,
                              'status' => 0, 'ms' => null,
                              'errorCode' => $this->curlErrorCode($errno)];
                continue;
            }
            $ok = $code >= 200 && $code < 400;
            $results[] = [
                'key'       => $s['key'],
                'name'      => $s['name'],
                'ok'        => $ok,
                'status'    => $code,
                'ms'        => (int)round($secs * 1000),
                'errorCode' => $ok ? null : 'upstream_error',
            ];
        }
        curl_multi_close($mh);
        return ['ok' => true, 'results' => $results];
    }
```

- [ ] **Step 3: 服务器 `php -l` 验证**

upload + `php -l DashboardController.php`. Expected: `No syntax errors detected`

- [ ] **Step 4: 端点冒烟**

```
curl -s -u <key>:<secret> http://127.0.0.1/api/mihomo/dashboard/accessCheck
```

Expected: `"ok":true` + `results` 含 4 个站点，每个有 `key/name/ok/status/ms/errorCode`。**不得** 500。

- [ ] **Step 5: Commit**

```bash
git add src/opnsense/mvc/app/controllers/OPNsense/Mihomo/Api/DashboardController.php
git commit -m "feat: accessCheck 端点 — curl_multi 并发探测 4 站点"
```

---

## Task 5: 删除日志卡 HTML + 样式 + logPoller

把 `dashboard.volt` 的日志相关三处删掉，为新卡腾位。先删后加，避免 id 冲突。

**Files:**
- Modify: `src/opnsense/mvc/app/views/OPNsense/Mihomo/dashboard.volt`

- [ ] **Step 1: 删除 `.mihomo-log` 样式块（82–94 行）**

删除整段：

```css
    .mihomo-log {
        display: block;
        width: 100%;
        max-width: 100%;
        height: 220px;
        font-family: monospace;
        font-size: 12px;
        background: #f5f5f5;
        color: #333;
        border: 1px solid #ccc;
        resize: vertical;
        box-sizing: border-box;
    }
```

- [ ] **Step 2: 删除日志卡 HTML（258–268 行 `{# 4. Recent Log Tail #}` 整块）**

删除整段：

```html
{# 4. Recent Log Tail #}
<div class="mihomo-card">
    <div class="card-header">
        <span class="card-icon fa fa-file-text-o"></span>
        <span class="card-title">最近日志</span>
        <span style="font-weight:normal;color:#999;font-size:12px;margin-left:8px;">最近 30 行</span>
    </div>
    <div class="card-body" style="padding-top:10px;">
        <textarea class="mihomo-log" id="log-tail" readonly></textarea>
    </div>
</div>
```

- [ ] **Step 3: 删除 `logPoller` 定义（527–532 行 `// ----- log tail -----` 整块）**

删除整段：

```javascript
    // ----- log tail -----
    var logPoller = poller('/api/mihomo/dashboard/logs?lines=30', 5000, function(j) {
        var ta = document.getElementById('log-tail');
        var atBottom = (ta.scrollTop + ta.clientHeight) >= (ta.scrollHeight - 4);
        ta.value = j.logs || '';
        if (atBottom) ta.scrollTop = ta.scrollHeight;
    });
```

- [ ] **Step 4: 从 `visibilitychange` 中移除 `logPoller` 引用（535–541 行）**

把这两行里的 `logPoller.stop()` / `logPoller.resume()` 删掉：

```javascript
        if (document.hidden) {
            statusPoller.stop(); trafficPoller.stop(); logPoller.stop();
        } else {
            statusPoller.resume(); trafficPoller.resume(); logPoller.resume();
            loadActiveProfile(); loadProfileList();
        }
```

改为（运行状态的两个 poller 在 Task 7 加入，此步先去掉 logPoller，留 statusPoller/trafficPoller）：

```javascript
        if (document.hidden) {
            statusPoller.stop(); trafficPoller.stop();
        } else {
            statusPoller.resume(); trafficPoller.resume();
            loadActiveProfile(); loadProfileList();
        }
```

- [ ] **Step 5: Commit**

```bash
git add src/opnsense/mvc/app/views/OPNsense/Mihomo/dashboard.volt
git commit -m "refactor: 移除仪表盘日志卡(日志在 Configuration 日志 tab 仍在)"
```

---

## Task 6: 新增「运行状态」卡 HTML + 样式

在原日志卡位置（Realtime Metrics 卡之后）插入运行状态卡。

**Files:**
- Modify: `src/opnsense/mvc/app/views/OPNsense/Mihomo/dashboard.volt`

- [ ] **Step 1: 在 `</style>` 之前补充运行状态卡专属样式**

锚点：`.mihomo-status-light.is-unknown { background: #f0ad4e; }`（约 110 行）之后、`</style>` 之前插入：

```css
    .mihomo-status-row {
        display: flex; align-items: center; justify-content: space-between;
        padding: 8px 0; border-bottom: 1px solid #f3f3f3;
    }
    .mihomo-status-row:last-child { border-bottom: none; }
    .mihomo-status-row .label { color: #555; font-size: 13px; }
    .mihomo-status-row .val { font-family: monospace; font-size: 13px; }
    .mihomo-ip-line { font-family: monospace; font-size: 15px; }
    .mihomo-ip-geo { color: #888; font-size: 13px; margin-left: 8px; }
    .mihomo-section-sub {
        font-size: 12px; color: #999; text-transform: uppercase;
        margin: 14px 0 4px;
    }
    .mihomo-dot {
        display: inline-block; width: 8px; height: 8px; border-radius: 50%;
        margin-right: 6px; background: #aaa; vertical-align: middle;
    }
    .mihomo-dot.ok { background: #5cb85c; }
    .mihomo-dot.bad { background: #d9534f; }
    .mihomo-ms.g { color: #32b643; }
    .mihomo-ms.y { color: #f0ad4e; }
    .mihomo-ms.o { color: #e85600; }
    .mihomo-icon-btn { cursor: pointer; color: #888; margin-left: 10px; }
    .mihomo-icon-btn:hover { color: #333; }
```

- [ ] **Step 2: 在 Realtime Metrics 卡之后（原日志卡位置）插入运行状态卡 HTML**

锚点：Realtime Metrics 卡的结束 `</div>`（原 256 行附近，现因删卡后行号前移）。插入：

```html
{# 4. Running Status — egress IP + access check #}
<div class="mihomo-card">
    <div class="card-header">
        <span class="card-icon fa fa-globe"></span>
        <span class="card-title">运行状态</span>
        <i class="fa fa-eye mihomo-icon-btn" id="rs-eye" title="隐藏 IP"></i>
        <i class="fa fa-refresh mihomo-icon-btn" id="rs-refresh" title="立即刷新"></i>
    </div>
    <div class="card-body">
        <div class="mihomo-section-sub">出口 IP</div>
        <div class="mihomo-status-row">
            <span class="mihomo-ip-line"><span id="rs-ip">—</span><span class="mihomo-ip-geo" id="rs-ip-geo"></span></span>
        </div>
        <div class="mihomo-section-sub">访问检查</div>
        <div id="rs-check-list">
            <div class="mihomo-status-row" data-key="baidu">
                <span class="label">百度</span>
                <span class="val"><span class="mihomo-dot" id="dot-baidu"></span><span id="st-baidu">—</span> <span class="mihomo-ms" id="ms-baidu"></span></span>
            </div>
            <div class="mihomo-status-row" data-key="netease">
                <span class="label">网易云音乐</span>
                <span class="val"><span class="mihomo-dot" id="dot-netease"></span><span id="st-netease">—</span> <span class="mihomo-ms" id="ms-netease"></span></span>
            </div>
            <div class="mihomo-status-row" data-key="github">
                <span class="label">GitHub</span>
                <span class="val"><span class="mihomo-dot" id="dot-github"></span><span id="st-github">—</span> <span class="mihomo-ms" id="ms-github"></span></span>
            </div>
            <div class="mihomo-status-row" data-key="youtube">
                <span class="label">YouTube</span>
                <span class="val"><span class="mihomo-dot" id="dot-youtube"></span><span id="st-youtube">—</span> <span class="mihomo-ms" id="ms-youtube"></span></span>
            </div>
        </div>
    </div>
</div>
```

- [ ] **Step 3: Commit**

```bash
git add src/opnsense/mvc/app/views/OPNsense/Mihomo/dashboard.volt
git commit -m "feat: 仪表盘运行状态卡 HTML + 样式"
```

---

## Task 7: 运行状态渲染 JS + 两个 poller + 隐私遮罩

在 `dashboard.volt` 的 `<script>` 内（原 logPoller 位置）加渲染逻辑。复用现有 `poller()`、`fmtBytes` 同区。

**Files:**
- Modify: `src/opnsense/mvc/app/views/OPNsense/Mihomo/dashboard.volt`

- [ ] **Step 1: 在 trafficPoller 之后（原 log tail 注释位置）插入运行状态逻辑**

锚点：trafficPoller 定义结束（约 524 行 `});`）之后插入：

```javascript
    // ----- running status: egress IP + access check -----
    var ERR_TEXT = {
        proxy_disabled:    '代理端口未启用',
        proxy_unreachable: '代理不可达',
        timeout:           '超时',
        upstream_error:    '查询失败'
    };
    var CHECK_KEYS = ['baidu', 'netease', 'github', 'youtube'];
    var ipPrivacy = localStorage.getItem('mihomo_rs_privacy') === 'true';
    var lastIp = '';

    function renderIp(j) {
        var ipEl = document.getElementById('rs-ip');
        var geoEl = document.getElementById('rs-ip-geo');
        if (!j.ok) {
            lastIp = '';
            ipEl.textContent = ERR_TEXT[j.errorCode] || '—';
            geoEl.textContent = '';
            return;
        }
        lastIp = j.ip || '';
        ipEl.textContent = ipPrivacy ? '***.***.***.***' : (j.ip || '—');
        var geo = [j.country, j.isp].filter(Boolean).join(' / ');
        geoEl.textContent = geo ? ('· ' + geo) : '';
    }

    function msClass(ms) {
        if (ms == null) return '';
        if (ms <= 500) return 'g';
        if (ms <= 1000) return 'y';
        return 'o';
    }

    function renderCheck(j) {
        var map = {};
        (j.results || []).forEach(function(r) { map[r.key] = r; });
        CHECK_KEYS.forEach(function(k) {
            var r = map[k];
            var dot = document.getElementById('dot-' + k);
            var st  = document.getElementById('st-' + k);
            var ms  = document.getElementById('ms-' + k);
            if (!r) { st.textContent = '—'; ms.textContent = ''; dot.className = 'mihomo-dot'; return; }
            if (r.ok) {
                dot.className = 'mihomo-dot ok';
                st.textContent = '正常';
                ms.textContent = (r.ms != null ? r.ms + ' ms' : '');
                ms.className = 'mihomo-ms ' + msClass(r.ms);
            } else {
                dot.className = 'mihomo-dot bad';
                st.textContent = ERR_TEXT[r.errorCode] || '失败';
                ms.textContent = '';
                ms.className = 'mihomo-ms';
            }
        });
    }

    var egressPoller = poller('/api/mihomo/dashboard/egressIp', 30000, renderIp);
    var checkPoller  = poller('/api/mihomo/dashboard/accessCheck', 15000, renderCheck);

    // privacy eye toggle
    function applyEye() {
        var el = document.getElementById('rs-eye');
        el.className = 'fa mihomo-icon-btn ' + (ipPrivacy ? 'fa-eye-slash' : 'fa-eye');
        el.title = ipPrivacy ? '显示 IP' : '隐藏 IP';
        var ipEl = document.getElementById('rs-ip');
        if (lastIp) ipEl.textContent = ipPrivacy ? '***.***.***.***' : lastIp;
    }
    document.getElementById('rs-eye').onclick = function() {
        ipPrivacy = !ipPrivacy;
        localStorage.setItem('mihomo_rs_privacy', ipPrivacy ? 'true' : 'false');
        applyEye();
    };
    applyEye();

    // manual refresh — restart both pollers immediately
    document.getElementById('rs-refresh').onclick = function() {
        egressPoller.stop(); checkPoller.stop();
        egressPoller.resume(); checkPoller.resume();
    };
```

- [ ] **Step 2: 把两个 poller 加入 `visibilitychange` 的 stop/resume**

锚点：Task 5 Step 4 改过的 `visibilitychange` 块。改为：

```javascript
        if (document.hidden) {
            statusPoller.stop(); trafficPoller.stop();
            egressPoller.stop(); checkPoller.stop();
        } else {
            statusPoller.resume(); trafficPoller.resume();
            egressPoller.resume(); checkPoller.resume();
            loadActiveProfile(); loadProfileList();
        }
```

- [ ] **Step 3: Commit**

```bash
git add src/opnsense/mvc/app/views/OPNsense/Mihomo/dashboard.volt
git commit -m "feat: 运行状态渲染 JS — 双 poller + 隐私遮罩 + 延迟着色"
```

---

## Task 8: 契约测试

在 `tests/test_contracts.py` 的 `MihomoContractsTest` 类末尾新增一个测试，断言前后端契约。

**Files:**
- Modify: `tests/test_contracts.py`（在 `test_configuration_volt_uses_codemirror` 之后、`# ---- Update helpers` 注释之前，约 93 行）

- [ ] **Step 1: 写测试**

锚点：`test_configuration_volt_uses_codemirror` 方法结束（约 92 行 `self.assertNotIn("alert(d.content", view)`）之后、空行与 `# ---- Update helpers` 之前，插入：

```python
    def test_dashboard_running_status_replaces_log_tail(self):
        view = read("src/opnsense/mvc/app/views/OPNsense/Mihomo/dashboard.volt")
        ctrl = read("src/opnsense/mvc/app/controllers/OPNsense/Mihomo/Api/DashboardController.php")
        trait = read("src/opnsense/mvc/app/controllers/OPNsense/Mihomo/Api/MihomoFileTrait.php")
        # 日志卡已从仪表盘移除
        self.assertNotIn('id="log-tail"', view)
        self.assertNotIn("mihomo-log", view)
        self.assertNotIn("logPoller", view)
        # 新增运行状态两端点的前端调用
        self.assertIn("/api/mihomo/dashboard/egressIp", view)
        self.assertIn("/api/mihomo/dashboard/accessCheck", view)
        # 控制器新增两个 action
        self.assertIn("function egressIpAction", ctrl)
        self.assertIn("function accessCheckAction", ctrl)
        # 走代理而非直连，且端口字段用对（无 http_port）
        self.assertIn("CURLOPT_PROXY", trait)
        self.assertIn("mixed_port", trait)
        self.assertNotIn("http_port", trait)
        self.assertNotIn("http_port", ctrl)
        # 失败契约：四个稳定 errorCode 都在前端有映射
        for code in ("proxy_disabled", "proxy_unreachable", "timeout", "upstream_error"):
            self.assertIn(code, view)
```

- [ ] **Step 2: 跑新测试，确认通过**

Run: `python3 -m unittest tests.test_contracts.MihomoContractsTest.test_dashboard_running_status_replaces_log_tail -v`
Expected: `OK`（1 test）

- [ ] **Step 3: 跑全量契约测试，确认未新增失败**

Run: `python3 -m unittest tests.test_contracts -v 2>&1 | tail -4`
Expected: 仅 `test_language_catalog...` 这 1 个**既有**失败（与本功能无关），新测试通过，无其他新增失败。

- [ ] **Step 4: Commit**

```bash
git add tests/test_contracts.py
git commit -m "test: 契约断言运行状态卡替换日志卡、端口字段、errorCode"
```

---

## Task 9: 部署 + Chrome MCP 冒烟（成功路径）

服务运行时，验证卡片渲染与两端点响应。

**Files:** 无（部署 + 验证）

- [ ] **Step 1: 部署三个改动文件到服务器**

```
upload MihomoFileTrait.php   → /usr/local/opnsense/mvc/app/controllers/OPNsense/Mihomo/Api/MihomoFileTrait.php
upload DashboardController.php → /usr/local/opnsense/mvc/app/controllers/OPNsense/Mihomo/Api/DashboardController.php
upload dashboard.volt         → /usr/local/opnsense/mvc/app/views/OPNsense/Mihomo/dashboard.volt
```

- [ ] **Step 2: 清 Volt 编译缓存**

```
mcp__ssh-mcp-server__execute-command  sh -c 'rm -f /var/lib/php/cache/*.volt.php; echo cleared'
```

Expected: `cleared`

- [ ] **Step 3: 确保 mihomo 服务运行**

```
mcp__ssh-mcp-server__execute-command  sh -c 'service mihomo status'
```

若未运行：`service mihomo start`。

- [ ] **Step 4: Chrome MCP 导航 + 快照**

```
mcp__chrome-devtools__navigate_page  → /ui/mihomo/dashboard
mcp__chrome-devtools__take_snapshot
```

Expected: 快照含「运行状态」卡，有「出口 IP」「访问检查」两区与 4 个站点行；**无**「最近日志」textarea。

- [ ] **Step 5: 验证两端点网络请求**

```
mcp__chrome-devtools__list_network_requests   （过滤 egressIp / accessCheck）
mcp__chrome-devtools__get_network_request     （取 accessCheck 响应体）
```

Expected: 两请求 HTTP 200；`egressIp` body 为 `{ok:true,ip,...}` 或 `{ok:false,errorCode}`；`accessCheck` body 为 `{ok:true,results:[4]}`。

- [ ] **Step 6: 控制台无报错**

```
mcp__chrome-devtools__list_console_messages
```

Expected: 无与运行状态相关的 JS error。

---

## Task 10: 失败路径冒烟

停服务，验证端点不 500、前端按 errorCode 显示提示而非伪造。

**Files:** 无（验证）

- [ ] **Step 1: 停 mihomo 服务**

```
mcp__ssh-mcp-server__execute-command  sh -c 'service mihomo stop; sleep 1; service mihomo status'
```

- [ ] **Step 2: 重新加载仪表盘，看降级渲染**

```
mcp__chrome-devtools__navigate_page  → /ui/mihomo/dashboard
mcp__chrome-devtools__take_snapshot
```

Expected: 出口 IP 显示「代理不可达」（或端口禁用时「代理端口未启用」）；4 站点行显示对应错误文案 + 红点；**无** 500、无空白崩溃、无伪造 IP。

- [ ] **Step 3: 验证端点返回 HTTP 200 + 失败 JSON**

```
mcp__chrome-devtools__list_network_requests  （确认 egressIp/accessCheck 仍是 200）
```

Expected: 两请求 HTTP 200；body 为 `{ok:false,errorCode:...}` / `{ok:true,results:[...errorCode...]}`。

- [ ] **Step 4: 恢复服务**

```
mcp__ssh-mcp-server__execute-command  sh -c 'service mihomo start; sleep 1; service mihomo status'
```

Expected: 服务恢复 running，仪表盘恢复正常出口 IP + 检查结果。

- [ ] **Step 5: 最终验证全量契约测试**

Run: `python3 -m unittest tests.test_contracts -v 2>&1 | tail -4`
Expected: 仅既有的 `test_language_catalog...` 失败，本功能新测试通过。

---

## 完成标准

- [ ] 仪表盘第 4 卡为「运行状态」，含出口 IP（带隐私遮罩）+ 4 站点访问检查（连通性 + 延迟着色）。
- [ ] 「最近日志」卡已从仪表盘移除；Configuration → 日志 tab 仍正常（`logsAction`/`tailLines` 未动）。
- [ ] 两端点经代理实测，失败时 HTTP 200 + 稳定 errorCode，前端按码显示提示、不伪造数据。
- [ ] 端口解析用 `mixed_port`/`port`，无 `http_port`。
- [ ] 新契约测试通过，无新增测试失败。
- [ ] 成功路径与失败路径 Chrome MCP 冒烟均通过。
