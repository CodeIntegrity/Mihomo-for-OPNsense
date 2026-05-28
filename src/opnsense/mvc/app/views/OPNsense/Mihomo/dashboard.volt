{#
 # Mihomo Dashboard — landing page.
 #
 # Layout: 4 stacked content-boxes
 #   1. Service Status (state light + uptime + pid + start/stop/restart + open UI)
 #   2. Active Profile (name + nodes + last_update + switch / refresh / health check)
 #   3. Realtime Metrics (4 cards: ↑/↓ rate, conns, mem) — 2s poll
 #   4. Recent Log Tail (textarea readonly)                — 5s poll
 #
 # All realtime data goes through /api/mihomo/* — vanilla JS, no framework.
#}

<style>
    .mihomo-section-title {
        font-size: 16px;
        font-weight: 600;
        margin: 0 0 12px 0;
        padding-bottom: 6px;
        border-bottom: 1px solid #ddd;
    }
    .mihomo-status-light {
        display: inline-block;
        width: 12px;
        height: 12px;
        border-radius: 50%;
        margin-right: 6px;
        vertical-align: middle;
        background: #aaa;
    }
    .mihomo-status-light.is-running { background: #5cb85c; box-shadow: 0 0 6px #5cb85c; }
    .mihomo-status-light.is-stopped { background: #d9534f; }
    .mihomo-status-light.is-unknown { background: #f0ad4e; }
    .mihomo-metric-card {
        text-align: center;
        padding: 16px 8px;
        border: 1px solid #e5e5e5;
        border-radius: 4px;
        background: #fafafa;
    }
    .mihomo-metric-card .value {
        font-size: 22px;
        font-weight: 600;
        margin: 4px 0;
    }
    .mihomo-metric-card .label {
        font-size: 12px;
        color: #888;
        text-transform: uppercase;
    }
    .mihomo-log {
        display: block;
        width: 100%;
        max-width: 100%;
        height: 220px;
        font-family: monospace;
        font-size: 12px;
        background: #1e1e1e;
        color: #d4d4d4;
        border: 1px solid #333;
        resize: vertical;
        box-sizing: border-box;
    }
    .mihomo-banner {
        margin-bottom: 12px;
    }
</style>

<div class="content-box mihomo-banner" id="mihomo-status-banner" style="display:none;">
    <div class="alert alert-warning" style="margin:0;padding:8px 12px;">
        <span id="banner-text"></span>
    </div>
</div>

{# 1. Service Status #}
<div class="content-box" style="padding: 16px;">
    <div class="mihomo-section-title">
        <span class="mihomo-status-light is-unknown" id="svc-light"></span>
        服务状态
        <span id="svc-text" style="font-weight:normal;color:#888;margin-left:8px;">加载中...</span>
    </div>
    <div class="row">
        <div class="col-md-8">
            <table class="table table-condensed" style="margin-bottom: 0;">
                <tbody>
                    <tr>
                        <td style="width: 30%;">PID</td>
                        <td><span id="svc-pid">—</span></td>
                    </tr>
                    <tr>
                        <td>运行时长</td>
                        <td><span id="svc-uptime">—</span></td>
                    </tr>
                    <tr>
                        <td>版本</td>
                        <td><span id="svc-version">—</span></td>
                    </tr>
                </tbody>
            </table>
        </div>
        <div class="col-md-4 text-right">
            <button type="button" class="btn btn-success" id="btn-start" disabled>
                <i class="fa fa-play"></i> 启动
            </button>
            <button type="button" class="btn btn-danger" id="btn-stop" disabled>
                <i class="fa fa-stop"></i> 停止
            </button>
            <button type="button" class="btn btn-warning" id="btn-restart" disabled>
                <i class="fa fa-refresh"></i> 重启
            </button>
            <a class="btn btn-default" id="btn-open-ui" target="_blank">
                <i class="fa fa-external-link"></i> 打开 Dashboard UI
            </a>
            <div id="ui-bind-hint" style="font-size:11px;color:#999;margin-top:6px;display:none;">
                Dashboard 监听在 localhost——请通过 LAN 地址访问，或在防火墙放行控制端口。
            </div>
        </div>
    </div>
</div>

{# 2. Active Profile #}
<div class="content-box" style="padding: 16px; margin-top: 16px;">
    <div class="mihomo-section-title">当前配置</div>
    <div class="row">
        <div class="col-md-8">
            <table class="table table-condensed" style="margin-bottom: 0;">
                <tbody>
                    <tr>
                        <td style="width: 30%;">名称</td>
                        <td><strong><span id="profile-name">—</span></strong>
                            <span class="label label-default" id="profile-source" style="margin-left:6px;">—</span>
                        </td>
                    </tr>
                    <tr>
                        <td>节点数</td>
                        <td><span id="profile-nodes">—</span></td>
                    </tr>
                    <tr>
                        <td>最近更新</td>
                        <td><span id="profile-last-update">—</span></td>
                    </tr>
                </tbody>
            </table>
        </div>
        <div class="col-md-4 text-right">
            <div class="btn-group">
                <button type="button" class="btn btn-default dropdown-toggle" data-toggle="dropdown" id="btn-switch-profile">
                    <i class="fa fa-exchange"></i> 切换配置 <span class="caret"></span>
                </button>
                <ul class="dropdown-menu" id="profile-list" style="right:0;left:auto;"></ul>
            </div>
            <button type="button" class="btn btn-default" id="btn-refresh-sub">
                <i class="fa fa-cloud-download"></i> 刷新订阅
            </button>
            <button type="button" class="btn btn-default" id="btn-health-check">
                <i class="fa fa-bolt"></i> 健康检查
            </button>
        </div>
    </div>
    <div id="health-result" style="margin-top: 12px; display: none;">
        <div class="alert alert-info" style="margin-bottom:0;padding:8px 12px;">
            <span id="health-text"></span>
            <button type="button" class="btn btn-xs btn-default pull-right" id="btn-clear-health">清空</button>
        </div>
    </div>
</div>

{# 3. Realtime Metrics #}
<div class="content-box" style="padding: 16px; margin-top: 16px;">
    <div class="mihomo-section-title">实时指标</div>
    <div class="row">
        <div class="col-md-3">
            <div class="mihomo-metric-card">
                <div class="label"><i class="fa fa-arrow-up"></i> 上传</div>
                <div class="value" id="metric-up-rate">—</div>
                <div class="label" id="metric-up-total">— total</div>
            </div>
        </div>
        <div class="col-md-3">
            <div class="mihomo-metric-card">
                <div class="label"><i class="fa fa-arrow-down"></i> 下载</div>
                <div class="value" id="metric-down-rate">—</div>
                <div class="label" id="metric-down-total">— total</div>
            </div>
        </div>
        <div class="col-md-3">
            <div class="mihomo-metric-card">
                <div class="label">连接数</div>
                <div class="value" id="metric-connections">—</div>
                <div class="label" id="metric-connection-total">total —</div>
            </div>
        </div>
        <div class="col-md-3">
            <div class="mihomo-metric-card">
                <div class="label">内存</div>
                <div class="value" id="metric-memory">—</div>
                <div class="label">&nbsp;</div>
            </div>
        </div>
    </div>
</div>

{# 4. Recent Log Tail #}
<div class="content-box" style="padding: 16px; margin-top: 16px;">
    <div class="mihomo-section-title">
        最近日志
        <span style="font-weight:normal;color:#888;font-size:12px;">（最近 30 行）</span>
    </div>
    <textarea class="mihomo-log" id="log-tail" readonly></textarea>
</div>

<script>
(function() {
    'use strict';

    // ----- helpers -----
    function fmtBytes(n) {
        if (n === null || n === undefined || isNaN(n)) return '—';
        if (n < 1024) return n + ' B';
        if (n < 1024 * 1024) return (n / 1024).toFixed(1) + ' KB';
        if (n < 1024 * 1024 * 1024) return (n / 1048576).toFixed(2) + ' MB';
        return (n / 1073741824).toFixed(2) + ' GB';
    }
    function fmtRate(n) {
        if (n === null || n === undefined || isNaN(n)) return '—';
        return fmtBytes(n) + '/s';
    }
    function fmtUptime(s) {
        if (!s) return '—';
        var d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600), m = Math.floor(s % 3600 / 60);
        if (d > 0) return d + 'd ' + h + 'h ' + m + 'm';
        if (h > 0) return h + 'h ' + m + 'm';
        return m + 'm';
    }
    function setLight(state) {
        var el = document.getElementById('svc-light');
        el.className = 'mihomo-status-light is-' + state;
    }
    function showBanner(text) {
        var b = document.getElementById('mihomo-status-banner');
        document.getElementById('banner-text').textContent = text;
        b.style.display = 'block';
    }
    function hideBanner() {
        document.getElementById('mihomo-status-banner').style.display = 'none';
    }

    // ----- exponential-backoff poller -----
    function poller(url, intervalMs, onSuccess, onFailure) {
        var backoff = intervalMs;
        var timer = null;
        var stopped = false;
        function tick() {
            if (stopped) return;
            fetch(url, {credentials: 'same-origin'})
                .then(function(r) { return r.json(); })
                .then(function(j) {
                    backoff = intervalMs;
                    hideBanner();
                    onSuccess(j);
                    if (!stopped) timer = setTimeout(tick, backoff);
                })
                .catch(function(err) {
                    backoff = Math.min(backoff * 2, 10000);
                    if (onFailure) onFailure(err);
                    showBanner('重新连接中...');
                    if (!stopped) timer = setTimeout(tick, backoff);
                });
        }
        tick();
        return {
            stop: function() { stopped = true; if (timer) clearTimeout(timer); },
            resume: function() { stopped = false; tick(); }
        };
    }

    // ----- status -----
    var statusPoller = poller('/api/mihomo/service/status', 2000, function(j) {
        var running = j.status === 'running';
        setLight(running ? 'running' : 'stopped');
        document.getElementById('svc-text').textContent = running
            ? '运行中' : '已停止';
        document.getElementById('svc-pid').textContent = j.pid || '—';
        document.getElementById('svc-uptime').textContent = fmtUptime(j.uptime);
        document.getElementById('svc-version').textContent = j.version || '—';
        document.getElementById('btn-start').disabled = running;
        document.getElementById('btn-stop').disabled = !running;
        document.getElementById('btn-restart').disabled = !running;
    });

    // ----- profile -----
    function loadActiveProfile() {
        fetch('/api/mihomo/profiles/active', {credentials: 'same-origin'})
            .then(function(r) { return r.json(); })
            .then(function(j) {
                document.getElementById('profile-name').textContent = j.name || '—';
                document.getElementById('profile-source').textContent = j.source_type || 'manual';
                document.getElementById('profile-nodes').textContent = j.node_count != null ? j.node_count : '—';
                document.getElementById('profile-last-update').textContent = j.last_update || '—';
                document.getElementById('btn-refresh-sub').disabled = (j.source_type !== 'subscription');
            }).catch(function(){});
    }
    function loadProfileList() {
        fetch('/api/mihomo/profiles/searchItem', {credentials: 'same-origin'})
            .then(function(r) { return r.json(); })
            .then(function(j) {
                var ul = document.getElementById('profile-list');
                ul.innerHTML = '';
                (j.rows || []).forEach(function(p) {
                    var li = document.createElement('li');
                    var a = document.createElement('a');
                    a.href = '#';
                    a.textContent = p.name + (p.active ? ' ✓' : '');
                    a.onclick = function(ev) {
                        ev.preventDefault();
                        activateProfile(p.name);
                    };
                    li.appendChild(a);
                    ul.appendChild(li);
                });
            }).catch(function(){});
    }
    function activateProfile(name) {
        fetch('/api/mihomo/profiles/activate/' + encodeURIComponent(name),
              {method: 'POST', credentials: 'same-origin',
               headers: {'X-Requested-With': 'XMLHttpRequest'}})
            .then(function(r) { return r.json(); })
            .then(function(j) {
                if (j.status === 'ok') {
                    loadActiveProfile(); loadProfileList();
                } else {
                    alert(j.message || 'Switch failed');
                }
            });
    }
    loadActiveProfile();
    loadProfileList();

    // ----- service buttons -----
    var svcPending = false;
    function svcAction(action) {
        if (svcPending) return;
        svcPending = true;
        // Optimistic UI: disable buttons immediately while the action runs.
        document.getElementById('btn-start').disabled = true;
        document.getElementById('btn-stop').disabled = true;
        document.getElementById('btn-restart').disabled = true;
        var prevText = document.getElementById('svc-text').textContent;
        document.getElementById('svc-text').textContent = '请稍候...';
        fetch('/api/mihomo/service/' + action, {method: 'POST', credentials: 'same-origin',
                                                headers: {'X-Requested-With': 'XMLHttpRequest'}})
            .then(function(r) { return r.json(); })
            .then(function(j) {
                if (j.status !== 'ok') {
                    document.getElementById('svc-text').textContent = j.message || prevText;
                }
                // Let the 2s poller restore button states — configd type:script
                // actions return before the rc.d script finishes.
            })
            .catch(function() {
                document.getElementById('svc-text').textContent = prevText;
            })
            .finally(function() {
                svcPending = false;
            });
    }
    document.getElementById('btn-start').onclick   = function(){ svcAction('start'); };
    document.getElementById('btn-stop').onclick    = function(){ svcAction('stop'); };
    document.getElementById('btn-restart').onclick = function(){ svcAction('restart'); };

    // ----- open dashboard ui -----
    (function() {
        var ec = '{{ externalController }}';
        var host = ec.split(':')[0];
        var port = ec.split(':')[1] || '9090';
        var publicHost = host;
        if (host === '0.0.0.0' || host === '127.0.0.1' || host === 'localhost' || host === '::') {
            document.getElementById('ui-bind-hint').style.display = 'block';
            publicHost = window.location.hostname;
        }
        document.getElementById('btn-open-ui').href = 'http://' + publicHost + ':' + port + '/ui/';
    })();

    // ----- refresh subscription -----
    document.getElementById('btn-refresh-sub').onclick = function() {
        var btn = this; btn.disabled = true;
        fetch('/api/mihomo/profiles/refreshActive', {method: 'POST', credentials: 'same-origin',
                                                     headers: {'X-Requested-With': 'XMLHttpRequest'}})
            .then(function(r) { return r.json(); })
            .then(function(j) {
                if (j.status !== 'ok') { alert(j.message || 'refresh failed'); btn.disabled = false; return; }
                var poll = setInterval(function() {
                    fetch('/api/mihomo/profiles/active', {credentials: 'same-origin'})
                        .then(function(r) { return r.json(); })
                        .then(function(jj) {
                            if (jj.last_status === 'done' || jj.last_status === 'failed') {
                                clearInterval(poll); btn.disabled = false; loadActiveProfile();
                            }
                        });
                }, 2000);
            });
    };

    // ----- health check -----
    var healthPollTimer = null;
    document.getElementById('btn-health-check').onclick = function() {
        var btn = this; btn.disabled = true;
        document.getElementById('health-result').style.display = 'block';
        document.getElementById('health-text').textContent = '正在执行健康检查...';
        fetch('/api/mihomo/dashboard/healthCheck', {method: 'POST', credentials: 'same-origin',
                                                   headers: {'X-Requested-With': 'XMLHttpRequest', 'Content-Type': 'application/json'},
                                                   body: JSON.stringify({mode: 'quick'})})
            .then(function(r) { return r.json(); })
            .then(function(j) {
                if (j.status !== 'ok') {
                    document.getElementById('health-text').textContent = j.message || 'failed';
                    btn.disabled = false; return;
                }
                var uuid = j.uuid;
                healthPollTimer = setInterval(function() {
                    fetch('/api/mihomo/dashboard/healthProgress?uuid=' + encodeURIComponent(uuid),
                          {credentials: 'same-origin'})
                        .then(function(r) { return r.json(); })
                        .then(function(p) {
                            if (p.state === 'done') {
                                clearInterval(healthPollTimer);
                                btn.disabled = false;
                                var r = p.result || {};
                                document.getElementById('health-text').textContent =
                                    '存活: ' + (r.alive || 0)
                                    + ' / 失效: ' + (r.dead || 0);
                            } else if (p.state === 'failed') {
                                clearInterval(healthPollTimer);
                                btn.disabled = false;
                                document.getElementById('health-text').textContent =
                                    '健康检查失败: ' + (p.message || '');
                            } else if (p.progress) {
                                document.getElementById('health-text').textContent =
                                    '测试中 ' + p.progress.done + '/' + p.progress.total;
                            }
                        });
                }, 2000);
            });
    };
    document.getElementById('btn-clear-health').onclick = function() {
        document.getElementById('health-result').style.display = 'none';
        if (healthPollTimer) clearInterval(healthPollTimer);
    };

    // ----- traffic -----
    var trafficPoller = poller('/api/mihomo/dashboard/traffic', 2000, function(j) {
        document.getElementById('metric-up-rate').textContent     = fmtRate(j.upRate);
        document.getElementById('metric-down-rate').textContent   = fmtRate(j.downRate);
        document.getElementById('metric-up-total').textContent    = fmtBytes(j.upTotal) + ' total';
        document.getElementById('metric-down-total').textContent  = fmtBytes(j.downTotal) + ' total';
        document.getElementById('metric-connections').textContent = j.connections != null ? j.connections : '—';
        document.getElementById('metric-connection-total').textContent =
            'total ' + (j.connectionTotal != null ? j.connectionTotal : '—');
        document.getElementById('metric-memory').textContent      = fmtBytes(j.memory);
    });

    // ----- log tail -----
    var logPoller = poller('/api/mihomo/dashboard/logs?lines=30', 5000, function(j) {
        var ta = document.getElementById('log-tail');
        var atBottom = (ta.scrollTop + ta.clientHeight) >= (ta.scrollHeight - 4);
        ta.value = j.logs || '';
        if (atBottom) ta.scrollTop = ta.scrollHeight;
    });

    // ----- pause when hidden -----
    document.addEventListener('visibilitychange', function() {
        if (document.hidden) {
            statusPoller.stop(); trafficPoller.stop(); logPoller.stop();
        } else {
            statusPoller.resume(); trafficPoller.resume(); logPoller.resume();
            loadActiveProfile(); loadProfileList();
        }
    });
})();
</script>
