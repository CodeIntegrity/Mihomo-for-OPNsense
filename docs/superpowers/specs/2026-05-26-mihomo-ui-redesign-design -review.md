# Mihomo for OPNsense — UI 审查意见

## Gemini审查建议
### 1. 配置读写与并发冲突（File Locking）

在多 Tab 架构和后台 Cron 共同作用下，极易出现文件并发写入导致配置损坏的竞态条件。

* **场景**：用户在 UI 点击 Save（触发 `base.yaml` 或 `active.json` 写入），而恰好同一秒钟底层的 `sub_cron.sh` 完成了订阅更新并试图触发 `mergeBaseAndProfile()`。
* **建议**：在 `mihomo_lib.inc.php` 中实现一个统一的带锁文件读写封装（使用 PHP 的 `flock()`）。在执行合并和写入 `config.yaml` 期间，必须获取排他锁。如果获取锁超时，向前端抛出 503 或友好提示，避免文件写一半被截断。

### 2. YAML 序列化与高级特性丢失（YAML Parsing）

你在方案中提到 `config.yaml = merge(base, override, profile)` 将在 PHP 中手写实现。

* **潜在风险**：PHP 无论是使用 `yaml` 扩展还是 `Spyc` 库，在将 YAML 解析为 PHP 数组然后再 dump 回 YAML 的过程中，**会丢失原文件中的所有注释、YAML 锚点（Anchors `&`）和别名（Aliases `*`）**。
* **建议**：
* 如果决定走解析再生成的路线，需要在 UI 上明确提示用户：`override.yaml` 中不支持或不保证保留 YAML 锚点特性。
* 或者，对于 `override_head` 和 `override_tail`，如果不需要深度合并（Deep Merge），仅仅是文本级别的追加（Append/Prepend），可以考虑纯文本拼接，以最大程度保留用户手写的原始格式。



### 3. 前端轮询的异常处理（Graceful Degradation）

Dashboard 依赖 2s 和 5s 的短轮询获取状态和流量信息。

* **体验优化**：当用户在 Configuration 页面执行了 Save（触发了后端 `reloadMihomo` 或 `restartMihomo`），此时如果用户切回 Dashboard，正好碰上服务重启的空窗期，2s 轮询可能会遇到 502 Bad Gateway 或连接拒绝。
* **建议**：在 Vanilla JS 的 `fetch` 逻辑中加入退避机制（Exponential Backoff）和“正在重连”的 UI 状态转换，而不是直接报错显示 "Service not running" 引起不必要的恐慌。

### 4. 订阅抓取防雪崩（Cron Jitter）

`actions_mihomo.conf` 中的 `[sub-update]` 计划每小时运行一次，遍历 `subs.json` 触发抓取。

* **建议**：在 `sub_cron.sh` 的实际抓取逻辑前，引入一个随机的延迟（例如 `sleep $((RANDOM % 30))`）。如果用户配置了多个订阅，或者很多 OPNsense 实例同时在整点向同一个机场服务器发起请求，很容易被机场的 WAF 拦截或导致瞬时 CPU/内存峰值。

### 5. 健康检查的 PHP 进程阻塞

你在 2.4 中提到对于大量节点的 Health Check 采取“分批 10 并发，避免占满 PHP-FPM”。

* **补充考量**：PHP 的 `curl_multi` 虽然可以做到并发，但整个 HTTP 请求周期仍然是同步阻塞当前 PHP-FPM Worker 的。如果配置了 3000ms 的超时，100 个节点分 10 批，这个接口可能需要 30 秒才能返回。这不仅会导致前端请求超时，还极易耗尽 OPNsense 默认配置下的 PHP 进程池。
* **替代思路**：可以考虑让 UI 下发一个触发指令，后端生成一个异步的背景任务并输出结果到临时文件（如 `/tmp/mihomo_hc_result.json`），前端通过轮询这个 JSON 文件来获取进度和最终结果，彻底解放 PHP-FPM。

---

## Qwen审查建议

这份设计稿非常详尽，涵盖了从架构、UI/UX、数据流到迁移兼容性的所有关键方面。整体逻辑清晰，特别是“三层合成模型”和“Profile模式”的引入，很好地解决了现有痛点。

在当前时间点（2026-05-26），针对这份**已确认进入 self-review 阶段**的设计稿，我提出以下审查建议，分为**高优风险**、**功能完善**和**体验优化**三个维度：

### 1. 高优风险与技术债

这部分建议涉及核心逻辑的健壮性，建议在开发前确认。

*   **三层合并逻辑的冲突检测（Critical）**
    *   **问题点**：设计中提到 `override` 可以合并 `proxy-groups`（同名合并列表）和 `rules`（prepend + append）。
    *   **建议**：必须定义明确的**优先级和冲突解决策略**。例如，如果 `profile`（订阅）里有一个规则 `DOMAIN-SUFFIX,google.com,Proxy`，而用户在 `override` 的 `rules-append` 里加了 `DOMAIN-SUFFIX,google.com,Direct`，最终结果应该是什么？是覆盖还是追加无效？建议在 `mihomo_lib.inc.php` 的合并函数中加入日志记录，告知用户哪些配置被覆盖了。
*   **Health Check 的资源消耗（Performance）**
    *   **问题点**：Dashboard 的“闪电”健康检查按钮，设计稿提到“节点 >50 时分批每批 10 个并发”。
    *   **建议**：对于 OPNsense 这种嵌入式设备（通常资源有限），即使是 10 个并发也可能造成 PHP-FPM 阻塞或内存溢出。建议将并发数降低到 **3-5**，或者将其改为完全的后台异步任务（通过 cron job 或 shell exec），前端通过轮询状态来显示进度，而不是保持 HTTP 连接。
*   **GitHub Release 下载的稳定性（Fallback）**
    *   **问题点**：内核更新强依赖 GitHub API 和 Release。
    *   **建议**：除了提供 Mirror 选项外，建议增加**“上传本地文件更新”**的兜底方案（例如管理员下载了 tar.gz 放在 /tmp 下），以防 GitHub 完全无法访问或 API 限流。

### 2. 功能与逻辑完善

这部分是设计稿中隐含或未明确定义的逻辑，需要补全。

*   **Profile 的“手动编辑”与“订阅更新”冲突**
    *   **场景**：用户激活了一个订阅生成的 Profile（例如 `airport-a`），然后点击“Edit”修改了里面的某个节点名字。下一次自动订阅更新或手动刷新时，这个修改会被**直接覆盖**。
    *   **建议**：这是典型的 **"Upstream Sync"** 问题。
        *   方案 A（推荐）：当用户编辑了订阅生成的 Profile 时，UI 弹出警告：“此操作将使该 Profile 与订阅源解绑，后续更新将不再生效。是否继续？”
        *   方案 B：引入更复杂的版本控制或三路合并，但这对插件来说过于沉重。
*   **Override 的粒度控制**
    *   **问题点**：目前的 Override 是一个全量的 YAML 片段。
    *   **建议**：考虑增加针对**特定 Profile**的 Override，或者至少在 UI 上引导用户使用 `rules-prepend` 和 `rules-append`，避免用户在 Override 里写死 `proxies` 导致订阅节点重复。
*   **备份（Backup）的加密缺失**
    *   **问题点**：Backup 页明确提到包含 "API secret, subscription URLs"。
    *   **建议**：目前的 `tar.gz` 是明文的。建议增加**加密备份**选项（例如使用密码加密 zip），或者至少在 UI 上用醒目的红色文字警告用户“备份文件包含敏感信息，请勿随意上传至云端”。

### 3. 用户体验（UX）与 UI

*   **Dashboard 的 Metrics 卡片**
    *   **建议**：目前的布局是 4 列（Up/Down/Conns/Mem）。在小屏幕（如手机或小屏显示器）下可能会挤压。建议改为响应式布局，或者将 "Conns" 和 "Mem" 合并为一行显示。
*   **订阅过滤（Filter）的正则支持**
    *   **问题点**：订阅页有 `Include Keyword` 和 `Exclude Keyword`。
    *   **建议**：目前设计为 CSV（逗号分隔）。建议确认是否支持**正则表达式**。如果机场节点命名不规范，单纯的关键词过滤（如“HK”）可能会误杀（比如杀掉“HK-Block”）。如果能支持简单的正则（如 `^HK.*`）会强大很多。
*   **Logs 的搜索功能**
    *   **建议**：在 Tab 5 (Log) 中，除了行数过滤，建议增加简单的**关键词高亮**或**搜索框**，因为排查问题时在 500 行日志里肉眼找错误非常痛苦。

### 4. 安全与权限

*   **Secret 的管理**
    *   **建议**：在 Settings Tab 中生成或修改 Secret 后，建议增加一个**“显示/隐藏”**按钮，方便用户核对。同时，确保在任何日志或 API 调用中，Secret 都是脱敏显示的（如 `s****d`）。
*   **TUN 设备的权限**
    *   **建议**：在 Settings 的 TUN 分组中，虽然设计了 `tun.device` 默认为 `tun_3000`，但需要确保 `install.sh` 或 `mihomo_lib` 有逻辑去检查该设备是否存在，如果不存在是否有自动创建的逻辑，或者给出明确的错误提示。

### 5. 文档与国际化

*   **Tooltip 的利用**
    *   **建议**：设计稿中提到 `find-process-mode` 在 FreeBSD 上可能失效。对于这类高级且有风险的选项，建议在 UI 上增加 **(i)** 图标，鼠标悬停显示解释（例如：“Strict 模式在 FreeBSD 上可能因权限问题失效，建议保持 Always 或 Off”）。

### 总结

这份设计稿的质量很高，结构非常清晰。上述建议主要集中在**防止用户误操作**（如 Profile 覆盖、敏感数据泄露）和**资源控制**（如 Health Check 并发）上。

**特别针对当前时间（2026-05-26）的提示**：
由于这是“重设计”项目，建议在 `install.sh` 的迁移脚本（`migrate.sh`）中，除了备份旧配置外，**强制暂停 Mihomo 服务**，直到新配置验证通过。避免新旧版本配置同时运行导致的端口冲突或数据混乱。

## KIMI审查建议

## 一、高优先级：安全与可靠性

### 1. 敏感数据的文件权限与备份加密
当前设计在 `base.yaml`、`profiles/*.yaml`、`subs.json` 中集中存储了 API Secret、订阅 Token、代理凭证等高度敏感信息，但文档未明确文件权限策略。

**建议：**
- 强制所有配置文件为 `640`（`root:www`），目录 `750`。`install.sh` 与 `migrate.sh` 中必须显式 `chmod`。
- **Backup 导出**应提供可选的**密码加密**（如 `openssl enc -aes-256-cbc`），或至少提供 "Strip Sensitive Data" 模式（抹除订阅 URL 查询参数、代理密码），方便用户分享配置模板而不泄露凭证。
- Backup 页面的警告文字很好，但建议增加一个复选框："I understand this file contains credentials and will store it securely"。

### 2. GitHub API 速率限制与更新检查
Updates Tab 的 [Check] 按钮直接调用 `api.github.com`，未认证 IP 的速率限制为 **60 req/hour**。用户在调试或频繁切换页面时极易触限。

**建议：**
- 在 `/tmp/` 或 `/usr/local/etc/mihomo/` 中缓存 `latest-release.json`，TTL 设为 1 小时。Check 按钮优先读缓存，提供 [Force Refresh] 绕过缓存。
- 支持可选的 **GitHub Personal Access Token** 字段（Settings > Advanced），用于认证 API 请求，将速率限制提升至 5000 req/hour，这对企业或多设备环境很重要。

### 3. 配置验证与原子写入的覆盖范围
文档在 **3.2 Settings** 中提到了 `mihomo -t -f` 验证 + 原子 mv，这是关键的安全网。但需要确保**所有会改变 `config.yaml` 的路径**都执行此流程：
- Profile 激活（3.4）
- Override 保存（3.3）
- 订阅刷新完成后的自动合并（5.4）

**建议：**
- 在 `mihomo_lib.inc.php` 中封装一个 **`atomicConfigUpdate($newContent)`** 函数：先写 `/tmp/config.yaml.new` → `mihomo -t -f /tmp/config.yaml.new` → 通过后才 `mv` 覆盖正式文件 → `reloadMihomo()`。任何失败都自动保留旧配置运行，避免服务中断。
- `sub.sh` 在写入 `profiles/<name>.yaml` 前，也应先写临时文件并做 YAML 语法校验，避免抓取到损坏内容直接破坏现有 profile。

### 4. Dashboard "Open Dashboard UI" 链接的可达性
按钮链接到 `http://<<opnsense_ip>:9090/ui/`。如果 `external-controller` 绑定在 `127.0.0.1:9090`（安全最佳实践），而用户通过 WAN/VPN 访问 OPNsense Web UI，此链接将**无法访问**。

**建议：**
- 动态生成链接：读取 `external-controller` 的绑定地址。如果是 `127.0.0.1` 或 `0.0.0.0`，提示用户："Dashboard UI 监听在 localhost，请通过 LAN 访问或配置防火墙放行 9090"。
- 或者提供一个**反向代理入口**（如 OPNsense 的 Web 代理子目录），但这会增加复杂度，至少应先给出口罩提示。

---

## 二、中优先级：用户体验与数据完整性

### 5. YAML 合并逻辑的复杂度与可维护性
文档明确"手写实现 merge，不用通用 deep-merge 库"，初期可控，但 Mihomo YAML 包含**锚点引用**（`&anchor` / `*alias`）、**复杂嵌套**（`proxy-providers`、`rule-providers`），手写字符串级合并极易出错。

**建议：**
- 使用 PHP 的 YAML 解析库（如 `Symfony\Component\Yaml` 或 PECL `yaml` 扩展，OPNsense 通常已装）将三份配置解析为数组，进行**结构化合并**，再序列化回 YAML。这样：
  - `proxy-groups` 的同名合并可精确控制字段级策略（override 的 `proxies` 列表追加，但 `type`/`url` 等元数据以 override 为准）。
  - `rules` 的 prepend/append 可通过数组操作精确实现，避免字符串拼接导致的缩进或注释丢失。
- 如果坚持手写，请在 `mihomo_lib.inc.php` 中为合并逻辑编写**单元测试级别的 PHP 脚本**（可在 install 时跑一遍验证），覆盖常见边界 case。

### 6. Profile 与 Subscription 的命名空间冲突
文档说"subs ↔ profile 一对一"，且 Name 同时作为 profile 名。但 Profiles Tab 支持"Create Empty"手动创建 profile。如果用户手动创建了名为 `airport-a` 的 profile，随后又添加了同名订阅，行为未定义。

**建议：**
- 明确规则：**订阅生成的 profile 前缀为 `sub-`**（如 `sub-airport-a`），手动创建的 profile 无前缀。或反之。
- 在 `subs.json` 和 `profiles/*.meta.json` 中增加 `source_type` 字段（`subscription` / `manual`），任何命名冲突时以用户手动创建的为准，并阻断订阅覆盖。

### 7. Health Check 的 UX 与性能边界
Dashboard 的 Health Check 对大量节点（>50）分批 10 并发，但：
- 200 个节点的检测可能需要 20-30 秒，"3 秒淡出"的结果提示太短。
- 所有检测走 `www` 用户权限的 PHP-FPM 进程，长时间占用连接池可能影响 OPNsense Web 界面响应。

**建议：**
- 结果改为**常驻显示**（非淡出），直到用户切换 Profile 或点击"Clear Results"。
- 增加**"Quick Check"模式**（仅检测前 10 个节点或仅检测 URL-Test 组内的节点），作为默认行为。Full Check 作为二级选项。
- 后端实现改为**异步队列**：Health Check 请求写入 `/tmp/mihomo-health.job`，由后台脚本（或 `actions_mihomo.conf` 的即时动作）执行，PHP 只轮询进度，避免阻塞 FPM。

### 8. Log 轮询的增量模式
当前每 5 秒 `tail -n 30`，如果 5 秒内产生 100 条日志，前端只能看到最新的 30 条，中间 70 条丢失，不利于排查瞬时故障。

**建议：**
- `status_mihomo_logs.php` 支持 `?offset=<bytes>` 参数，后端返回自该偏移量以来的**新增行** + 新的 offset。前端首次加载读 `?lines=30`，后续轮询用增量追加，实现类似 `tail -f` 的平滑体验。
- 增加**日志级别前端过滤**（文档已提及），但建议后端也支持 `?level=warning` 过滤，减少传输数据量。

### 9. DNS 端口冲突的显式检测
`dns.listen: 0.0.0.0:53` 与 OPNsense 默认 Unbound 冲突是新手最常见的配置错误。

**建议：**
- Settings > DNS 分组增加**冲突检测**：保存时若 `dns.listen` 包含 `:53`，检查系统是否有其他进程监听 53（`sockstat -4 -l | grep :53`），如有则弹出警告："Port 53 is already in use by Unbound. Consider using 5353 with NAT redirect, or disable Unbound on this interface."
- 默认 `dns.listen` 建议改为 `127.0.0.1:5353`（或保留 53 但增加醒目提示），与 Unbound 的 `127.0.0.1:5355` 形成区分。

### 10. Updates 回滚机制的完整性
内核更新有完善的备份+回滚，但 GeoIP 和 UI 更新的回滚策略较简略。

**建议：**
- GeoIP 更新：替换前 `cp Country.mmdb Country.mmdb.bak.<ts>`，更新失败自动恢复。
- UI 更新：使用**目录级原子替换**（如 `mv ui ui.bak.<ts> && mv ui-new ui`），而非逐文件覆盖。更新失败可一键回滚。

---

## 三、低优先级：细节打磨与长期考量

### 11. 实时流量统计的速率计算
Dashboard 显示 `↑ 12.3MB /s`，但 `/traffic` 端点返回的是**累计值**。需要确认 `status_mihomo_traffic.php` 是否负责计算差分速率，还是前端负责。

**建议：**
- 由后端计算速率更可靠：PHP 将上次读取的累计值和时间戳暂存到 `/tmp/mihomo-traffic-state.json`，下次请求时计算 `(current - last) / deltaT`，返回 `{upRate, downRate, upTotal, downTotal}`。前端只负责显示，避免浏览器标签页切换/休眠导致的时间计算失真。

### 12. 订阅刷新状态的精确感知
"按钮灰显 + 轮询 `subs.json.last_update` 变化时恢复"存在边界问题：如果刷新失败，`last_update` 不会变化，按钮将永远灰显（或需要前端设置一个硬超时）。

**建议：**
- `sub.sh` 执行时写入 `/tmp/mihomo-sub-<id>.pid` 或更新 `subs.json` 中的 `last_status: "updating"`。前端轮询 `last_status`，看到 `done` 或 `failed` 即恢复按钮，并显示失败原因。

### 13. `find-process-mode` 的 FreeBSD 限制
文档提到 `strict` 在 FreeBSD 上可能失效，已有 tooltip 说明，很好。建议更进一步：

**建议：**
- 在 Settings 表单中，如果用户选择 `strict` 或 `always`，前端弹出**温和的非阻塞提示**（banner 或 tooltip）："FreeBSD 的进程查找支持有限，TUN 模式下通常不需要此选项即可正常工作。"
- 后端保存时若检测到 `strict`，在 `mihomo.log` 中增加一条启动提示，帮助用户排查。

### 14. 国际化（gettext）的加载机制
OPNsense 的 Web 服务器（lighttpd + PHP-FPM）对 `.mo` 文件有缓存。install.sh 复制 `.mo` 后，可能需要重启 Web 服务或清除 OPcache 才能生效。

**建议：**
- `install.sh` 在复制 `.mo` 后执行 `killall -USR1 php-fpm`（优雅重启 FPM）或提供说明要求用户重启 Web GUI。
- 所有 PHP 文件在 `gettext()` 前显式调用 `bindtextdomain('mihomo', '/usr/local/share/locale')`，确保域正确绑定。

### 15. 公共库 `mihomo_lib.inc.php` 的远期拆分
当前设计为单文件公共库，初期合理。但随着 Override 合并逻辑、API 调用、订阅管理、GitHub Release 检查等逻辑膨胀，单文件可能超过 1000 行。

**建议：**
- 保持当前单文件设计，但在文件内用清晰的注释区块划分（`// === CONFIG ===`、`// === API ===`、`// === MERGE ===`），为将来拆分为 `mihomo_config.inc.php`、`mihomo_api.inc.php` 等预留结构。

### 16. 旧 URL 跳转与 SEO/书签
"旧 URL `/services_mihomo.php` / `/sub.php` → 302 跳转到新页"很好。建议：

**建议：**
- 在 `mihomo_dashboard.php` 顶部增加一个**一次性横幅**（dismissible）："UI 已升级至新版本。原配置已自动迁移，如有问题请访问 Backup 页面恢复。" 持续 1-2 周，降低老用户的困惑。

### 17. 未明确支持的订阅格式边界
文档说支持 "Clash / Mihomo / V2Ray 格式"。V2Ray 订阅通常是 base64 编码的 VMess/VLESS 链接列表，与 Clash YAML 差异很大。

**建议：**
- 明确 `sub.sh` 的输入格式要求：**优先保证 Clash/Mihomo 原生 YAML 订阅的健壮性**。V2Ray 格式如果支持，需要引入转换逻辑（如 `subconverter` 或内置模板），这会增加体积和复杂度。如果首期不做，应在 UI 中明确提示："请使用 Clash/Mihomo 格式订阅链接，V2Ray 原生格式需自行转换"。

---

## 四、总结：最应优先落地的 3 项

如果资源有限，建议按以下顺序强化设计：

1. **原子写入 + `mihomo -t` 验证覆盖所有修改路径**（Profile 切换、Override 保存、订阅刷新）——这是防止用户把服务配崩的最后防线。
2. **敏感文件权限 + 备份加密/脱敏**——OPNsense 是网关设备，安全基线必须高。
3. **GitHub API 缓存 + 可选 Token**——避免更新功能在真实使用场景中因速率限制而不可用。

整体而言，这份设计稿的**决策日志（Q1-Q11）**和**范围边界（Out of Scope）**写得尤为出色，能够有效防止项目蔓延。只要在上述安全与可靠性环节补上细节，实施风险会很低。

## GLM审查建议

这份设计稿非常详尽且专业，体现了对 OPNsense 框架限制、Mihomo 内核机制以及用户实际使用痛点的深刻理解。特别是“分层配置模型”和“Override 借鉴 OpenClash”的决策，直击当前各类代理工具 UI 的核心痛点。

以下是对该设计稿的详细审查意见与优化建议，按架构、交互、实现细节和风险点分类：

---

### 一、 核心架构与数据流（高优）

**1. Override 合并逻辑的明确化**
*   **现状**：1.5 节提到 `override 拆 head/tail`，但在 1.2 文件布局中只有一个 `override.yaml`。
*   **建议**：不推荐在文件系统层面拆分为 `override_head.yaml` 和 `override_tail.yaml`，这会增加用户的理解成本和文件管理复杂度。建议**在单一 `override.yaml` 内部采用约定的 Key**，例如：
    ```yaml
    prepend-rules: 
      - "..."
    append-proxies:
      - "..."
    prepend-proxy-groups: 
      - "..."
    # 其他顶层 key 直接深度覆盖
    dns:
      nameserver:
        - "..."
    ```
    这样用户只需维护一个文件，`mihomo_lib.inc.php` 中的 `mergeAll()` 按约定的 key 进行插入/覆盖即可。这也与 OpenClash 的 Override 逻辑保持心智模型一致。

**2. base.yaml 表单与未管辖字段的保留机制**
*   **现状**：3.2 节提到“表单 Save 时只更新管辖字段，未管辖字段保留不动”。
*   **风险**：OPNsense 原生的 `save()` 方法通常是整体序列化覆盖。如果用户在 YAML Tab 手动了高级字段，表单 Save 时若逻辑写不好容易丢失。
*   **建议**：在架构设计中明确：表单提交后，后端流程必须是 `读取现有 base.yaml` → `用表单值覆盖对应 key` → `写回 base.yaml`。切勿从零构建 base.yaml。

**3. PHP 短轮询的性能隐患**
*   **现状**：2.4 节 Dashboard 通过 PHP 代理 `/traffic` 和 `/memory`，2 秒轮询。
*   **风险**：Mihomo 的 `/traffic` 是典型的流式接口，PHP 使用 `stream_socket_client` 读取 1-2 帧即断开，意味着每 2 秒都要经历一次 TCP 建立 + HTTP 握手 + 认证 + 断开，并发多用户时对 PHP-FPM 和 Mihomo API 都是负担。
*   **建议**：
    *   Dashboard 页面增加**“暂停刷新”**机制，切到其他 Tab 或最小化浏览器时停止轮询（利用 `visibilitychange` 事件）。
    *   考虑首次加载只拉取一次静态总量，速度/流量速率由前端在两次轮询的差值中自行计算，减少 PHP 需要同时聚合三个接口的压力。

---

### 二、 页面与交互设计（中优）

**1. Dashboard：Active Profile 的 Refresh 交互**
*   **现状**：点击 Refresh Subscription 后，按钮灰显，轮询 `subs.json.last_update` 变化时恢复。
*   **风险**：如果抓取失败（网络超时、机场报错），`last_update` 可能不更新，导致按钮一直灰显卡死。
*   **建议**：改为轮询 `subs.json` 中的 `last_status` 字段（如 `running` / `success` / `failed`），并设定最大轮询次数（如 60 次 * 2 秒 = 2 分钟超时），超时或收到 `failed` 立即恢复按钮并 Toast 提示失败。

**2. Configuration - Tab 6：Updates 的前端体验**
*   **现状**：下载 → 校验 → 替换 → 重启，后端执行时间可能长达几十秒。
*   **建议**：Update 按钮点击后，UI 必须进入明确的“不可中断状态”（如整块变成 Spinner + "Updating, please wait..."），并使用长轮询或后台任务状态检测，绝不能让用户在内核替换期间二次点击或离开页面导致状态不一致。

**3. Backup：Merge 逻辑的边界**
*   **现状**：4.3 节提到 Import 的 Merge 模式：`subs.json` 按 id 合并，`base.yaml` 整文件覆盖。
*   **疑问**：如果选择 Merge，`base.yaml` 整文件覆盖其实是一个“全量覆盖”行为，不符合“保留不在备份中的现有项”的直觉。
*   **建议**：对于 `base.yaml`，Merge 模式应该表现为“深度合并（Deep Merge）”，即备份里的键值覆盖当前的，当前独有的键值保留。如果实现太复杂，建议在 UI 上明确提示“Base 配置将被完全替换”，避免用户产生错觉。

**4. Subscriptions：关键词过滤的作用域**
*   **现状**：5.3 节定义了 `Include Keyword` 和 `Exclude Keyword`。
*   **建议**：在 UI 的 Tooltip 中明确说明过滤的作用域（通常是仅针对 `proxies` 节点名生效，还是也影响 `proxy-groups`？）。参考 OpenClash，建议**仅过滤 proxies**，如果剔除的节点属于某个 proxy-group 的正则/掩码范围，group 会自动失效，这是符合预期的。

---

### 三、 工程与向后兼容（中优）

**1. 迁移脚本 (migrate.sh) 的兜底**
*   **现状**：6.2 节中，迁移失败时“保留旧 config.yaml 不动，UI 显示横幅”。
*   **建议**：既然 UI 已经重写，如果迁移失败，新 UI 是无法正常工作的（因为找不到 base.yaml 等结构）。建议在 `install.sh` 阶段，如果 `migrate.sh` 失败，除了保留旧文件，还应**拒绝注册新菜单/拒绝启动新 PHP 页面**，或者在新 UI 顶部增加强拦截硬错误，引导用户手动处理或通过 SSH 回滚，避免用户进入一个半残的新 UI。

**2. Cron 任务的锁机制**
*   **现状**：5.5 节统一每小时跑 `sub_cron.sh` 遍历到期订阅。
*   **建议**：`sub_cron.sh` 必须实现文件锁（如 `flock -n`）。如果机场响应慢，上一次 cron 还没跑完，新的一小时又触发了，容易导致并发写入 `profiles/*.yaml` 造成配置损坏。

**3. Status API 的路由冲突**
*   **现状**：1.3 节扩展 `status_mihomo.php` 返回 pid + uptime。
*   **注意**：需检查 OPNsense 现有框架是否占用了 `/api/mihomo/*` 路由。OPNsense 较新版本倾向于将 API 放在 `/api/` 下，老插件放在 `www/` 下。如果此插件未来要支持 OPNsense API 导出，建议现在就把只读接口规划到 `/api/mihomo/status` 等路径下。

---

### 四、 风险点补充

1.  **mihomo 热重载的规则丢失问题**：Mihomo 的 `PUT /configs?force=true` 在某些版本下（特别是涉及 TUN 和 DNS 变更时）并不稳定，可能会短暂断网。设计稿中的“失败 fallback 到 restart”很好，但建议增加一个**静默延迟**：reload 后等待 1-2 秒再验证状态，避免因为状态检查太快误判为失败而触发不必要的 restart。
2.  **GeoIP 热重载 API**：1.5.1 提到 GeoIP 走 `PUT /configs/geo` 热重载，这在 mihomo 的某些版本中可能不被支持或需要附带特定参数，实施前务必针对当前最新版 Mihomo 实测该 API 的可用性，不可用的话只能走完整 reload。

---

### 五、 小修正与细节打磨

*   **目录结构笔误**：1.2 节中 `sub/sub.log` 和 5.4 节的 `stdout/stderr 写 sub.log`，但 5.2 节底部写的是复用 `status_sub_logs.php`，需确认 log 的真实路径，通常 OPNsense 的日志规范建议输出到 `syslog` 或 `/var/log/mihomo_sub.log`，而不是写在 `/usr/local/etc/mihomo/sub/` 下（违背 FHS 文件系统层级标准，etc 目录不应放动态日志）。
*   **端口冲突检测**：3.2 节 General 表单中，保存时应增加 OPNsense 常用端口（如 80, 443, 22, 8443）的冲突警告，特别是 `mixed-port` 或 `external-controller` 如果设为了 OPNsense WEB GUI 占用的端口，会导致失联。

### 总结
这份设计稿质量极高，逻辑闭环完整，特别是“极简 Dashboard + 完整 External UI”的克制设计非常符合 OPNsense 的系统哲学。只需在 **Override 文件结构规范、PHP 轮询性能管控、以及后台长耗时任务的前端状态锁定** 这三个方向稍作补强，即可进入 spec 定稿和开发阶段。