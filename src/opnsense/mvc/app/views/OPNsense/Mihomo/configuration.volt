{#
 # Mihomo Configuration — 8 Tabs in one page.
 #
 # Settings | Subscriptions | Profiles | Override | YAML | Log | Updates | Backup
 #
 # All tabs share the global Apply button (top-right) that fires
 # /api/mihomo/service/reconfigure. The button only enables when the
 # underlying ApiMutableModel reports `dirty` (handled by base_apply_button).
#}

<style>
    .mihomo-tab-content { padding-top: 14px; }
    #backup .content-box { padding: 16px 20px; }
    #backup .content-box > h4:first-child { margin-top: 0; }
    .mihomo-yaml-edit {
        display: block;
        width: 100%;
        max-width: 100%;
        height: 420px;
        font-family: monospace;
        font-size: 12px;
        background: #f5f5f5;
        color: #333;
        border: 1px solid #ccc;
        resize: vertical;
        box-sizing: border-box;
    }
    .mihomo-log {
        display: block;
        width: 100%;
        max-width: 100%;
        height: 360px;
        font-family: monospace;
        font-size: 12px;
        background: #f5f5f5;
        color: #333;
        border: 1px solid #ccc;
        resize: vertical;
        box-sizing: border-box;
    }
    .update-badge.is-up-to-date { background: #e8f5e9; color: #2e7d32; }
    .update-badge.is-has-update { background: #fff3e0; color: #e65100; }
    .update-badge.is-unknown     { background: #f5f5f5; color: #999; }
    .update-badge.is-error       { background: #fce4e4; color: #c62828; }
    .update-status-msg.is-error { color: #d9534f; }
    .update-status-msg.is-ok    { color: #5cb85c; }
    .update-status-msg.is-info  { color: #337ab7; }
</style>

<ul class="nav nav-tabs" role="tablist" id="mihomo-tabs">
    <li class="active"><a data-toggle="tab" href="#settings">设置</a></li>
    <li><a data-toggle="tab" href="#subscriptions">订阅</a></li>
    <li><a data-toggle="tab" href="#profiles">配置档</a></li>
    <li><a data-toggle="tab" href="#override">覆写</a></li>
    <li><a data-toggle="tab" href="#yaml">YAML</a></li>
    <li><a data-toggle="tab" href="#log">日志</a></li>
    <li><a data-toggle="tab" href="#updates">更新</a></li>
    <li><a data-toggle="tab" href="#backup">备份</a></li>
</ul>

<div class="tab-content content-box">

    {# ---------------- Tab 1: Settings ---------------- #}
    <div id="settings" class="tab-pane fade in active mihomo-tab-content">
        <ul class="nav nav-pills" role="tablist" id="mihomo-settings-subtabs">
            <li class="active"><a data-toggle="pill" href="#sub-general">常规</a></li>
            <li><a data-toggle="pill" href="#sub-controller">外部控制器</a></li>
            <li><a data-toggle="pill" href="#sub-tun">TUN</a></li>
            <li><a data-toggle="pill" href="#sub-dns">DNS</a></li>
            <li><a data-toggle="pill" href="#sub-sniffer">嗅探</a></li>
            <li><a data-toggle="pill" href="#sub-update">自动更新</a></li>
        </ul>

        <div class="tab-content content-box" style="border-top: none; padding-top: 14px;">
            <div id="sub-general" class="tab-pane fade in active">
                {{ partial('layout_partials/base_form', {'fields': formGeneral, 'id': 'frm_general'}) }}
            </div>
            <div id="sub-controller" class="tab-pane fade">
                {{ partial('layout_partials/base_form', {'fields': formController, 'id': 'frm_controller'}) }}
            </div>
            <div id="sub-tun" class="tab-pane fade">
                {{ partial('layout_partials/base_form', {'fields': formTun, 'id': 'frm_tun'}) }}
            </div>
            <div id="sub-dns" class="tab-pane fade">
                {{ partial('layout_partials/base_form', {'fields': formDns, 'id': 'frm_dns'}) }}
            </div>
            <div id="sub-sniffer" class="tab-pane fade">
                {{ partial('layout_partials/base_form', {'fields': formSniffer, 'id': 'frm_sniffer'}) }}
            </div>
            <div id="sub-update" class="tab-pane fade">
                {{ partial('layout_partials/base_form', {'fields': formUpdate, 'id': 'frm_update'}) }}
            </div>
        </div>

        <div style="margin-top: 16px;">
            <button type="button" class="btn btn-primary" id="btn-save-settings">
                <i class="fa fa-save"></i> 保存设置
            </button>
            <span id="settings-save-msg" style="margin-left: 10px; color: #888;"></span>
        </div>
    </div>

    {# ---------------- Tab 2: Subscriptions ---------------- #}
    <div id="subscriptions" class="tab-pane fade mihomo-tab-content">
        <table id="grid-subscriptions" class="table table-condensed table-hover table-striped"
               data-editDialog="DialogSubscription" data-editAlertText="">
            <thead>
                <tr>
                    <th data-column-id="uuid" data-type="string" data-identifier="true" data-visible="false">UUID</th>
                    <th data-column-id="enabled" data-type="boolean" data-formatter="rowtoggle" data-width="6em">启用</th>
                    <th data-column-id="name" data-type="string">名称</th>
                    <th data-column-id="url" data-type="string">URL</th>
                    <th data-column-id="interval" data-type="string" data-width="8em">间隔（小时）</th>
                    <th data-column-id="last_update" data-type="string">上次更新</th>
                    <th data-column-id="last_status" data-type="string" data-width="8em">状态</th>
                    <th data-column-id="commands" data-formatter="commands" data-sortable="false" data-width="12em">
                        操作
                    </th>
                </tr>
            </thead>
            <tbody></tbody>
            <tfoot>
                <tr>
                    <td></td>
                    <td colspan="7">
                        <button type="button" data-action="add" class="btn btn-xs btn-default">
                            <span class="fa fa-plus"></span>
                        </button>
                        <button type="button" data-action="deleteSelected" class="btn btn-xs btn-default">
                            <span class="fa fa-trash"></span>
                        </button>
                    </td>
                </tr>
            </tfoot>
        </table>

        <h4 style="margin-top: 16px;">订阅日志</h4>
        <textarea class="mihomo-log" id="sub-log" readonly></textarea>
    </div>

    {# ---------------- Tab 3: Profiles ---------------- #}
    <div id="profiles" class="tab-pane fade mihomo-tab-content">
        <div style="margin-bottom: 10px;">
            <button type="button" class="btn btn-default" id="btn-create-empty">
                <i class="fa fa-plus"></i> 新建空配置档
            </button>
            <button type="button" class="btn btn-default" id="btn-profile-reload">
                <i class="fa fa-refresh"></i> 重新加载
            </button>
        </div>
        <table class="table table-condensed table-hover table-striped">
            <thead>
                <tr>
                    <th>名称</th>
                    <th>来源</th>
                    <th>节点数</th>
                    <th>最近更新</th>
                    <th>已激活</th>
                    <th>操作</th>
                </tr>
            </thead>
            <tbody id="profile-rows"></tbody>
        </table>
    </div>

    {# ---------------- Tab 4: Override ---------------- #}
    <div id="override" class="tab-pane fade mihomo-tab-content">
        <div class="alert alert-info" style="margin-bottom: 10px;">
            override.yaml 中的片段在订阅刷新后仍然保留。保留约定键：
            <code>prepend-rules</code>, <code>append-rules</code>,
            <code>append-proxies</code>,
            <code>prepend-proxy-groups</code>, <code>append-proxy-groups</code>.
            其它顶层键将深度合并到最终配置中。
        </div>
        <details style="margin-bottom: 10px;">
            <summary style="cursor:pointer;">示例</summary>
<pre style="background:#f5f5f5;padding:8px;border:1px solid #ddd;border-radius:4px;font-size:12px;">prepend-rules:
  - DOMAIN-SUFFIX,my-internal.lan,DIRECT

append-rules:
  - MATCH,Proxy

append-proxies:
  - name: my-private-vpn
    type: ss
    server: 1.2.3.4
    port: 8388

prepend-proxy-groups:
  - name: 🌍选择代理节点
    type: select
    proxies: [my-private-vpn]
</pre>
        </details>
        <textarea class="mihomo-yaml-edit" id="override-content" spellcheck="false"></textarea>
        <div style="margin-top: 10px;">
            <button type="button" class="btn btn-primary" id="btn-override-save">
                <i class="fa fa-save"></i> 保存覆写
            </button>
            <button type="button" class="btn btn-default" id="btn-override-validate">
                <i class="fa fa-check"></i> 仅校验
            </button>
            <button type="button" class="btn btn-danger" id="btn-override-reset">
                <i class="fa fa-undo"></i> 重置
            </button>
            <span id="override-msg" style="margin-left:10px;color:#888;"></span>
        </div>
    </div>

    {# ---------------- Tab 5: YAML (read-only) ---------------- #}
    <div id="yaml" class="tab-pane fade mihomo-tab-content">
        <div class="alert alert-warning" style="margin-bottom:10px;">
            此视图展示当前激活的 config.yaml（只读）。请通过 Settings / Override / Profiles 修改其源头。
        </div>
        <textarea class="mihomo-yaml-edit" id="composed-yaml" readonly spellcheck="false"></textarea>
        <div style="margin-top: 10px;">
            <button type="button" class="btn btn-default" id="btn-yaml-refresh">
                <i class="fa fa-refresh"></i> 刷新
            </button>
            <button type="button" class="btn btn-default" id="btn-yaml-copy">
                <i class="fa fa-copy"></i> 复制到剪贴板
            </button>
            <button type="button" class="btn btn-default" id="btn-yaml-download">
                <i class="fa fa-download"></i> 下载
            </button>
        </div>
    </div>

    {# ---------------- Tab 6: Log ---------------- #}
    <div id="log" class="tab-pane fade mihomo-tab-content">
        <div style="margin-bottom: 10px;">
            <label>行数:
                <select id="log-lines">
                    <option value="100">100</option>
                    <option value="200" selected>200</option>
                    <option value="500">500</option>
                    <option value="1000">1000</option>
                </select>
            </label>
            <label style="margin-left: 12px;">过滤:
                <select id="log-level">
                    <option value="">全部</option>
                    <option value="ERR">error</option>
                    <option value="WARN">warning</option>
                    <option value="INFO">info</option>
                    <option value="DEBUG">debug</option>
                </select>
            </label>
            <button type="button" class="btn btn-default btn-xs" id="btn-log-pause" style="margin-left:8px;">
                <i class="fa fa-pause"></i> 暂停自动刷新
            </button>
            <button type="button" class="btn btn-default btn-xs" id="btn-log-refresh">
                <i class="fa fa-refresh"></i> 刷新
            </button>
        </div>
        <textarea class="mihomo-log" id="mihomo-log-view" readonly></textarea>
    </div>

    {# ---------------- Tab 7: Updates ---------------- #}
    <div id="updates" class="tab-pane fade mihomo-tab-content">
        <div class="content-box">
            <table class="table table-striped table-condensed" style="margin-bottom:0;">
                <thead>
                    <tr>
                        <th>资源</th>
                        <th>当前版本</th>
                        <th>最新版本</th>
                        <th style="width:8em;">状态</th>
                        <th style="width:16em;">操作</th>
                    </tr>
                </thead>
                <tbody>
                    <tr data-resource="core">
                        <td><i class="fa fa-microchip"></i> <strong>Mihomo 内核</strong></td>
                        <td class="update-current">—</td>
                        <td class="update-latest">—</td>
                        <td><span class="update-badge label label-default">检查中...</span></td>
                        <td>
                            <button type="button" class="btn btn-xs btn-default btn-check">
                                <i class="fa fa-refresh"></i> 检查
                            </button>
                            <button type="button" class="btn btn-xs btn-primary btn-update" disabled>
                                <i class="fa fa-cloud-download"></i> 更新
                            </button>
                        </td>
                    </tr>
                    <tr data-resource="geoip">
                        <td><i class="fa fa-globe"></i> <strong>GeoIP 数据库</strong></td>
                        <td class="update-current">—</td>
                        <td class="update-latest">—</td>
                        <td><span class="update-badge label label-default">检查中...</span></td>
                        <td>
                            <button type="button" class="btn btn-xs btn-default btn-check">
                                <i class="fa fa-refresh"></i> 检查
                            </button>
                            <button type="button" class="btn btn-xs btn-primary btn-update" disabled>
                                <i class="fa fa-cloud-download"></i> 更新
                            </button>
                        </td>
                    </tr>
                    <tr data-resource="ui">
                        <td><i class="fa fa-desktop"></i> <strong>Dashboard 界面</strong></td>
                        <td class="update-current">—</td>
                        <td class="update-latest">—</td>
                        <td><span class="update-badge label label-default">检查中...</span></td>
                        <td>
                            <button type="button" class="btn btn-xs btn-default btn-check">
                                <i class="fa fa-refresh"></i> 检查
                            </button>
                            <button type="button" class="btn btn-xs btn-primary btn-update" disabled>
                                <i class="fa fa-cloud-download"></i> 更新
                            </button>
                        </td>
                    </tr>
                </tbody>
            </table>
            <div class="update-progress-wrap" style="display:none;padding:8px 12px;border-top:1px solid #eee;">
                <div class="progress" style="margin:0 0 6px 0;">
                    <div class="progress-bar progress-bar-striped active" style="width:0%;">
                        <span class="progress-text">0%</span>
                    </div>
                </div>
                <div class="update-status-msg" style="font-size:12px;"></div>
            </div>
        </div>
    </div>

    {# ---------------- Tab 8: Backup ---------------- #}
    <div id="backup" class="tab-pane fade mihomo-tab-content">
        <div class="content-box">
            <h4>导出配置</h4>
            <div class="alert alert-warning" style="margin-top:6px;">
                备份包含敏感数据（API 密钥、代理凭据），请妥善保管。
            </div>
            <div class="form-group">
                <label class="checkbox-inline">
                    <input type="checkbox" id="export-encrypt"> 使用 AES-256-CBC 加密
                </label>
            </div>
            <div class="form-group" id="export-password-row" style="display:none;">
                <label>密码 (≥ 8 chars):
                    <input type="password" id="export-password" class="form-control" style="display:inline-block;width:280px;margin-left:8px;">
                </label>
            </div>
            <button type="button" class="btn btn-primary" id="btn-export">
                <i class="fa fa-download"></i> 下载备份
            </button>
        </div>

        <div class="content-box" style="margin-top:16px;">
            <h4>导入配置</h4>
            <div class="form-group">
                <label>备份文件</label>
                <input type="file" id="import-file" name="file" accept=".tar.gz,.gz,.enc">
            </div>
            <div class="form-group">
                <label>冲突策略</label>
                <div>
                    <label class="radio-inline">
                        <input type="radio" name="strategy" value="overwrite" checked> 全部覆盖
                    </label>
                    <label class="radio-inline">
                        <input type="radio" name="strategy" value="merge"> 合并（保留本地额外条目）
                    </label>
                </div>
            </div>
            <div class="form-group">
                <label>密码（若已加密）
                    <input type="password" id="import-password" class="form-control" style="display:inline-block;width:280px;margin-left:8px;">
                </label>
            </div>
            <div class="form-group">
                <label class="checkbox-inline">
                    <input type="checkbox" id="import-restart"> 导入后重启 mihomo
                </label>
            </div>
            <button type="button" class="btn btn-primary" id="btn-import">
                <i class="fa fa-upload"></i> 导入备份
            </button>
            <span id="import-msg" style="margin-left:10px;color:#888;"></span>
        </div>

        <div class="content-box" style="margin-top:16px;">
            <h4>最近本地备份</h4>
            <table class="table table-condensed table-hover table-striped" style="margin-top:6px;">
                <thead>
                    <tr>
                        <th>文件</th>
                        <th>大小</th>
                        <th>修改时间</th>
                        <th>操作</th>
                    </tr>
                </thead>
                <tbody id="backup-rows"></tbody>
            </table>
        </div>

        <div class="content-box" style="margin-top:16px;">
            <h4>自动备份</h4>
            <p style="font-size:12px;color:#888;margin:0;">
                请在「设置 → 自动更新」中配置（auto_backup_on_override / auto_backup_on_profile_activate）。
            </p>
        </div>
    </div>

</div>

{# Apply button — global #}
<div style="margin-top: 16px;">
    {{ partial('layout_partials/base_apply_button', {'data_endpoint': '/api/mihomo/service/reconfigure'}) }}
</div>

{# Subscription edit dialog #}
{{ partial('layout_partials/base_dialog', {
    'fields': formDialogSubscription,
    'id': 'DialogSubscription',
    'label': '编辑订阅'
}) }}

<script>
$(function() {
    'use strict';

    // ----- Hash routing — preserve current tab across reloads -----
    var hash = window.location.hash || '#settings';
    $('#mihomo-tabs a[href="' + hash + '"]').tab('show');
    $('#mihomo-tabs a').on('shown.bs.tab', function(e) {
        history.replaceState(null, '', e.target.getAttribute('href'));
        var tab = e.target.getAttribute('href').substring(1);
        onTabShown(tab);
    });

    function onTabShown(tab) {
        if (tab === 'profiles')      loadProfiles();
        if (tab === 'yaml')          loadComposedYaml();
        if (tab === 'log')           loadLogTail(true);
        if (tab === 'override')      loadOverride();
        if (tab === 'backup')        loadBackupList();
        if (tab === 'subscriptions') loadSubLog();
        if (tab === 'updates')       loadAllUpdateStates();
    }

    // ----- Tab 1: Settings -----
    var SETTINGS_API = '/api/mihomo/settings/';
    function loadSettings() {
        // Pre-populate the interface dropdown with choices so setFormData
        // can set the saved value against valid options.
        $.get(SETTINGS_API + 'get').done(function(data) {
            var choices = data && data.mihomo && data.mihomo._interface_choices;
            if (choices && choices.length) {
                var $sel = $('[id="mihomo.general.interface_name"]');
                $sel.empty();
                choices.forEach(function(c) {
                    $sel.append($('<option>', {value: c.value, text: c.label}));
                });
            }
        }).always(function() {
            mapDataToFormUI({
                'frm_general':    SETTINGS_API + 'get',
                'frm_controller': SETTINGS_API + 'get',
                'frm_tun':        SETTINGS_API + 'get',
                'frm_dns':        SETTINGS_API + 'get',
                'frm_sniffer':    SETTINGS_API + 'get',
                'frm_update':     SETTINGS_API + 'get'
            }).done(function() {});
        });
    }
    loadSettings();

    $('#btn-save-settings').click(function() {
        var $msg = $('#settings-save-msg');
        $msg.text('保存中...');
        // Collect form data via getFormData (OPNsense uses id-attrs, not name-attrs).
        var allData = {};
        ['frm_general', 'frm_controller', 'frm_tun', 'frm_dns', 'frm_sniffer', 'frm_update'].forEach(function(id) {
            $.extend(true, allData, getFormData(id));
        });
        $.post(SETTINGS_API + 'set', $.param(allData)).done(function(response) {
            if (response && response.result === 'saved') {
                $msg.text('已保存').css('color', '#5cb85c');
            } else {
                $msg.text((response && response.message) ? response.message : '保存失败').css('color', '#d9534f');
            }
        }).fail(function() {
            $msg.text('保存失败').css('color', '#d9534f');
        });
    });

    // ----- Tab 2: Subscriptions -----
    // Event delegation on the stable tab-pane (#subscriptions) — UIBootgrid
    // replaces #grid-subscriptions during init, so binding on it would lose
    // the handler.  The parent tab-pane survives the swap.
    $('#subscriptions').on('click', '.mihomo-sub-refresh', function() {
        var $btn = $(this);
        var uuid = $btn.data('row-id');
        $btn.prop('disabled', true).find('span').removeClass('fa-cloud-download').addClass('fa-spinner fa-spin');
        $.ajax({
            url: '/api/mihomo/subscriptions/refresh/' + encodeURIComponent(uuid),
            method: 'POST'
        }).done(function(r) {
            if (r.status !== 'ok') {
                alert(r.message || 'refresh failed');
            }
        }).fail(function() {
            alert('refresh request failed');
        }).always(function() {
            setTimeout(function() {
                $('#grid-subscriptions').bootgrid('reload');
                loadSubLog();
            }, 1500);
        });
    });
    $('#grid-subscriptions').UIBootgrid({
        search:  '/api/mihomo/subscriptions/searchItem/',
        get:     '/api/mihomo/subscriptions/getItem/',
        set:     '/api/mihomo/subscriptions/setItem/',
        add:     '/api/mihomo/subscriptions/addItem/',
        del:     '/api/mihomo/subscriptions/delItem/',
        toggle:  '/api/mihomo/subscriptions/toggleItem/',
        options: {
            requestHandler: function(req) { return req; },
            formatters: {
                commands: function(column, row) {
                    return  '<button type="button" class="btn btn-xs btn-default bootgrid-tooltip mihomo-sub-refresh" '
                          + 'data-row-id="' + row.uuid + '" title="立即刷新">'
                          + '<span class="fa fa-cloud-download fa-fw"></span></button>'
                          + ' <button type="button" class="btn btn-xs btn-default bootgrid-tooltip command-edit" '
                          + 'data-row-id="' + row.uuid + '"><span class="fa fa-pencil fa-fw"></span></button>'
                          + ' <button type="button" class="btn btn-xs btn-default bootgrid-tooltip command-delete" '
                          + 'data-row-id="' + row.uuid + '"><span class="fa fa-trash-o fa-fw"></span></button>';
                }
            }
        }
    });
    function loadSubLog() {
        $.get('/api/mihomo/subscriptions/log?lines=200').done(function(j) {
            $('#sub-log').val((j && j.logs) || '');
        });
    }

    // ----- Tab 3: Profiles -----
    function loadProfiles() {
        $.get('/api/mihomo/profiles/searchItem').done(function(j) {
            var $tbody = $('#profile-rows').empty();
            (j.rows || []).forEach(function(p) {
                var $tr = $('<tr>');
                $tr.append('<td><strong>' + escapeHtml(p.name) + '</strong></td>');
                $tr.append('<td>' + (p.source_type === 'subscription'
                    ? '<span class="label label-primary">subscription</span>'
                    : '<span class="label label-default">manual</span>') + '</td>');
                $tr.append('<td>' + (p.node_count || 0) + '</td>');
                $tr.append('<td>' + escapeHtml(p.last_update || '') + '</td>');
                $tr.append('<td>' + (p.active ? '<span class="fa fa-check text-success"></span>' : '') + '</td>');
                var $cmds = $('<td>');
                $cmds.append(actionBtn('fa-power-off', '激活',
                    'POST', '/api/mihomo/profiles/activate/' + encodeURIComponent(p.name),
                    function() { loadProfiles(); }, p.active));
                if (p.source_type === 'subscription' && p.sub_id) {
                    $cmds.append(' ', actionBtn('fa-cloud-download', '刷新',
                        'POST', '/api/mihomo/subscriptions/refresh/' + encodeURIComponent(p.sub_id),
                        function() { loadProfiles(); }));
                }
                $cmds.append(' ', actionBtn('fa-eye', '查看 YAML',
                    'GET', '/api/mihomo/profiles/viewYaml/' + encodeURIComponent(p.name),
                    function(d) { alert(d.content || d.message); }));
                $cmds.append(' ', actionBtn('fa-trash-o', '删除',
                    'POST', '/api/mihomo/profiles/delete/' + encodeURIComponent(p.name),
                    function() { loadProfiles(); }, p.active, true));
                $tr.append($cmds);
                $tbody.append($tr);
            });
        });
    }
    function actionBtn(icon, title, method, url, onOk, disabled, confirmFirst) {
        var $b = $('<button class="btn btn-xs btn-default">')
            .attr('title', title).prop('disabled', !!disabled)
            .append('<span class="fa ' + icon + '"></span>');
        $b.click(function() {
            if (confirmFirst && !confirm('确认执行此操作？')) return;
            $.ajax({url: url, method: method}).done(function(d) { onOk && onOk(d); });
        });
        return $b;
    }
    $('#btn-create-empty').click(function() {
        var name = prompt('配置档名称（仅字母、数字、下划线、短横线；不可以 sub- 开头）：');
        if (!name) return;
        $.post('/api/mihomo/profiles/createEmpty', {name: name}).done(function(d) {
            if (d.status === 'ok') loadProfiles();
            else alert(d.message);
        });
    });
    $('#btn-profile-reload').click(loadProfiles);

    // ----- Tab 4: Override -----
    function loadOverride() {
        $.get('/api/mihomo/override/get').done(function(j) {
            $('#override-content').val((j && j.content) || '');
        });
    }
    $('#btn-override-save').click(function() {
        var $msg = $('#override-msg').text('保存中...').css('color', '#888');
        $.post('/api/mihomo/override/set', {content: $('#override-content').val()}).done(function(d) {
            $msg.text(d.message || d.status).css('color', d.status === 'ok' ? '#5cb85c' : '#d9534f');
        });
    });
    $('#btn-override-validate').click(function() {
        var $msg = $('#override-msg').text('校验中...').css('color', '#888');
        $.post('/api/mihomo/override/validate', {content: $('#override-content').val()}).done(function(d) {
            $msg.text(d.message || d.status).css('color', d.status === 'ok' ? '#5cb85c' : '#d9534f');
        });
    });
    $('#btn-override-reset').click(function() {
        if (!confirm('重置 override.yaml 为空？')) return;
        $.post('/api/mihomo/override/reset').done(function(d) {
            if (d.status === 'ok') loadOverride();
            $('#override-msg').text(d.message || d.status).css('color', d.status === 'ok' ? '#5cb85c' : '#d9534f');
        });
    });

    // ----- Tab 5: YAML -----
    function loadComposedYaml() {
        $.get('/api/mihomo/override/composedYaml').done(function(j) {
            $('#composed-yaml').val((j && j.content) || (j && j.message) || '');
        });
    }
    $('#btn-yaml-refresh').click(loadComposedYaml);
    $('#btn-yaml-copy').click(function() {
        var el = document.getElementById('composed-yaml');
        el.select(); document.execCommand('copy');
    });
    $('#btn-yaml-download').click(function() {
        var blob = new Blob([$('#composed-yaml').val() || ''], {type: 'text/yaml'});
        var url = URL.createObjectURL(blob);
        var a = document.createElement('a');
        a.href = url; a.download = 'config.yaml';
        document.body.appendChild(a); a.click();
        setTimeout(function() { URL.revokeObjectURL(url); a.remove(); }, 500);
    });

    // ----- Tab 6: Log -----
    var logTimer = null, logPaused = false;
    function loadLogTail(force) {
        var lines = $('#log-lines').val();
        var level = $('#log-level').val();
        $.get('/api/mihomo/dashboard/logs', {lines: lines, level: level}).done(function(j) {
            var ta = document.getElementById('mihomo-log-view');
            var atBottom = (ta.scrollTop + ta.clientHeight) >= (ta.scrollHeight - 4);
            ta.value = (j && j.logs) || '';
            if (atBottom || force) ta.scrollTop = ta.scrollHeight;
        });
    }
    function startLogTimer() {
        if (logTimer) return;
        logTimer = setInterval(function() { if (!logPaused) loadLogTail(); }, 5000);
    }
    $('#btn-log-pause').click(function() {
        logPaused = !logPaused;
        $(this).find('i').toggleClass('fa-pause fa-play');
    });
    $('#btn-log-refresh').click(function() { loadLogTail(true); });
    $('#log-lines, #log-level').change(function() { loadLogTail(true); });
    startLogTimer();

    // ----- Tab 7: Updates -----
    var $updateProgressWrap = $('.update-progress-wrap');
    var $updateProgressBar  = $updateProgressWrap.find('.progress-bar');
    var $updateProgressText = $updateProgressWrap.find('.progress-text');
    var $updateStatusMsg    = $updateProgressWrap.find('.update-status-msg');
    var currentUpdateResource = null;

    function loadAllUpdateStates() {
        $('#updates tbody tr[data-resource]').each(function() { loadUpdateState($(this)); });
    }
    function loadUpdateState($row) {
        var resource = $row.data('resource');
        var variant = resource === 'ui' ? 'zashboard' : undefined;
        $.get('/api/mihomo/update/check', {resource: resource, variant: variant})
            .done(function(j) {
                var $badge = $row.find('.update-badge');
                if (j.status === 'ok') {
                    $row.find('.update-current').text(j.current || '—');
                    $row.find('.update-latest').text(j.latest || '—');
                    var isCustomUrl = j.custom_url === true;
                    var hasCurrent = j.current && j.current !== '';
                    var hasUpdate;
                    if (isCustomUrl) {
                        hasUpdate = true;
                    } else {
                        hasUpdate = j.latest && j.current && j.latest !== j.current;
                    }
                    $row.find('.btn-update').prop('disabled', !hasUpdate);
                    $badge.removeClass('is-up-to-date is-has-update is-unknown is-error');
                    if (!hasCurrent) {
                        $badge.addClass('is-unknown').text('未安装');
                    } else if (hasUpdate && !isCustomUrl) {
                        $badge.addClass('is-has-update').text('有新版本');
                    } else if (hasUpdate && isCustomUrl) {
                        $badge.addClass('is-has-update').text('可更新');
                    } else {
                        $badge.addClass('is-up-to-date').text('已是最新');
                    }
                } else {
                    $badge.removeClass('is-up-to-date is-has-update').addClass('is-error').text('检查失败');
                    if (currentUpdateResource === resource) {
                        $updateStatusMsg.addClass('is-error').removeClass('is-ok is-info')
                            .text(j.message || 'check failed');
                    }
                }
            })
            .fail(function(xhr, status, err) {
                $row.find('.update-badge').removeClass('is-up-to-date is-has-update').addClass('is-error').text('检查失败');
            });
        // Resume any prior in-progress update.
        $.get('/api/mihomo/update/progress', {resource: resource})
            .done(function(p) {
                if (p && p.state === 'running') {
                    currentUpdateResource = resource;
                    pollUpdateProgress(resource);
                }
            })
            .fail(function() { /* progress polls are best-effort */ });
    }
    $('#updates').on('click', '.btn-check', function() {
        var $row = $(this).closest('tr');
        $row.find('.update-badge').removeClass('is-up-to-date is-has-update is-unknown is-error').addClass('is-unknown').text('检查中...');
        loadUpdateState($row);
    });
    $('#updates').on('click', '.btn-update', function() {
        var $row = $(this).closest('tr');
        var resource = $row.data('resource');
        var variant = resource === 'ui' ? 'zashboard' : undefined;
        if (!confirm('开始更新？')) return;
        currentUpdateResource = resource;
        $row.find('.btn-update, .btn-check').prop('disabled', true);
        $updateProgressWrap.show();
        $updateProgressBar.css('width', '0%');
        $updateProgressText.text('0%');
        $updateStatusMsg.removeClass('is-error is-ok is-info').text('');
        $row.find('.update-badge').removeClass('is-up-to-date is-has-update is-unknown is-error').addClass('is-unknown').text('更新中...');
        $.post('/api/mihomo/update/run', {resource: resource, variant: variant})
            .done(function(j) {
                if (j.status !== 'ok') {
                    $updateStatusMsg.addClass('is-error').removeClass('is-ok is-info')
                        .text(j.message || 'failed');
                    $row.find('.btn-update, .btn-check').prop('disabled', false);
                    $updateProgressWrap.hide();
                    return;
                }
                pollUpdateProgress(resource);
            })
            .fail(function(xhr, status, err) {
                $updateStatusMsg.addClass('is-error').removeClass('is-ok is-info')
                    .text('update failed: ' + (err || status));
                $row.find('.btn-update, .btn-check').prop('disabled', false);
                $updateProgressWrap.hide();
            });
    });
    function pollUpdateProgress(resource) {
        var attempts = 0;
        var poll = setInterval(function() {
            attempts++;
            $.get('/api/mihomo/update/progress', {resource: resource})
                .done(function(p) {
                    if (!p) return;
                    if (p.state === 'done') {
                        clearInterval(poll);
                        $updateProgressWrap.hide();
                        $updateStatusMsg.addClass('is-ok').removeClass('is-error is-info')
                            .text('更新完成。');
                        currentUpdateResource = null;
                        loadAllUpdateStates();
                    } else if (p.state === 'failed') {
                        clearInterval(poll);
                        $updateProgressWrap.hide();
                        $updateStatusMsg.addClass('is-error').removeClass('is-ok is-info')
                            .text(p.message || 'failed');
                        currentUpdateResource = null;
                        var $row = $('#updates tbody tr[data-resource="' + resource + '"]');
                        $row.find('.btn-update, .btn-check').prop('disabled', false);
                        $row.find('.update-badge').removeClass('is-up-to-date is-has-update is-unknown is-error').addClass('is-unknown').text('更新失败');
                    } else {
                        var pct = p.percent != null ? p.percent : 0;
                        $updateProgressWrap.show();
                        $updateProgressBar.css('width', pct + '%');
                        $updateProgressText.text((p.step || 'working') + ' ' + pct + '%');
                    }
                })
                .fail(function(xhr, status, err) {
                    if (attempts > 5) {
                        clearInterval(poll);
                        $updateProgressWrap.hide();
                        $updateStatusMsg.addClass('is-error').removeClass('is-ok is-info')
                            .text('progress lost: ' + (err || status));
                        currentUpdateResource = null;
                        var $row = $('#updates tbody tr[data-resource="' + resource + '"]');
                        $row.find('.btn-update, .btn-check').prop('disabled', false);
                    }
                });
        }, 2000);
    }

    // ----- Tab 8: Backup -----
    $('#export-encrypt').change(function() {
        $('#export-password-row').toggle(this.checked);
    });
    $('#btn-export').click(function() {
        var fd = new FormData();
        fd.append('encrypt', $('#export-encrypt').is(':checked') ? '1' : '0');
        fd.append('password', $('#export-password').val() || '');
        $.ajax({
            url: '/api/mihomo/backup/export', method: 'POST',
            data: fd, processData: false, contentType: false,
            xhrFields: { responseType: 'blob' }
        }).done(function(blob, status, xhr) {
            var a = document.createElement('a');
            var url = window.URL.createObjectURL(blob);
            a.href = url;
            var disp = xhr.getResponseHeader('Content-Disposition');
            a.download = disp ? disp.split('filename=')[1].replace(/"/g, '') : 'mihomo-backup.tar.gz';
            document.body.appendChild(a);
            a.click();
            window.URL.revokeObjectURL(url);
            document.body.removeChild(a);
            loadBackupList();
        }).fail(function(xhr) {
            var msg = '导出失败';
            try {
                var r = JSON.parse(xhr.responseText);
                msg = r.message || msg;
            } catch(e) {}
            alert(msg);
        });
    });
    $('#btn-import').click(function() {
        var file = $('#import-file')[0].files[0];
        if (!file) { $('#import-msg').text('请先选择文件').css('color', '#d9534f'); return; }
        var fd = new FormData();
        fd.append('file', file);
        fd.append('strategy', $('input[name="strategy"]:checked').val());
        fd.append('password', $('#import-password').val() || '');
        fd.append('restart', $('#import-restart').is(':checked') ? '1' : '0');
        $('#import-msg').text('导入中...').css('color', '#888');
        $.ajax({
            url: '/api/mihomo/backup/import', method: 'POST',
            data: fd, processData: false, contentType: false
        }).done(function(d) {
            $('#import-msg').text(d.message || d.status).css('color', d.status === 'ok' ? '#5cb85c' : '#d9534f');
            if (d.status === 'ok') loadBackupList();
        }).fail(function(xhr, status, err) {
            $('#import-msg').text('import failed: ' + (err || status)).css('color', '#d9534f');
        });
    });
    function loadBackupList() {
        $.get('/api/mihomo/backup/list').done(function(j) {
            var $tbody = $('#backup-rows').empty();
            (j.rows || []).forEach(function(b) {
                var $tr = $('<tr>');
                $tr.append('<td><code>' + escapeHtml(b.file) + '</code></td>');
                $tr.append('<td>' + fmtSize(b.size) + '</td>');
                $tr.append('<td>' + new Date(b.mtime * 1000).toLocaleString() + '</td>');
                var $cmds = $('<td>');
                $cmds.append($('<a class="btn btn-xs btn-default">')
                    .attr('href', '/api/mihomo/backup/download?file=' + encodeURIComponent(b.file))
                    .attr('target', '_blank')
                    .html('<span class="fa fa-download"></span>'));
                $cmds.append(' ', $('<button class="btn btn-xs btn-default">')
                    .html('<span class="fa fa-undo"></span>')
                    .click(function() {
                        if (!confirm('从此备份还原？')) return;
                        var data = {file: b.file};
                        if (/\.enc$/.test(b.file)) {
                            var pw = prompt('该备份已加密，请输入密码（至少8位）：');
                            if (!pw || pw.length < 8) {
                                alert('加密备份需要密码');
                                return;
                            }
                            data.password = pw;
                        }
                        $.post('/api/mihomo/backup/restore', data)
                            .done(function(d) {
                                if (d.status === 'ok') { loadBackupList(); }
                                else { alert(d.message || 'restore failed'); }
                            })
                            .fail(function(xhr, status, err) {
                                alert('restore failed: ' + (err || status));
                            });
                    }));
                $cmds.append(' ', $('<button class="btn btn-xs btn-default">')
                    .html('<span class="fa fa-trash-o"></span>')
                    .click(function() {
                        if (!confirm('删除此备份？')) return;
                        $.post('/api/mihomo/backup/delete', {file: b.file})
                            .done(function(d) {
                                if (d.status === 'ok') { loadBackupList(); }
                                else { alert(d.message || 'delete failed'); }
                            })
                            .fail(function(xhr, status, err) {
                                alert('delete failed: ' + (err || status));
                            });
                    }));
                $tr.append($cmds);
                $tbody.append($tr);
            });
        }).fail(function(xhr, status, err) {
            $('#backup-rows').empty().append('<tr><td colspan="4" style="color:#d9534f;">load failed: ' + (err || status) + '</td></tr>');
        });
    }

    // ----- Apply button -----
    $('#reconfigureAct').SimpleActionButton();

    // ----- helpers -----
    function escapeHtml(s) {
        return (s == null ? '' : String(s))
            .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
    }
    function fmtSize(n) {
        if (!n) return '0 B';
        if (n < 1024) return n + ' B';
        if (n < 1048576) return (n / 1024).toFixed(1) + ' KB';
        return (n / 1048576).toFixed(2) + ' MB';
    }

    // Trigger initial-tab handlers.
    onTabShown((window.location.hash || '#settings').substring(1));
});
</script>
