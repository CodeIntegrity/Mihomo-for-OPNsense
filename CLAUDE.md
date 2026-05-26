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
