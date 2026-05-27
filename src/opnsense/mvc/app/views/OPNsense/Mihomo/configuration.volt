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
    .mihomo-yaml-edit {
        width: 100%;
        height: 420px;
        font-family: monospace;
        font-size: 12px;
        background: #1e1e1e;
        color: #d4d4d4;
        border: 1px solid #333;
        resize: vertical;
    }
    .mihomo-log {
        width: 100%;
        height: 360px;
        font-family: monospace;
        font-size: 12px;
        background: #1e1e1e;
        color: #d4d4d4;
        border: 1px solid #333;
        resize: vertical;
    }
    .mihomo-update-card {
        border: 1px solid #e5e5e5;
        border-radius: 4px;
        padding: 12px;
        margin-bottom: 12px;
        background: #fafafa;
    }
    .mihomo-update-card .versions {
        font-size: 13px;
        margin: 6px 0;
    }
    .mihomo-update-card .versions .label-text { color: #888; min-width: 70px; display: inline-block; }
    .mihomo-update-card .progress { margin-top: 8px; }
</style>

<ul class="nav nav-tabs" role="tablist" id="mihomo-tabs">
    <li class="active"><a data-toggle="tab" href="#settings">{{ lang._('Settings') }}</a></li>
    <li><a data-toggle="tab" href="#subscriptions">{{ lang._('Subscriptions') }}</a></li>
    <li><a data-toggle="tab" href="#profiles">{{ lang._('Profiles') }}</a></li>
    <li><a data-toggle="tab" href="#override">{{ lang._('Override') }}</a></li>
    <li><a data-toggle="tab" href="#yaml">{{ lang._('YAML') }}</a></li>
    <li><a data-toggle="tab" href="#log">{{ lang._('Log') }}</a></li>
    <li><a data-toggle="tab" href="#updates">{{ lang._('Updates') }}</a></li>
    <li><a data-toggle="tab" href="#backup">{{ lang._('Backup') }}</a></li>
</ul>

<div class="tab-content content-box">

    {# ---------------- Tab 1: Settings ---------------- #}
    <div id="settings" class="tab-pane fade in active mihomo-tab-content">
        <form id="frm_settings">
            <h3>{{ lang._('General') }}</h3>
            <div class="content-box">
                {{ partial('layout_partials/base_form', {'fields': formGeneral, 'id': 'frm_general'}) }}
            </div>
            <h3>{{ lang._('External Controller (API & UI)') }}</h3>
            <div class="content-box">
                {{ partial('layout_partials/base_form', {'fields': formController, 'id': 'frm_controller'}) }}
            </div>
            <h3>{{ lang._('TUN') }}</h3>
            <div class="content-box">
                {{ partial('layout_partials/base_form', {'fields': formTun, 'id': 'frm_tun'}) }}
            </div>
            <h3>{{ lang._('DNS') }}</h3>
            <div class="content-box">
                {{ partial('layout_partials/base_form', {'fields': formDns, 'id': 'frm_dns'}) }}
            </div>
            <h3>{{ lang._('Sniffer') }}</h3>
            <div class="content-box">
                {{ partial('layout_partials/base_form', {'fields': formSniffer, 'id': 'frm_sniffer'}) }}
            </div>
            <h3>{{ lang._('Auto Update') }}</h3>
            <div class="content-box">
                {{ partial('layout_partials/base_form', {'fields': formUpdate, 'id': 'frm_update'}) }}
            </div>
            <div style="margin-top: 16px;">
                <button type="button" class="btn btn-primary" id="btn-save-settings">
                    <i class="fa fa-save"></i> {{ lang._('Save Settings') }}
                </button>
                <span id="settings-save-msg" style="margin-left: 10px; color: #888;"></span>
            </div>
        </form>
    </div>

    {# ---------------- Tab 2: Subscriptions ---------------- #}
    <div id="subscriptions" class="tab-pane fade mihomo-tab-content">
        <table id="grid-subscriptions" class="table table-condensed table-hover table-striped"
               data-editDialog="DialogSubscription" data-editAlertText="">
            <thead>
                <tr>
                    <th data-column-id="uuid" data-type="string" data-identifier="true" data-visible="false">{{ lang._('uuid') }}</th>
                    <th data-column-id="enabled" data-type="boolean" data-formatter="rowtoggle" data-width="6em">{{ lang._('Enabled') }}</th>
                    <th data-column-id="name" data-type="string">{{ lang._('Name') }}</th>
                    <th data-column-id="url" data-type="string">{{ lang._('URL') }}</th>
                    <th data-column-id="interval" data-type="string" data-width="8em">{{ lang._('Interval (h)') }}</th>
                    <th data-column-id="last_update" data-type="string">{{ lang._('Last Update') }}</th>
                    <th data-column-id="last_status" data-type="string" data-width="8em">{{ lang._('Status') }}</th>
                    <th data-column-id="commands" data-formatter="commands" data-sortable="false" data-width="12em">
                        {{ lang._('Commands') }}
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

        <h4 style="margin-top: 16px;">{{ lang._('Subscription Log') }}</h4>
        <textarea class="mihomo-log" id="sub-log" readonly></textarea>
    </div>

    {# ---------------- Tab 3: Profiles ---------------- #}
    <div id="profiles" class="tab-pane fade mihomo-tab-content">
        <div style="margin-bottom: 10px;">
            <button type="button" class="btn btn-default" id="btn-create-empty">
                <i class="fa fa-plus"></i> {{ lang._('Create Empty Profile') }}
            </button>
            <button type="button" class="btn btn-default" id="btn-profile-reload">
                <i class="fa fa-refresh"></i> {{ lang._('Reload') }}
            </button>
        </div>
        <table class="table table-condensed table-hover table-striped">
            <thead>
                <tr>
                    <th>{{ lang._('Name') }}</th>
                    <th>{{ lang._('Source') }}</th>
                    <th>{{ lang._('Nodes') }}</th>
                    <th>{{ lang._('Last Updated') }}</th>
                    <th>{{ lang._('Active') }}</th>
                    <th>{{ lang._('Commands') }}</th>
                </tr>
            </thead>
            <tbody id="profile-rows"></tbody>
        </table>
    </div>

    {# ---------------- Tab 4: Override ---------------- #}
    <div id="override" class="tab-pane fade mihomo-tab-content">
        <div class="alert alert-info" style="margin-bottom: 10px;">
            {{ lang._('Snippets in override.yaml survive subscription refreshes. Reserved convention keys:') }}
            <code>prepend-rules</code>, <code>append-rules</code>,
            <code>append-proxies</code>,
            <code>prepend-proxy-groups</code>, <code>append-proxy-groups</code>.
            {{ lang._('All other top-level keys are deep-merged into the composed config.') }}
        </div>
        <details style="margin-bottom: 10px;">
            <summary style="cursor:pointer;">{{ lang._('Example') }}</summary>
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
                <i class="fa fa-save"></i> {{ lang._('Save Override') }}
            </button>
            <button type="button" class="btn btn-default" id="btn-override-validate">
                <i class="fa fa-check"></i> {{ lang._('Validate Only') }}
            </button>
            <button type="button" class="btn btn-danger" id="btn-override-reset">
                <i class="fa fa-undo"></i> {{ lang._('Reset') }}
            </button>
            <span id="override-msg" style="margin-left:10px;color:#888;"></span>
        </div>
    </div>

    {# ---------------- Tab 5: YAML (read-only) ---------------- #}
    <div id="yaml" class="tab-pane fade mihomo-tab-content">
        <div class="alert alert-warning" style="margin-bottom:10px;">
            {{ lang._('This view shows the currently active config.yaml (read-only). Edit Settings, Override, or Profiles to change the underlying sources.') }}
        </div>
        <textarea class="mihomo-yaml-edit" id="composed-yaml" readonly spellcheck="false"></textarea>
        <div style="margin-top: 10px;">
            <button type="button" class="btn btn-default" id="btn-yaml-refresh">
                <i class="fa fa-refresh"></i> {{ lang._('Refresh') }}
            </button>
            <button type="button" class="btn btn-default" id="btn-yaml-copy">
                <i class="fa fa-copy"></i> {{ lang._('Copy to Clipboard') }}
            </button>
            <button type="button" class="btn btn-default" id="btn-yaml-download">
                <i class="fa fa-download"></i> {{ lang._('Download') }}
            </button>
        </div>
    </div>

    {# ---------------- Tab 6: Log ---------------- #}
    <div id="log" class="tab-pane fade mihomo-tab-content">
        <div style="margin-bottom: 10px;">
            <label>{{ lang._('Lines') }}:
                <select id="log-lines">
                    <option value="100">100</option>
                    <option value="200" selected>200</option>
                    <option value="500">500</option>
                    <option value="1000">1000</option>
                </select>
            </label>
            <label style="margin-left: 12px;">{{ lang._('Filter') }}:
                <select id="log-level">
                    <option value="">{{ lang._('all') }}</option>
                    <option value="ERR">error</option>
                    <option value="WARN">warning</option>
                    <option value="INFO">info</option>
                    <option value="DEBUG">debug</option>
                </select>
            </label>
            <button type="button" class="btn btn-default btn-xs" id="btn-log-pause" style="margin-left:8px;">
                <i class="fa fa-pause"></i> {{ lang._('Pause Auto-refresh') }}
            </button>
            <button type="button" class="btn btn-default btn-xs" id="btn-log-refresh">
                <i class="fa fa-refresh"></i> {{ lang._('Refresh') }}
            </button>
        </div>
        <textarea class="mihomo-log" id="mihomo-log-view" readonly></textarea>
    </div>

    {# ---------------- Tab 7: Updates ---------------- #}
    <div id="updates" class="tab-pane fade mihomo-tab-content">
        {% for r in [{'k':'core','label':lang._('Mihomo Core')}, {'k':'geoip','label':lang._('GeoIP Database')}, {'k':'ui','label':lang._('Dashboard UI')}] %}
        <div class="mihomo-update-card" data-resource="{{ r.k }}">
            <h4 style="margin-top:0;">{{ r.label }}</h4>
            <div class="versions">
                <div><span class="label-text">{{ lang._('Current') }}:</span> <span class="current">—</span></div>
                <div><span class="label-text">{{ lang._('Latest') }}:</span>  <span class="latest">—</span></div>
            </div>
            {% if r.k == 'ui' %}
            <div style="margin: 6px 0;">
                <label>{{ lang._('Variant') }}:
                    <select class="ui-variant">
                        <option value="zashboard">zashboard</option>
                        <option value="metacubexd">metacubexd</option>
                        <option value="yacd">yacd</option>
                    </select>
                </label>
            </div>
            {% endif %}
            <button type="button" class="btn btn-default btn-check">
                <i class="fa fa-search"></i> {{ lang._('Check for Updates') }}
            </button>
            <button type="button" class="btn btn-primary btn-update" disabled>
                <i class="fa fa-arrow-up"></i> {{ lang._('Update') }}
            </button>
            <div class="progress" style="display:none;">
                <div class="progress-bar progress-bar-striped active" style="width:0%;">
                    <span class="progress-text">0%</span>
                </div>
            </div>
            <div class="status-msg" style="margin-top:6px;color:#888;font-size:12px;"></div>
        </div>
        {% endfor %}
    </div>

    {# ---------------- Tab 8: Backup ---------------- #}
    <div id="backup" class="tab-pane fade mihomo-tab-content">
        <h4>{{ lang._('Export Configuration') }}</h4>
        <div class="alert alert-warning">
            {{ lang._('Backups contain sensitive data (API secret, proxy credentials). Store securely.') }}
        </div>
        <form id="frm-export">
            <div class="form-group">
                <label><input type="checkbox" id="export-encrypt"> {{ lang._('Encrypt with AES-256-CBC') }}</label>
            </div>
            <div class="form-group" id="export-password-row" style="display:none;">
                <label>{{ lang._('Password') }} (≥ 8 chars):
                    <input type="password" id="export-password" class="form-control" style="display:inline-block;width:300px;">
                </label>
            </div>
            <button type="button" class="btn btn-primary" id="btn-export">
                <i class="fa fa-download"></i> {{ lang._('Download Backup') }}
            </button>
        </form>

        <hr>

        <h4>{{ lang._('Import Configuration') }}</h4>
        <form id="frm-import" enctype="multipart/form-data">
            <div class="form-group">
                <input type="file" id="import-file" name="file" accept=".tar.gz,.gz,.enc">
            </div>
            <div class="form-group">
                <label>{{ lang._('Conflict policy') }}:</label>
                <label style="margin-left: 10px;">
                    <input type="radio" name="strategy" value="overwrite" checked> {{ lang._('Overwrite all') }}
                </label>
                <label style="margin-left: 10px;">
                    <input type="radio" name="strategy" value="merge"> {{ lang._('Merge (keep local extras)') }}
                </label>
            </div>
            <div class="form-group">
                <label>{{ lang._('Password (if encrypted)') }}:
                    <input type="password" id="import-password" class="form-control" style="display:inline-block;width:300px;">
                </label>
            </div>
            <div class="form-group">
                <label><input type="checkbox" id="import-restart"> {{ lang._('Restart mihomo after import') }}</label>
            </div>
            <button type="button" class="btn btn-primary" id="btn-import">
                <i class="fa fa-upload"></i> {{ lang._('Import Backup') }}
            </button>
            <span id="import-msg" style="margin-left:10px;color:#888;"></span>
        </form>

        <hr>

        <h4>{{ lang._('Recent Local Backups') }}</h4>
        <table class="table table-condensed table-hover table-striped">
            <thead>
                <tr>
                    <th>{{ lang._('File') }}</th>
                    <th>{{ lang._('Size') }}</th>
                    <th>{{ lang._('Modified') }}</th>
                    <th>{{ lang._('Commands') }}</th>
                </tr>
            </thead>
            <tbody id="backup-rows"></tbody>
        </table>

        <h4 style="margin-top: 16px;">{{ lang._('Auto Backup') }}</h4>
        <div style="font-size:12px;color:#888;">
            {{ lang._('Configure under Settings → Auto Update (auto_backup_on_override / auto_backup_on_profile_activate).') }}
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
    'label': lang._('Edit Subscription')
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
        mapDataToFormUI({
            'frm_general':    SETTINGS_API + 'get',
            'frm_controller': SETTINGS_API + 'get',
            'frm_tun':        SETTINGS_API + 'get',
            'frm_dns':        SETTINGS_API + 'get',
            'frm_sniffer':    SETTINGS_API + 'get',
            'frm_update':     SETTINGS_API + 'get'
        }).done(function() {});
    }
    loadSettings();

    $('#btn-save-settings').click(function() {
        var $msg = $('#settings-save-msg');
        $msg.text('{{ lang._('Saving...') }}');
        saveFormToEndpoint('#frm_settings', SETTINGS_API + 'set', function(data) {
            if (data && data.result === 'saved') {
                $msg.text('{{ lang._('Saved') }}').css('color', '#5cb85c');
            } else {
                $msg.text((data && data.message) ? data.message : '{{ lang._('Save failed') }}').css('color', '#d9534f');
            }
        });
    });

    // ----- Tab 2: Subscriptions -----
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
                          + 'data-row-id="' + row.uuid + '" title="{{ lang._('Refresh Now') }}">'
                          + '<span class="fa fa-cloud-download fa-fw"></span></button>'
                          + ' <button type="button" class="btn btn-xs btn-default bootgrid-tooltip command-edit" '
                          + 'data-row-id="' + row.uuid + '"><span class="fa fa-pencil fa-fw"></span></button>'
                          + ' <button type="button" class="btn btn-xs btn-default bootgrid-tooltip command-delete" '
                          + 'data-row-id="' + row.uuid + '"><span class="fa fa-trash-o fa-fw"></span></button>';
                }
            }
        }
    });
    $('#grid-subscriptions').on('loaded.rs.jquery.bootgrid', function() {
        $('.mihomo-sub-refresh').off('click').on('click', function() {
            var uuid = $(this).data('row-id');
            $(this).prop('disabled', true);
            $.ajax({
                url: '/api/mihomo/subscriptions/refresh/' + encodeURIComponent(uuid),
                method: 'POST'
            }).always(function() { setTimeout(loadSubLog, 800); });
        });
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
                $cmds.append(actionBtn('fa-power-off', '{{ lang._('Activate') }}',
                    'POST', '/api/mihomo/profiles/activate/' + encodeURIComponent(p.name),
                    function() { loadProfiles(); }, p.active));
                if (p.source_type === 'subscription' && p.sub_id) {
                    $cmds.append(' ', actionBtn('fa-cloud-download', '{{ lang._('Refresh') }}',
                        'POST', '/api/mihomo/subscriptions/refresh/' + encodeURIComponent(p.sub_id),
                        function() { loadProfiles(); }));
                }
                $cmds.append(' ', actionBtn('fa-eye', '{{ lang._('View YAML') }}',
                    'GET', '/api/mihomo/profiles/viewYaml/' + encodeURIComponent(p.name),
                    function(d) { alert(d.content || d.message); }));
                $cmds.append(' ', actionBtn('fa-trash-o', '{{ lang._('Delete') }}',
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
            if (confirmFirst && !confirm('{{ lang._('Confirm operation?') }}')) return;
            $.ajax({url: url, method: method}).done(function(d) { onOk && onOk(d); });
        });
        return $b;
    }
    $('#btn-create-empty').click(function() {
        var name = prompt('{{ lang._('Profile name (letters/digits/underscore/dash; no sub- prefix):') }}');
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
        var $msg = $('#override-msg').text('{{ lang._('Saving...') }}').css('color', '#888');
        $.post('/api/mihomo/override/set', {content: $('#override-content').val()}).done(function(d) {
            $msg.text(d.message || d.status).css('color', d.status === 'ok' ? '#5cb85c' : '#d9534f');
        });
    });
    $('#btn-override-validate').click(function() {
        var $msg = $('#override-msg').text('{{ lang._('Validating...') }}').css('color', '#888');
        $.post('/api/mihomo/override/validate', {content: $('#override-content').val()}).done(function(d) {
            $msg.text(d.message || d.status).css('color', d.status === 'ok' ? '#5cb85c' : '#d9534f');
        });
    });
    $('#btn-override-reset').click(function() {
        if (!confirm('{{ lang._('Reset override.yaml to empty?') }}')) return;
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
    function loadAllUpdateStates() {
        $('.mihomo-update-card').each(function() { loadUpdateState($(this)); });
    }
    function loadUpdateState($card) {
        var resource = $card.data('resource');
        var variant = $card.find('.ui-variant').val() || undefined;
        $.get('/api/mihomo/update/check', {resource: resource, variant: variant}).done(function(j) {
            if (j.status === 'ok') {
                $card.find('.current').text(j.current || '—');
                $card.find('.latest').text(j.latest || '—');
                var has = j.latest && j.current && j.latest !== j.current;
                $card.find('.btn-update').prop('disabled', !has && j.current !== '');
            } else {
                $card.find('.status-msg').text(j.message || 'check failed').css('color', '#d9534f');
            }
        });
        // Resume any prior in-progress update.
        $.get('/api/mihomo/update/progress', {resource: resource}).done(function(p) {
            if (p && p.state === 'running') {
                pollUpdateProgress($card, resource);
            }
        });
    }
    $('.mihomo-update-card .btn-check').click(function() {
        loadUpdateState($(this).closest('.mihomo-update-card'));
    });
    $('.mihomo-update-card .ui-variant').change(function() {
        loadUpdateState($(this).closest('.mihomo-update-card'));
    });
    $('.mihomo-update-card .btn-update').click(function() {
        var $card = $(this).closest('.mihomo-update-card');
        var resource = $card.data('resource');
        var variant = $card.find('.ui-variant').val() || undefined;
        if (!confirm('{{ lang._('Start update?') }}')) return;
        $card.find('.btn-update, .btn-check').prop('disabled', true);
        $card.find('.progress').show();
        $.post('/api/mihomo/update/run', {resource: resource, variant: variant}).done(function(j) {
            if (j.status !== 'ok') {
                $card.find('.status-msg').text(j.message || 'failed').css('color', '#d9534f');
                $card.find('.btn-update, .btn-check').prop('disabled', false);
                return;
            }
            pollUpdateProgress($card, resource);
        });
    });
    function pollUpdateProgress($card, resource) {
        var poll = setInterval(function() {
            $.get('/api/mihomo/update/progress', {resource: resource}).done(function(p) {
                if (!p) return;
                if (p.state === 'done') {
                    clearInterval(poll);
                    $card.find('.progress').hide();
                    $card.find('.status-msg').text('{{ lang._('Update complete.') }}').css('color', '#5cb85c');
                    $card.find('.btn-update, .btn-check').prop('disabled', false);
                    loadUpdateState($card);
                } else if (p.state === 'failed') {
                    clearInterval(poll);
                    $card.find('.progress').hide();
                    $card.find('.status-msg').text(p.message || 'failed').css('color', '#d9534f');
                    $card.find('.btn-update, .btn-check').prop('disabled', false);
                } else {
                    var pct = p.percent != null ? p.percent : 0;
                    $card.find('.progress-bar').css('width', pct + '%');
                    $card.find('.progress-text').text((p.step || 'working') + ' ' + pct + '%');
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
        // Use form submit so the browser handles the streaming download.
        var $f = $('<form>', {
            method: 'POST', action: '/api/mihomo/backup/export', target: '_self'
        });
        $f.append($('<input>', {type:'hidden', name:'encrypt', value: $('#export-encrypt').is(':checked') ? '1':'0'}));
        $f.append($('<input>', {type:'hidden', name:'password', value: $('#export-password').val() || ''}));
        $f.appendTo('body').submit().remove();
    });
    $('#btn-import').click(function() {
        var file = $('#import-file')[0].files[0];
        if (!file) { $('#import-msg').text('{{ lang._('Choose a file first') }}').css('color', '#d9534f'); return; }
        var fd = new FormData();
        fd.append('file', file);
        fd.append('strategy', $('input[name="strategy"]:checked').val());
        fd.append('password', $('#import-password').val() || '');
        fd.append('restart', $('#import-restart').is(':checked') ? '1' : '0');
        $('#import-msg').text('{{ lang._('Importing...') }}').css('color', '#888');
        $.ajax({
            url: '/api/mihomo/backup/import', method: 'POST',
            data: fd, processData: false, contentType: false
        }).done(function(d) {
            $('#import-msg').text(d.message || d.status).css('color', d.status === 'ok' ? '#5cb85c' : '#d9534f');
            if (d.status === 'ok') loadBackupList();
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
                    .html('<span class="fa fa-download"></span>'));
                $cmds.append(' ', $('<button class="btn btn-xs btn-default">')
                    .html('<span class="fa fa-undo"></span>')
                    .click(function() {
                        if (!confirm('{{ lang._('Restore from this backup?') }}')) return;
                        $.post('/api/mihomo/backup/restore', {file: b.file}).done(loadBackupList);
                    }));
                $cmds.append(' ', $('<button class="btn btn-xs btn-default">')
                    .html('<span class="fa fa-trash-o"></span>')
                    .click(function() {
                        if (!confirm('{{ lang._('Delete this backup?') }}')) return;
                        $.post('/api/mihomo/backup/delete', {file: b.file}).done(loadBackupList);
                    }));
                $tr.append($cmds);
                $tbody.append($tr);
            });
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
