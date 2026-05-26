## Mihomo for OPNsense

在 OPNsense 上运行 Mihomo，实现透明代理。提供独立的 Web UI 进行配置、订阅、备份与服务管理。在 OPNsense 26.1.6 + x86_64 上测试通过。

![](images/proxy.png)

## 集成程序

[Vincent-Loeng 大佬魔改 Mihomo](https://github.com/Vincent-Loeng/mihomo)

## 功能特性（v2 UI 重设计）

- **分层配置模型**：`config.yaml = merge(base, override, profile)`，订阅刷新不会覆盖用户自定义片段
- **多订阅 + Profile 切换**：支持多个订阅源，激活单一 Profile，订阅生成的 Profile 强制 `sub-` 前缀
- **Dashboard 极简面板**：服务状态、流量速率、连接数、内存、日志尾部一屏显示
- **结构化 Settings 表单**：约 40 个高频字段表单化（General/External Controller/TUN/DNS/Sniffer/Auto Update），替代裸 YAML 编辑
- **资源在线更新**：Mihomo 内核 / GeoIP / Dashboard UI 三类资源一键更新，内核更新失败自动回滚
- **导入导出备份**：支持 AES-256-CBC 加密备份与 Overwrite/Merge 导入策略
- **中文国际化**：基于 gettext，提供 zh_CN 翻译
- **配置原子写入**：所有 config.yaml 修改路径走 `atomicConfigUpdate()`（写 tmp → `mihomo -t` 校验 → mv 覆盖 → 热重载）
- **并发写入保护**：`lockedWrite()` + `flock()` 防止 Cron 与 Web UI 同时写入截断文件

## 菜单结构

```text
VPN > Mihomo
├── Dashboard          落地页：状态/流量/日志
├── Configuration      6 Tab 单页：
│   ├── Settings           base.yaml 表单
│   ├── Override           override.yaml 编辑器
│   ├── Profiles           Profile 列表 + 切换 + 激活
│   ├── YAML               当前 config.yaml 只读
│   ├── Log                mihomo.log 查看 + 过滤
│   └── Updates            内核/GeoIP/UI 在线更新
├── Backup             导入/导出/加密备份
└── Subscriptions      订阅源 CRUD + Cron 自动刷新
```

## 注意事项

1. 当前仅支持 x86_64 平台。
2. 脚本不提供任何订阅信息，请准备好自己的订阅 URL。
3. 安装脚本会自动添加 tun 接口、防火墙规则，修改 Unbound DNS 端口为 5355，重启服务并应用配置。
4. 脚本已集成可用的默认配置，添加订阅后即可使用。
5. 为减少长期运行保存的日志数量，调试完成后请将日志级别改为 `warning` 或 `error`。

## 安装命令

```bash
sh install.sh
```

首次安装会自动执行 [migrate.sh](migrate.sh)，将旧版单文件 `config.yaml` 拆分为 `base.yaml + override.yaml + profiles/`。迁移幂等，失败会保留旧文件不动并拒绝注册新菜单。

## 卸载命令

```bash
sh uninstall.sh
```

## 配置过程

1. 安装完成后，检查 **接口 > 分配**，`tun_3000` 虚拟网卡是否已添加为接口并启用（无需 IPv4 地址和网关）。
2. 检查 **服务 > Unbound DNS** 监听端口是否已修改为 5355（避免与 Mihomo 53 端口冲突）。
3. 检查 **防火墙 > 规则**，`tun` 接口是否有 `any to any` 规则放行 tun 子网。
4. 导航到 **VPN > Mihomo > Subscriptions**，添加订阅源并刷新生成 Profile。
5. 进入 **Configuration > Profiles**，激活 Profile（写入 `config.yaml` 并热重载）。
6. 回到 **Dashboard** 启动服务，客户端访问 [ip111.cn](https://ip.skk.moe/) 验证分流。

## 端口分配

| 端口 | 服务 |
| ---- | ---- |
| 53 | Mihomo DNS 劫持入口 |
| 5355 | Unbound DNS（OPNsense 默认 DNS） |
| 7890 | Mihomo HTTP 代理 |
| 7891 | Mihomo SOCKS5 代理 |
| 9090 | Mihomo API / Dashboard UI |

## 其他事项

1. 经测试 OPNsense 的 Mihomo 配置 `tun.stack` 参数只能使用 `gvisor` 栈。
2. 默认开启 External Controller，访问 `http://<lan_ip>:9090/ui` 登录内嵌 Dashboard（可在 Configuration > Updates 中切换 zashboard / metacubexd / yacd）。
3. 订阅自动刷新由 configd action `sub-update` 通过 cron 触发，间隔在 Subscriptions 页按订阅配置。
4. 从旧版升级后，旧 URL `/services_mihomo.php` 和 `/sub.php` 会 302 跳转到新页面，旧书签仍可用。
