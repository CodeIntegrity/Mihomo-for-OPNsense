# YAML 语法高亮 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 为 Configuration 页「覆写」Tab(可编辑)、「YAML」Tab(只读)、Profiles「查看 YAML」动作引入 CodeMirror 5 YAML 语法高亮。

**Architecture:** CodeMirror 5.65.21 资源 vendored 进仓库命名空间子目录,经 install.sh 部署到 `/usr/local/opnsense/www/mihomo/codemirror/`,浏览器经 lighttpd 既有 `/ui/` alias 访问。configuration.volt 顶部引入三资源,用工厂函数实例化两个常驻 CM(override 可编辑 / composed 只读)与一个 profiles 按需弹窗实例;读写从 `$.val()` 切到 `cm.getValue()/setValue()`;隐藏 Tab 显示时 `refresh()` 撑开。后端 YAML 校验保持不变(单一真相源)。

**Tech Stack:** CodeMirror 5(vanilla `<script>`)、OPNsense jQuery、BootstrapDialog(平台自带,ControllerBase 全局加载)、Volt 模板、POSIX sh(install/uninstall)、Python unittest(契约测试)。

**设计依据:** [docs/superpowers/specs/2026-05-31-yaml-syntax-highlight-design.md](../specs/2026-05-31-yaml-syntax-highlight-design.md)

---

## 已核实的代码库事实(实现者必读)

- `/ui/` → `/usr/local/opnsense/www/` 由 lighttpd `alias.url` 提供(无需改 web server)。
- `cache_safe()` 是 OPNsense 核心 Volt helper(非本仓库定义),用于带缓存破坏哈希引用静态资源。
- `BootstrapDialog` 在所有 MVC 页面全局可用(`ControllerBase.php` 加载 `bootstrap-dialog.min.js`,`default.volt` 已使用),**无需**额外 `<script>` 引入。
- configuration.volt 当前读写两个目标 textarea 的位置(行号基于编写时快照,实现时以实际为准):
  - `loadOverride` (595-599)、`btn-override-save` (600-605)、`btn-override-validate` (606-)→ `#override-content`
  - `loadComposedYaml` (621-625)、`btn-yaml-copy` (627-630)、`btn-yaml-download` (631-638)→ `#composed-yaml`
  - profiles viewYaml 回调 (565):`function(d) { alert(d.content || d.message); }`
- install.sh 顶部变量:`WWW_DIR="$ROOT/www"`(即 `/usr/local/www`,**核心 legacy 目录,不是本功能目标**);MVC 部署在 122 行 `cp -R -f ./src/opnsense/mvc/app/. "$MVC_DIR/"`。本功能目标路径是 `/usr/local/opnsense/www/mihomo/`,需新增变量,**禁止复用 `WWW_DIR`**。
- uninstall.sh MVC 清理块在 102-104 行(`rm -rf .../mvc/app/.../Mihomo`)。
- `tests/test_contracts.py` 已存在,断言 install.sh 文本内容(如 `chmod` 行)。
- override.yaml 上限 1 MiB(OverrideController.php:40);profile / composed YAML 经 `readFileBounded` 上限 5 MiB(MihomoFileTrait.php:126)。

---

## 文件结构

| 文件 | 责任 | 动作 |
| --- | --- | --- |
| `src/opnsense/www/mihomo/codemirror/codemirror.min.js` | CM5 核心 | 新建(vendored) |
| `src/opnsense/www/mihomo/codemirror/codemirror.min.css` | CM5 样式 | 新建(vendored) |
| `src/opnsense/www/mihomo/codemirror/yaml.min.js` | YAML mode | 新建(vendored) |
| `src/opnsense/www/mihomo/codemirror/LICENSE` | MIT 协议 | 新建(vendored) |
| `src/opnsense/www/mihomo/codemirror/PROVENANCE.txt` | 来源/版本/SHA256/提取步骤 | 新建 |
| `install.sh` | 部署 CM 资源到 `/usr/local/opnsense/www/mihomo/` | 修改 |
| `uninstall.sh` | 清理 `/usr/local/opnsense/www/mihomo` | 修改 |
| `src/.../Mihomo/configuration.volt` | 引入资源 + 实例化 + 读写切换 + refresh + 弹窗 | 修改 |
| `tests/test_contracts.py` | 断言 install/uninstall 含 CM 部署/清理步骤 | 修改 |

---

## Task 1: Vendor CodeMirror 5.65.21 资源并记录来源

**Files:**
- Create: `src/opnsense/www/mihomo/codemirror/codemirror.min.js`
- Create: `src/opnsense/www/mihomo/codemirror/codemirror.min.css`
- Create: `src/opnsense/www/mihomo/codemirror/yaml.min.js`
- Create: `src/opnsense/www/mihomo/codemirror/LICENSE`
- Create: `src/opnsense/www/mihomo/codemirror/PROVENANCE.txt`

- [ ] **Step 1: 创建目录**

```bash
mkdir -p src/opnsense/www/mihomo/codemirror
```

- [ ] **Step 2: 下载并提取固定版本资源**

从官方 release 提取 CodeMirror 5.65.21 的三个文件。在有网环境执行(防火墙设备本身无需联网):

```bash
cd /tmp
curl -fsSL -o cm.tgz https://registry.npmjs.org/codemirror/-/codemirror-5.65.21.tgz
tar xzf cm.tgz
# package/ 内含已发布的 min 文件
cp package/lib/codemirror.js   /tmp/cm-codemirror.js
cp package/lib/codemirror.css  /tmp/cm-codemirror.css
cp package/mode/yaml/yaml.js   /tmp/cm-yaml.js
cp package/LICENSE             /tmp/cm-LICENSE
```

注:npm 包内 `lib/codemirror.js` 为未压缩版。本任务直接采用未压缩文件但命名保留 `.min.js` 后缀以匹配引用路径,或用任意 JS minifier 压缩。**关键是记录实际采用的来源与处理方式到 PROVENANCE.txt**。为简化与可复现,推荐直接采用 GitHub release 的预构建产物:

```bash
# 备选:从 GitHub release zip 取预构建 min 文件
curl -fsSL -o cm5.zip https://github.com/codemirror/codemirror5/archive/refs/tags/5.65.21.zip
unzip -o cm5.zip
# 5.65.21 仓库 lib/ 下含 codemirror.js/codemirror.css;mode/yaml/yaml.js
```

- [ ] **Step 3: 放置文件到仓库**

将提取的三文件与 LICENSE 复制到仓库目录:

```bash
cd <repo-root>
cp /tmp/cm-codemirror.js  src/opnsense/www/mihomo/codemirror/codemirror.min.js
cp /tmp/cm-codemirror.css src/opnsense/www/mihomo/codemirror/codemirror.min.css
cp /tmp/cm-yaml.js        src/opnsense/www/mihomo/codemirror/yaml.min.js
cp /tmp/cm-LICENSE        src/opnsense/www/mihomo/codemirror/LICENSE
```

- [ ] **Step 4: 计算 SHA256 并写 PROVENANCE.txt**

```bash
cd src/opnsense/www/mihomo/codemirror
sha256sum codemirror.min.js codemirror.min.css yaml.min.js
```

将输出写入 `PROVENANCE.txt`,内容模板(填入实际哈希):

```text
CodeMirror vendored assets — provenance
========================================
Version: 5.65.21
Upstream: https://github.com/codemirror/codemirror5 (tag 5.65.21)
Package:  https://registry.npmjs.org/codemirror/-/codemirror-5.65.21.tgz
License:  MIT (see ./LICENSE)

Extracted files:
  codemirror.min.js  <- lib/codemirror.js
  codemirror.min.css <- lib/codemirror.css
  yaml.min.js        <- mode/yaml/yaml.js

Minify: <实际处理方式,如 "上游预构建,未二次压缩" 或所用命令>

SHA256:
  codemirror.min.js   <hash>
  codemirror.min.css  <hash>
  yaml.min.js         <hash>
```

- [ ] **Step 5: 校验文件非截断**

```bash
# codemirror.js 应以 CodeMirror UMD 头开始,文件大小 > 100KB
wc -c src/opnsense/www/mihomo/codemirror/codemirror.min.js
head -c 80 src/opnsense/www/mihomo/codemirror/codemirror.min.js
# yaml.js 应引用 CodeMirror.defineMode("yaml", ...)
grep -c 'defineMode' src/opnsense/www/mihomo/codemirror/yaml.min.js
```

Expected: codemirror 文件 > 100000 字节;yaml.js `defineMode` 计数 ≥ 1。

- [ ] **Step 6: Commit**

```bash
git add src/opnsense/www/mihomo/codemirror/
git commit -m "feat: vendor CodeMirror 5.65.21 用于 YAML 语法高亮"
```

---

## Task 2: install.sh 部署 CM 资源

**Files:**
- Modify: `install.sh`(顶部变量区 ~14-29 行;MVC 部署段 ~122-126 行)

- [ ] **Step 1: 新增目标路径变量**

在 install.sh 变量定义区(`MVC_DIR=...` 行之后)新增:

```sh
OPN_WWW_DIR="$ROOT/opnsense/www"
```

放在 `MVC_DIR="$ROOT/opnsense/mvc/app"` 之后,保持同组就近。

- [ ] **Step 2: 新增资源部署步骤**

在 MVC 部署段(`run_or_die cp -R -f ./src/opnsense/scripts/mihomo/. "$SCRIPTS_DIR/"` 与其后 `chmod` 之间,即资源拷贝逻辑处)新增。定位锚点为 122-124 行的 cp 段落,在 124 行之后插入:

```sh
# 部署前端静态资源(CodeMirror 语法高亮)
mkdir -p "$OPN_WWW_DIR/mihomo"
run_or_die cp -R -f ./src/opnsense/www/mihomo/. "$OPN_WWW_DIR/mihomo/"
```

- [ ] **Step 3: 校验脚本语法**

Run: `sh -n install.sh`
Expected: 无输出(语法正确),退出码 0。

- [ ] **Step 4: 确认部署语句存在(为 Task 9 契约测试预演)**

```bash
grep -n 'OPN_WWW_DIR' install.sh
grep -n 'cp -R -f ./src/opnsense/www/mihomo' install.sh
```

Expected: 两条均有匹配。

- [ ] **Step 5: Commit**

```bash
git add install.sh
git commit -m "feat: install.sh 部署 CodeMirror 资源到 opnsense/www/mihomo"
```

---

## Task 3: uninstall.sh 清理 CM 资源

**Files:**
- Modify: `uninstall.sh`(MVC 清理块 ~102-104 行附近)

- [ ] **Step 1: 新增清理步骤**

在 uninstall.sh 删除 MVC views 之后(104 行 `rm -rf /usr/local/opnsense/mvc/app/views/OPNsense/Mihomo` 之后)新增:

```sh
# 删除前端静态资源(CodeMirror)
rm -rf /usr/local/opnsense/www/mihomo
```

- [ ] **Step 2: 校验脚本语法**

Run: `sh -n uninstall.sh`
Expected: 无输出,退出码 0。

- [ ] **Step 3: 确认清理语句存在**

```bash
grep -n 'rm -rf /usr/local/opnsense/www/mihomo' uninstall.sh
```

Expected: 1 条匹配。

- [ ] **Step 4: Commit**

```bash
git add uninstall.sh
git commit -m "feat: uninstall.sh 清理 CodeMirror 资源目录"
```

---

## Task 4: configuration.volt 引入 CM 资源与 CSS

**Files:**
- Modify: `src/opnsense/mvc/app/views/OPNsense/Mihomo/configuration.volt`(顶部 11 行 `<style>` 之前;CSS 块 15-27 行 `.mihomo-yaml-edit`)

- [ ] **Step 1: 在文件最顶部(第 1 行 `{#` 注释块之前)引入资源**

在文件最开头插入三行资源引用:

```volt
<link rel="stylesheet" type="text/css" href="{{ cache_safe('/ui/mihomo/codemirror/codemirror.min.css') }}"/>
<script src="{{ cache_safe('/ui/mihomo/codemirror/codemirror.min.js') }}"></script>
<script src="{{ cache_safe('/ui/mihomo/codemirror/yaml.min.js') }}"></script>
```

顺序固定:CSS → 核心 JS → yaml mode(yaml.js 依赖核心先加载)。

- [ ] **Step 2: 调整 CSS,让 CM 容器继承固定高度与浅色外观**

在 `<style>` 块内,`.mihomo-yaml-edit { ... }` 规则(15-27 行)之后新增 CM 容器样式:

```css
.CodeMirror {
    height: 420px;
    border: 1px solid #ccc;
    font-family: monospace;
    font-size: 12px;
}
.CodeMirror-scroll { min-height: 420px; }
```

保留原 `.mihomo-yaml-edit`(textarea 被 CM 接管后隐藏,但 profiles 弹窗等可能复用类名;不删以免误伤)。

- [ ] **Step 3: 部署到服务器并冒烟验证资源 200**

```bash
# 经 SSH upload configuration.volt 与 codemirror 资源目录(见 Task 8 完整部署)
# 本步骤先验证资源可达
```

用 Chrome DevTools MCP:
- `navigate_page` → `https://<opnsense>/ui/mihomo/configuration#override`
- `list_network_requests` → 确认 `codemirror.min.css` / `codemirror.min.js` / `yaml.min.js` 均 **200**

Expected: 三资源 HTTP 200(非 404)。若 404,查 install.sh cp 路径与服务器 `/usr/local/opnsense/www/mihomo/` 实际内容。

- [ ] **Step 4: Commit**

```bash
git add src/opnsense/mvc/app/views/OPNsense/Mihomo/configuration.volt
git commit -m "feat: configuration.volt 引入 CodeMirror 资源与容器样式"
```

---

## Task 5: 实例化常驻 CM 并接管 override / composed 读写

**Files:**
- Modify: `src/opnsense/mvc/app/views/OPNsense/Mihomo/configuration.volt`(JS `$(function(){...})` 内,420-441 行 routing 区与 594-638 行读写区)

- [ ] **Step 1: 新增工厂函数与两个常驻实例**

在 `$(function() { 'use strict';` 之后、hash routing 之前(约 422-424 行之间)插入:

```javascript
    // ----- CodeMirror 实例 -----
    function makeCM(textareaId, readOnly) {
        return CodeMirror.fromTextArea(document.getElementById(textareaId), {
            mode: 'yaml',
            lineNumbers: true,
            lineWrapping: true,
            readOnly: readOnly
        });
    }
    var cmOverride = makeCM('override-content', false);
    var cmComposed = makeCM('composed-yaml', true);
```

不设 `viewportMargin`(沿用默认 10);固定高度由 CSS 提供。

- [ ] **Step 2: override 读写切到 cmOverride**

将 `loadOverride`(595-599)改为:

```javascript
    function loadOverride() {
        $.get('/api/mihomo/override/get').done(function(j) {
            cmOverride.setValue((j && j.content) || '');
        });
    }
```

将 `btn-override-save` 内 `$.post` 的 content 取值(602 行)`$('#override-content').val()` 改为 `cmOverride.getValue()`:

```javascript
        $.post('/api/mihomo/override/set', {content: cmOverride.getValue()}).done(function(d) {
```

将 `btn-override-validate` 内(608 行)同样 `$('#override-content').val()` 改为 `cmOverride.getValue()`:

```javascript
        $.post('/api/mihomo/override/validate', {content: cmOverride.getValue()}).done(function(d) {
```

- [ ] **Step 3: composed 读取与复制/下载切到 cmComposed**

将 `loadComposedYaml`(621-625)改为:

```javascript
    function loadComposedYaml() {
        $.get('/api/mihomo/override/composedYaml').done(function(j) {
            cmComposed.setValue((j && j.content) || (j && j.message) || '');
        });
    }
```

将 `btn-yaml-copy`(627-630)改为用 CM 取值并写剪贴板:

```javascript
    $('#btn-yaml-copy').click(function() {
        var text = cmComposed.getValue();
        if (navigator.clipboard && navigator.clipboard.writeText) {
            navigator.clipboard.writeText(text);
        } else {
            var ta = document.createElement('textarea');
            ta.value = text; document.body.appendChild(ta);
            ta.select(); document.execCommand('copy'); ta.remove();
        }
    });
```

将 `btn-yaml-download`(631-638)内取值(632 行)`$('#composed-yaml').val()` 改为 `cmComposed.getValue()`:

```javascript
        var blob = new Blob([cmComposed.getValue() || ''], {type: 'text/yaml'});
```

- [ ] **Step 4: 隐藏 Tab 显示时 refresh(撑开塌缩的编辑器)**

将 `onTabShown`(433-441)中 yaml / override 两条改为:

```javascript
        if (tab === 'yaml')          { loadComposedYaml(); cmComposed.refresh(); }
        if (tab === 'override')      { loadOverride();     cmOverride.refresh(); }
```

其余 5 行保持不变。

- [ ] **Step 5: 部署并功能验证(override 可编辑)**

经 SSH upload configuration.volt(见 Task 8)。用 Chrome DevTools MCP:
- `navigate_page` → `/ui/mihomo/configuration#override`
- `take_snapshot` → 确认编辑器撑开(非窄缝)、有行号、YAML 染色
- `list_console_messages` → 无 `CodeMirror is not defined` 等报错
- 编辑内容 → 点保存 → `list_network_requests` 看 `/api/mihomo/override/set` 请求体 content 非空 → 响应 status ok
- 点校验 → 确认走 `/api/mihomo/override/validate`(后端校验未被前端取代)

Expected: 编辑器正常渲染;保存请求携带实际内容;校验仍走后端。

- [ ] **Step 6: 功能验证(YAML 只读)**

- `navigate_page` → `/ui/mihomo/configuration#yaml`
- `take_snapshot` → 染色显示、不可编辑
- 点复制 / 下载 → 确认取到内容(下载请求或剪贴板非空)

Expected: 只读染色;复制/下载取到 composed 内容。

- [ ] **Step 7: 回归验证**

- 依次切换其余 6 个 Tab(settings/subscriptions/profiles/log/updates/backup),`list_console_messages` 无新报错
- 刷新页面停在 `#override`,确认 hash 路由恢复且编辑器已 refresh 撑开(非塌缩)

Expected: 无回归;hash 路由 + refresh 正常。

- [ ] **Step 8: Commit**

```bash
git add src/opnsense/mvc/app/views/OPNsense/Mihomo/configuration.volt
git commit -m "feat: override/composed YAML 区接管为 CodeMirror 高亮编辑器"
```

---

## Task 6: Profiles「查看 YAML」改为 CM 只读弹窗(含防注入)

**Files:**
- Modify: `src/opnsense/mvc/app/views/OPNsense/Mihomo/configuration.volt`(profiles viewYaml 回调 565 行)

- [ ] **Step 1: 新增弹窗辅助函数**

在 `loadProfiles` 函数之前(约 541 行之前)插入辅助函数,**用 DOM API 创建 textarea 节点,禁止 HTML 字符串拼接**:

```javascript
    // 只读 CM 弹窗展示 YAML(纯文本语义,防 HTML 注入)
    function showYamlDialog(title, content) {
        var ta = document.createElement('textarea');  // DOM 创建,不拼 HTML
        BootstrapDialog.show({
            title: title,
            message: ta,                               // 传 DOM 节点而非字符串
            size: BootstrapDialog.SIZE_WIDE,
            onshown: function(dialog) {
                dialog.cmTmp = CodeMirror.fromTextArea(ta, {
                    mode: 'yaml', lineNumbers: true, lineWrapping: true, readOnly: true
                });
                dialog.cmTmp.setValue(content);        // setValue 填充,非拼接
                dialog.cmTmp.refresh();
            },
            onhidden: function(dialog) {
                if (dialog.cmTmp) {
                    dialog.cmTmp.toTextArea();          // 销毁实例,还原 textarea、解绑事件
                    dialog.cmTmp = null;                // 置空引用,避免泄漏
                }
            },
            buttons: [{ label: '关闭', action: function(d) { d.close(); } }]
        });
    }
```

注:此处直接对已持有的 `ta` 元素调用 `CodeMirror.fromTextArea`,不复用 `makeCM` 工厂(工厂签名按 textareaId 取元素,这里持有的是元素本身)。

- [ ] **Step 2: 替换 viewYaml 回调**

将 565 行的 `function(d) { alert(d.content || d.message); }` 改为:

```javascript
                    function(d) {
                        if (d.status === 'ok') {
                            showYamlDialog('查看 YAML', d.content || '');
                        } else {
                            BootstrapDialog.show({
                                title: '查看 YAML',
                                message: d.message || 'failed'
                            });
                        }
                    }));
```

注意:原 565 行以 `}));` 结尾闭合 `$cmds.append(' ', actionBtn(...))`。替换时保留外层 `actionBtn(... )` 与 `$cmds.append` 的括号结构,仅替换 onOk 回调实参。

- [ ] **Step 3: 部署并功能验证(正常用例)**

经 SSH upload。Chrome DevTools MCP:
- `navigate_page` → `/ui/mihomo/configuration#profiles`
- 点某 profile 的「查看 YAML」按钮(`click`)
- `take_snapshot` → 弹窗内 CM 只读染色显示 YAML
- 关闭弹窗 → 再次打开 → `list_console_messages` 无报错(确认实例销毁未残留)

Expected: 弹窗只读染色;反复开关无报错。

- [ ] **Step 4: 对抗性验证(防注入)**

在服务器构造一个含注入文本的 profile(只读测试数据):

```bash
# 经 SSH execute-command
printf '%s\n' '# test' '</textarea><script>window.__xss=1</script>' \
  > /usr/local/etc/mihomo/profiles/xsstest.yaml
chown root:www /usr/local/etc/mihomo/profiles/xsstest.yaml
```

- `navigate_page` 刷新 profiles → 点 xsstest 的「查看 YAML」
- `take_snapshot` → 确认 `</textarea><script>...` 按**纯文本原样显示**在 CM 内
- `evaluate_script` 执行 `return window.__xss === undefined` → 确认脚本**未执行**(返回 true)
- 清理:`rm -f /usr/local/etc/mihomo/profiles/xsstest.yaml`

Expected: 注入文本纯文本显示;`window.__xss` 未定义(脚本未执行)。

- [ ] **Step 5: Commit**

```bash
git add src/opnsense/mvc/app/views/OPNsense/Mihomo/configuration.volt
git commit -m "feat: Profiles 查看 YAML 改为 CodeMirror 只读弹窗,setValue 填充防注入"
```

---

## Task 7: 契约测试断言部署/清理步骤

**Files:**
- Modify: `tests/test_contracts.py`

- [ ] **Step 1: 阅读现有测试结构**

```bash
grep -n 'def read\|class .*Test\|def test_' tests/test_contracts.py | head -30
```

确认 `read()` helper 与现有 install.sh 断言测试的写法(参照 `test_php_writable_mihomo_paths_keep_group_write`)。

- [ ] **Step 2: 新增契约测试**

在合适的测试类内(与现有 install/uninstall 断言同类)新增:

```python
    def test_codemirror_assets_deployed_and_cleaned(self):
        install = read("install.sh")
        uninstall = read("uninstall.sh")
        # install 部署 CM 资源到 opnsense/www/mihomo,且不复用核心 WWW_DIR
        self.assertIn('OPN_WWW_DIR="$ROOT/opnsense/www"', install)
        self.assertIn('cp -R -f ./src/opnsense/www/mihomo', install)
        # uninstall 清理资源目录
        self.assertIn('rm -rf /usr/local/opnsense/www/mihomo', uninstall)

    def test_configuration_volt_uses_codemirror(self):
        view = read("src/opnsense/mvc/app/views/OPNsense/Mihomo/configuration.volt")
        # 引入资源
        self.assertIn('/ui/mihomo/codemirror/codemirror.min.js', view)
        self.assertIn('/ui/mihomo/codemirror/yaml.min.js', view)
        # 读写已切到 CM API(不再用 textarea .val() 读这两个目标)
        self.assertIn('cmOverride.getValue()', view)
        self.assertIn('cmComposed.setValue', view)
        # profiles 弹窗用 setValue 填充,杜绝 alert(d.content)
        self.assertIn('showYamlDialog', view)
        self.assertNotIn('alert(d.content', view)
```

注:`read()` 的路径基准以现有测试为准(若现有测试用相对仓库根路径,沿用之)。

- [ ] **Step 3: 运行测试**

Run: `python3 -m pytest tests/test_contracts.py -v`(若仓库用 unittest:`python3 -m unittest tests.test_contracts -v`)
Expected: 新增两个测试 PASS,既有测试不回归。

- [ ] **Step 4: Commit**

```bash
git add tests/test_contracts.py
git commit -m "test: 契约断言 CodeMirror 部署/清理与 volt 集成"
```

---

## Task 8: 端到端部署与完整冒烟

**Files:** 无代码改动(部署 + 验证)

- [ ] **Step 1: 部署全部改动到服务器**

经 SSH upload(本地权威 → 服务器测试):
- `configuration.volt` → `/usr/local/opnsense/mvc/app/views/OPNsense/Mihomo/`
- CM 资源目录 → `/usr/local/opnsense/www/mihomo/codemirror/`(模拟 install.sh 的 cp 步骤)

```bash
# 经 ssh execute-command 确认目录
mkdir -p /usr/local/opnsense/www/mihomo/codemirror
# upload 四个资源文件到该目录
ls -la /usr/local/opnsense/www/mihomo/codemirror/
```

- [ ] **Step 2: 静态语法终检**

```bash
sh -n install.sh uninstall.sh
php -l src/opnsense/mvc/app/views/OPNsense/Mihomo/configuration.volt 2>/dev/null || echo "volt 非纯 PHP,跳过 php -l"
python3 -m pytest tests/test_contracts.py -v
```

Expected: sh 语法 0;契约测试全绿。

- [ ] **Step 3: 三资源 200 验证**

Chrome DevTools MCP:`navigate_page` → `/ui/mihomo/configuration#override`,`list_network_requests` 确认 codemirror.min.css/js + yaml.min.js 均 200。

- [ ] **Step 4: 全功能走查**

按 spec 第 4 节逐项:
- Override:加载→染色→编辑→保存(content 非空)→校验走后端
- YAML:切 Tab→染色→复制/下载取值→不可编辑
- Profiles:查看 YAML 弹窗只读染色;对抗用例纯文本显示、脚本不执行;反复开关无报错
- 回归:6 个 Tab 无破坏;hash 路由 + refresh 正常

- [ ] **Step 5: 验证总结**

记录每项 PASS/FAIL 证据(网络状态码、snapshot、console 无报错)。若任一 FAIL,按 spec「验证失败处理」定位(404 查 cp 路径/alias;塌缩查 refresh 时机),不引入兜底掩盖。

---

## Self-Review(编写后自查结果)

**1. Spec 覆盖:**
- 资源 vendoring + PROVENANCE/SHA256 → Task 1 ✓
- install.sh 部署(新增变量,不复用 WWW_DIR)→ Task 2 ✓
- uninstall.sh 清理 → Task 3 ✓
- Volt 引入资源 + CSS → Task 4 ✓
- 工厂函数 + 两常驻实例 + 6 处读写切换 + onTabShown refresh → Task 5 ✓
- Profiles 弹窗 + 防注入(DOM textarea + setValue)+ toTextArea 销毁 → Task 6 ✓
- 后端校验保持单一真相源 → Task 5 Step 2(validate 仍走后端)✓
- 验证含 sh -n + 契约测试 + 对抗用例 → Task 7、Task 6 Step 5、Task 8 ✓

**2. 占位符扫描:** 无 TBD/TODO。PROVENANCE 模板中 `<hash>` / `<实际处理方式>` 是必须由实现者填入的真实运行时产物(SHA256 无法预先写死),非计划占位缺陷。

**3. 类型/命名一致性:** `cmOverride` / `cmComposed` / `makeCM` / `showYamlDialog` / `OPN_WWW_DIR` / `dialog.cmTmp` 跨任务命名一致。Task 6 弹窗实例直接用 `CodeMirror.fromTextArea(ta, ...)`(持有元素),不复用按 id 取元素的 `makeCM` 工厂,已在 Task 6 Step 1 注明。

**4. 已知注意点:** 行号基于编写时快照,实现时以 grep 实际定位为准(计划已在「已核实事实」标注)。
