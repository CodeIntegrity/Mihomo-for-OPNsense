# YAML 语法高亮 — 设计文档

- **日期**: 2026-05-31
- **范围**: Configuration 页「覆写」Tab(可编辑)、「YAML」Tab(只读)、Profiles「查看 YAML」动作
- **目标**: 为 YAML 编辑/查看区域提供语法高亮,提升可读性

## 背景与约束

当前「覆写」「YAML」两个 Tab 的编辑区均为纯 `<textarea>`(`#override-content` 可编辑、`#composed-yaml` 只读),Profiles 的「查看 YAML」用原生 `alert(d.content)` 展示。三处均无任何语法高亮。

关键约束:

- OPNsense 26.1.8 自带前端库中**无任何语法高亮库**(已核查:无 CodeMirror / Prism / Ace / highlight.js;仅有 jQuery / Bootstrap / Chart.js / d3 / tabulator)。
- 项目 CLAUDE.md 约定「vanilla JS + jQuery,无外部框架」。本功能经用户明确同意后引入 CodeMirror,作为该约束的一次受控例外。
- 防火墙设备通常无出站公网,CDN 不可用 → 资源必须 vendored 进仓库。
- 插件当前**不附带任何前端静态资源**,`install.sh` 也无 JS/CSS 拷贝步骤 → 需新建资源目录与部署步骤。

## 决策汇总

| 决策点 | 选定方案 |
| --- | --- |
| 高亮库 | CodeMirror 5.65.21(固定版本,最后的非模块化稳定版,纯 `<script>` 加载) |
| 覆盖范围 | 覆写 Tab(可编辑)+ YAML Tab(只读)+ Profiles 查看 YAML(只读弹窗) |
| 配色主题 | 浅色(跟随页面,与现有 `#f5f5f5` textarea 及 OPNsense 亮色界面一致) |
| 长行处理 | 自动折行(`lineWrapping: true`) |
| 部署位置 | 命名空间子目录 `/usr/local/opnsense/www/mihomo/codemirror/`,核心目录零侵入 |

## 1. 资源 vendoring 与部署

仓库新增静态资源目录(插件首次引入前端资源):

```
src/opnsense/www/mihomo/codemirror/
├── codemirror.min.js      # CM5 核心 (~140KB)
├── codemirror.min.css     # 核心样式 (~10KB)
├── yaml.min.js            # YAML mode (~2KB)
├── LICENSE                # CM5 MIT 协议原文
└── PROVENANCE.txt         # 版本/来源/SHA256/提取步骤,保证可复现
```

选用 **CodeMirror 5.65.21**(固定到具体版本,非 `5.65.x` 区间)。这是最后一个稳定的非模块化版本,纯 `<script>` 标签即可加载,无需打包器,契合「vanilla JS + jQuery」约束。

**可复现性要求**(记录于 `PROVENANCE.txt`):
- 上游来源:从官方 release tarball `https://github.com/codemirror/codemirror5/archive/refs/tags/5.65.21.tar.gz` 提取(或 npm `codemirror@5.65.21`)。
- 提取路径:`lib/codemirror.js` + `lib/codemirror.css` + `mode/yaml/yaml.js`。
- minify 步骤:记录所用工具与命令(如直接取上游已发布的 `.min.js`,或本地 minify 命令)。
- 每个 vendored 文件记录 **SHA256**,便于后续核验未被截断或篡改。
- LICENSE 来源:CM5 仓库根 `LICENSE`(MIT)。

部署链路:

- `install.sh`:新增一步,将 `./src/opnsense/www/mihomo` 拷贝到 `/usr/local/opnsense/www/mihomo/`,与现有 `cp -R ./src/opnsense/mvc/app/.` 等步骤并列。注意:install.sh 现有的 `WWW_DIR="$ROOT/www"` 指向 `/usr/local/www`(OPNsense 核心 legacy 目录),**不是**本功能的目标路径;需新增指向 `/usr/local/opnsense/www` 的目标,不可复用 `WWW_DIR`。
- lighttpd 已有 `alias.url += ("/ui/" => "/usr/local/opnsense/www/")`,浏览器经 `/ui/mihomo/codemirror/...` 访问,**无需改 web server 配置**。
- `uninstall.sh`:新增 `rm -rf /usr/local/opnsense/www/mihomo`(与现有 `rm -rf` 模式一致)。

此链路对 OPNsense 核心目录零侵入,核心升级不冲突,卸载干净。

## 2. Volt 前端集成

资源引入(configuration.volt 顶部,`<style>` 块之前):

```volt
<link rel="stylesheet" type="text/css" href="{{ cache_safe('/ui/mihomo/codemirror/codemirror.min.css') }}"/>
<script src="{{ cache_safe('/ui/mihomo/codemirror/codemirror.min.js') }}"></script>
<script src="{{ cache_safe('/ui/mihomo/codemirror/yaml.min.js') }}"></script>
```

`yaml.min.js` 依赖 `codemirror.min.js` 先加载,`<script>` 顺序固定如上。

三处实例化统一封装工厂函数:

```js
function makeCM(textareaId, readOnly) {
    return CodeMirror.fromTextArea(document.getElementById(textareaId), {
        mode: 'yaml',
        lineNumbers: true,
        lineWrapping: true,
        readOnly: readOnly
    });
}
```

不设 `viewportMargin: Infinity`,沿用 CM 默认值(10)。理由:`.CodeMirror` 固定高度 420px(见第 3 节),只渲染视口内行即可;而 profiles / composed YAML 经 `readFileBounded` 上限达 5 MiB(MihomoFileTrait.php:126),`Infinity` 会强制渲染整篇大文档,与限高视口矛盾且劣化性能。CM 的虚拟滚动在默认值下已能流畅处理大文件。

- `#override-content`(可编辑)→ `cmOverride = makeCM('override-content', false)`
- `#composed-yaml`(只读)→ `cmComposed = makeCM('composed-yaml', true)`
- Profiles「查看 YAML」→ BootstrapDialog 弹窗内挂临时 CM 只读实例,替换原 `alert(d.content)`

**安全约束(防 HTML 注入)**:profile YAML 内容来自订阅,不可信。原 `alert(d.content)` 按纯文本显示,无注入风险;改 BootstrapDialog 后必须保持等价的纯文本语义。**强制要求**:先用 DOM API 创建空 `<textarea>` 作为 dialog message 节点,再 `cmTmp.setValue(d.content)` 填充内容;**禁止**任何形如 `message: '<textarea>' + d.content + '</textarea>'` 的字符串拼接 HTML,否则订阅内容中的 `</textarea><script>` 等文本会被解析为 HTML。

**关键改动:读写改走 CM 实例而非 textarea**。CodeMirror 隐藏原 `<textarea>` 并接管,故所有 `$('#override-content').val(...)` / `.val()` 必须改为 `cmOverride.setValue(...)` / `cmOverride.getValue()`。涉及位置:

- 可编辑侧:`loadOverride`、`btn-override-save`、`btn-override-validate`(3 处)→ `cmOverride`
- 只读侧:`loadComposedYaml`、`btn-yaml-copy`、`btn-yaml-download`(3 处)→ `cmComposed`

这是本次最易遗漏点,实现时逐一核对,否则会读到空字符串。

## 3. 初始化时机与错误处理

**核心陷阱:CodeMirror 在隐藏 Tab 中初始化会塌缩**。覆写 / YAML 两 Tab 初始 `display:none`,`fromTextArea` 创建时测不到尺寸,显示为窄缝,需在 Tab 显示时 `.refresh()`。复用现有 `onTabShown(tab)` 调度器(configuration.volt:433):

```js
if (tab === 'yaml')     { loadComposedYaml(); cmComposed.refresh(); }
if (tab === 'override') { loadOverride();     cmOverride.refresh(); }
```

实例化时机:`$(function(){...})` 内一次性创建两个常驻实例(DOM 就绪,textarea 隐藏 → 创建后塌缩,靠首次 `onTabShown` 的 `refresh()` 撑开)。Profiles 弹窗实例按需创建,`BootstrapDialog` 的 `onshown` 回调里 `refresh()`,关闭时销毁。

错误处理(Debug-First,不静默兜底):

- 不为「CodeMirror 未定义」加 try/catch 回退到纯 textarea。资源加载失败时,让 `CodeMirror is not defined` 在 console 显式报错——这是部署问题,应暴露而非掩盖。
- YAML 语法校验**不归 CM 管**:override 的「校验」按钮仍走后端 `/api/mihomo/override/validate`(Python py-yaml 权威解析)。CM 只染色,不做语法正确性判断,避免前端弱解析与后端产生第二套真相。

CSS 调整:现有 `.mihomo-yaml-edit` 的固定高度规则改挂到 CM 容器(`.CodeMirror`),保留 `height:420px` + 浅色背景,视觉与现状一致。

## 4. 测试与验证

静态检查:

- `sh -n install.sh uninstall.sh` 校验两个脚本语法(本功能新增了 cp / rm 步骤)。
- `python3 -m pytest tests/test_contracts.py`(或仓库既有运行方式)跑安装脚本契约测试,确认新增的资源部署/清理步骤未破坏现有断言;若需要,补充覆盖 `www/mihomo` 部署与卸载的契约断言。
- Volt 改动无独立 lint,靠部署后页面实际渲染验证。
- 核验 vendored 三文件的 SHA256 与 `PROVENANCE.txt` 一致(非截断、非篡改),`yaml.min.js` 在 `codemirror.min.js` 之后加载。

部署 + 冒烟测试(SSH upload + Chrome DevTools MCP):

1. `upload` 改动文件(configuration.volt + 新建 www/mihomo/codemirror/ 资源 + install.sh / uninstall.sh)
2. 手动 `cp -R` 资源到 `/usr/local/opnsense/www/mihomo/`(模拟 install.sh 那步)
3. Chrome MCP `navigate_page` → `/ui/mihomo/configuration#override`
4. `list_network_requests` 验证三个 CM 资源返回 **200**(非 404,确认 `/ui/` alias 映射)
5. `list_console_messages` 确认无 `CodeMirror is not defined` 等报错
6. `take_snapshot` / `take_screenshot` 确认编辑器撑开(非塌缩)、有行号、染色生效

逐项功能验证:

- Override:加载现有内容 → 染色 → 编辑 → 保存(确认 `getValue()` 取到值而非空)→ 校验按钮仍走后端
- YAML 只读:切到 Tab → 染色 → 复制 / 下载取到内容 → 确认不可编辑
- Profiles:点「查看 YAML」→ 弹窗内只读染色(替换原 alert)
- 回归:切其他 6 个 Tab 确认无破坏;刷新页面 hash 路由(`#override`)仍能恢复并 refresh

验证失败处理:资源 404 先查 install.sh 的 cp 路径与 lighttpd alias;编辑器塌缩查 `refresh()` 时机。不引入兜底掩盖问题。

## 不做的事(YAGNI)

- 不引入代码折叠、括号匹配、自动补全等 CM 高级插件(仅核心 + yaml mode)。
- 不做前端 YAML 语法校验(保持后端单一真相源)。
- 不为旧版 OPNsense 或非 x86_64 做兼容。
- 不改 Profiles 之外其他使用 `alert()` 的位置。
