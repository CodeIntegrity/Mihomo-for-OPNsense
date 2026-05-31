# 仪表盘「运行状态」设计 — 替换最近日志卡

- 日期：2026-05-31
- 参考：[OpenClash](https://github.com/vernesong/OpenClash) `luci-app-openclash/luasrc/view/openclash/myip.htm`（运行状态 / IP 地址查询页）
- 状态：设计已确认，待转实施计划

## 目标

把仪表盘第 4 张卡「最近日志」替换为 OpenClash 风格的「运行状态」卡，包含两部分：

1. **出口 IP**：经 Mihomo 代理查询外部 geo-IP 服务，显示代理出口的公网 IP + 国家/ISP，反映「流量是否已被代理改变出口」。
2. **访问检查**：经代理并发探测固定站点集，显示连通性（正常/拒绝/超时）与延迟（毫秒，按阈值着色）。

日志在 Configuration → 日志 tab 已有独立入口，移除仪表盘日志卡不丢失任何功能。

## 关键架构决策

| 决策点 | 选择 | 理由 |
| --- | --- | --- |
| 检查执行侧 | **服务端经代理** | 真实反映「流量经 Mihomo 能否通」；复用 `DashboardController` 既有的 PHP 端 curl 模式；不依赖管理员浏览器自身网络。不做 OpenClash 的 browser/router 双模式切换——浏览器模式在透明代理场景价值低。 |
| IP 显示 | **出口公网 IP + 地理位置** | 「我是否已被代理」的核心信号。带前端隐私遮罩开关。 |
| 检查站点 | **沿用 OpenClash 默认集**：百度、网易云音乐、GitHub、YouTube | 国内+国际混合，固定列表、零配置，能同时看出直连与代理两条路径是否正常。 |

不引入 configd action、不写 Python、不提权——全部在 PHP 控制器内用 curl 完成，与现有 `trafficAction` 同级。

## 数据流

```
浏览器 (dashboard.volt JS, 轮询)
  → GET /api/mihomo/dashboard/egressIp      ← 出口 IP + 地理位置 (30s 轮询)
  → GET /api/mihomo/dashboard/accessCheck   ← 4 站点连通性 + 延迟 (15s 轮询)
      └─ DashboardController (PHP)
           └─ proxiedCurl()，CURLOPT_PROXY = 127.0.0.1:7890  ← 流量真正经 Mihomo
                ├─ egressIp:   curl 经代理打 geo-IP 服务，拿公网 IP + 国家/ISP
                └─ accessCheck: curl_multi 经代理并发打 4 站点，量 HTTP 码 + 毫秒
```

代理端口默认 7890（见 CLAUDE.md 端口表），从 config.xml 读 `mixed_port`/`http_port` 兜底。

## API 端点契约

### `GET /api/mihomo/dashboard/egressIp`

经代理 curl 一个 geo-IP 服务（主 `https://api.ip.sb/geoip`，超时 5s）。后端把上游 JSON 归一化为下列固定字段，上游字段名变化不外泄到前端契约。

- 成功：`{ "ok": true, "ip": "1.2.3.4", "country": "Japan", "isp": "Akamai" }`
  - `country`/`isp` 从上游响应映射；任一缺失时返回空串，前端按空处理。
- 失败（代理不通 / 服务超时）：`{ "ok": false, "error": "proxy connect failed" }`
  - 前端显示「—」，**不伪造数据**（Debug-First，失败显式暴露）。
- 隐私遮罩纯前端处理（eye 图标 toggle + `localStorage`），后端永远返回真值。

### `GET /api/mihomo/dashboard/accessCheck`

用 `curl_multi_*` 并发探测 4 站点，每站点 `CURLOPT_NOBODY`（HEAD）或限 1 字节，超时 5s，只取 HTTP 状态码 + `CURLINFO_TOTAL_TIME`。

站点固定集：

| key | name | host |
| --- | --- | --- |
| baidu | 百度 | www.baidu.com |
| netease | 网易云音乐 | music.163.com |
| github | GitHub | github.com |
| youtube | YouTube | www.youtube.com |

返回：

```json
{ "results": [
  { "key": "baidu",   "name": "百度",      "ok": true,  "status": 200, "ms": 42 },
  { "key": "youtube", "name": "YouTube",  "ok": false, "status": 0,   "ms": null }
] }
```

- `ok` 判定：HTTP 状态码 < 400 且 curl 无错误。
- 延迟分级阈值（沿用 OpenClash）：绿 ≤500ms / 黄 ≤1000ms / 橙 >1000ms；失败为红。前端着色。
- 两端点均为 GET、无副作用、无用户输入参数（站点集硬编码），故**无需** `actions_mihomo.conf` 正则校验（该校验只约束 configd 入参）。

## 前端卡片

替换 `dashboard.volt` 258–268 行的日志卡，复用现有 `.mihomo-card` 样式，内部分两区：

```
┌─ 运行状态 ──────────────────────── [眼睛图标] [刷新图标] ┐
│  出口 IP                                                  │
│    1.2.3.4   ·   Japan / Akamai                          │
│  ───────────────────────────────────────────────────    │
│  访问检查                                                  │
│    百度       ● 正常    42 ms                             │
│    网易云音乐  ● 正常    88 ms                             │
│    GitHub     ● 正常   320 ms                             │
│    YouTube    ● 超时     —                                │
└──────────────────────────────────────────────────────────┘
```

- **出口 IP 区**：一行 IP + 地理位置。眼睛图标遮罩 IP（`***.***.***.***`），状态存 `localStorage`，沿用 OpenClash 交互。
- **访问检查区**：4 行，每行 `● 正常/拒绝/超时` + 毫秒，圆点与毫秒按阈值着色。
- **刷新图标**：手动立即重测两区。

### 轮询

复用现有 `poller()`（指数退避 + `visibilitychange` 暂停，`dashboard.volt:312`）：

- `egressIp`：30s 轮询（出口 IP 不常变）。
- `accessCheck`：15s 轮询（服务端实测比前端探测稳定，无需 OpenClash 的随机抖动）。
- 两个 poller 一并加入 `visibilitychange` 的 stop/resume（`dashboard.volt:535`），页面隐藏即停，省代理流量。

## 改动范围

| 文件 | 改动 |
| --- | --- |
| `DashboardController.php` | 新增 `egressIpAction()`、`accessCheckAction()` |
| `MihomoFileTrait.php` | 新增 `proxiedCurl()` 辅助（curl + `CURLOPT_PROXY`）；新增读代理端口的小工具 |
| `dashboard.volt` | 替换日志卡 HTML；删 `logPoller`（527 行）、`.mihomo-log` 样式（82–94 行）、`#log-tail`；新增两区渲染 JS + 两个 poller + 隐私遮罩 |

**保留**：`logsAction`（Configuration 日志 tab 仍在用）、`tailLines`。

## 验证计划

1. PHP 语法：`php -l` 两个改动文件。
2. 部署到服务器（`upload`），`configd` 无关（未碰 configd）。
3. Chrome MCP 冒烟：导航 `/ui/mihomo/dashboard`，`take_snapshot` 看运行状态卡渲染；`list_network_requests` 验证 `egressIp`/`accessCheck` 两请求状态码与响应体。
4. 边界：停掉 mihomo 服务时，两端点应返回 `ok:false`，前端显示「—」/「超时」而非报错或伪造。

## 非目标（YAGNI）

- 不做 browser/router 双模式切换。
- 不做站点列表自定义（不碰 Mihomo.xml / 表单 / reconfigure）。
- 不做直连 IP 对比。
- 不动日志后端逻辑。
