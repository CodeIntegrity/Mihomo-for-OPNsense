<?php
require_once 'guiconfig.inc';
require_once 'includes/mihomo_lib.inc.php';
include 'head.inc';
include 'fbegin.inc';

$profile = readActiveProfile();
$profiles = readProfiles();
$profileCount = count($profiles);
$currentProfileMeta = ($profile && isset($profiles[$profile])) ? $profiles[$profile] : null;

// Handle POST actions
$message = '';
$message_type = 'info';

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $action = $_POST['action'] ?? '';

    if ($action === 'start') {
        list($ok, $msg) = startMihomo();
        $message = $msg;
        $message_type = $ok ? 'success' : 'danger';
    } elseif ($action === 'stop') {
        list($ok, $msg) = stopMihomo();
        $message = $msg;
        $message_type = $ok ? 'success' : 'danger';
    } elseif ($action === 'restart') {
        list($ok, $msg) = restartMihomo();
        $message = $msg;
        $message_type = $ok ? 'success' : 'danger';
    } elseif ($action === 'activate_profile') {
        $target = $_POST['profile'] ?? '';
        if ($target && isset($profiles[$target])) {
            list($ok, $msg) = activateProfile($target);
            $message = $msg;
            $message_type = $ok ? 'success' : 'danger';
            if ($ok) {
                $profile = $target;
                $currentProfileMeta = $profiles[$target] ?? null;
            }
        }
    } elseif ($action === 'refresh_subscription') {
        $subId = $currentProfileMeta['sub_id'] ?? null;
        if ($subId) {
            mihomoExecBackground('bash /usr/local/etc/mihomo/sub/sub.sh ' . escapeshellarg($subId));
            $message = dgettext('mihomo', 'Subscription refresh triggered. Please wait...');
            $message_type = 'success';
        } else {
            $message = dgettext('mihomo', 'Active profile is not linked to a subscription.');
            $message_type = 'warning';
        }
    } elseif ($action === 'health_check') {
        $mode = ($_POST['mode'] ?? 'quick') === 'full' ? 'full' : 'quick';
        $uuid = bin2hex(random_bytes(16));
        $pfName = escapeshellarg($profile ?: '');
        mihomoExecBackground(
            'bash /usr/local/etc/mihomo/sub/mihomo_health_check.sh ' .
            escapeshellarg($uuid) . ' ' . $pfName . ' ' . $mode
        );
        $message = dgettext('mihomo', 'Health check started. Results will appear below.');
        $message_type = 'info';
    }
}

$serviceStatus = getMihomoStatus();
$controller = controllerFromBase();
$dashboardUrl = '';
if ($controller) {
    $host = explode(':', $controller)[0];
    $port = explode(':', $controller)[1] ?? '9090';
    $isLocalhost = in_array($host, ['127.0.0.1', '0.0.0.0', 'localhost']);
    $dashboardUrl = $isLocalhost ? '' : "http://{$host}:{$port}/ui/";
}
?>

<style>
.mihomo-dashboard {}
.mihomo-status-box {
    display: flex;
    align-items: center;
    gap: 12px;
    padding: 14px 16px;
    border-radius: 3px;
    border: 1px solid #d8dee3;
    background: #f7f7f7;
    color: #333;
    line-height: 1.5;
}
.mihomo-status-box.is-running { background: #f3fbf4; border-color: #b7dec0; }
.mihomo-status-box.is-stopped { background: #fff5f5; border-color: #e5bcbc; }
.mihomo-status-light {
    width: 12px; height: 12px; min-width: 12px;
    border-radius: 50%; display: inline-block;
    box-shadow: inset 0 0 0 1px rgba(0,0,0,0.12);
}
.mihomo-status-light.is-running { background: #51a351; }
.mihomo-status-light.is-stopped { background: #d9534f; }
.mihomo-section-title {
    display: flex; align-items: center; gap: 8px;
    font-weight: 700; color: #333; padding: 2px 0;
}
.mihomo-section-title .fa { color: #777; width: 14px; text-align: center; }
.mihomo-action-bar {
    display: flex; flex-wrap: wrap; gap: 8px; align-items: center;
}
.mihomo-action-bar .btn { min-width: 80px; font-weight: 600; }
.mihomo-metrics {
    display: grid; grid-template-columns: repeat(4, 1fr); gap: 12px;
}
.mihomo-metric-card {
    text-align: center; padding: 16px 8px;
    background: #f9f9f9; border: 1px solid #e0e0e0; border-radius: 3px;
}
.mihomo-metric-value { font-size: 20px; font-weight: 700; color: #333; }
.mihomo-metric-label { font-size: 11px; color: #888; margin-top: 4px; }
.mihomo-log-area { font-family: monospace; font-size: 12px; }
.mihomo-panel-cell { padding-top: 10px !important; padding-bottom: 10px !important; }
.mihomo-reconnect { color: #f0ad4e; font-weight: 600; }
.mihomo-localhost-hint { color: #999; font-size: 12px; }
.health-result { margin-top: 10px; padding: 10px; background: #f9f9f9; border-radius: 3px; }
.health-result .alive { color: #51a351; }
.health-result .dead { color: #d9534f; }
</style>

<?php if ($message): ?>
<div>
    <div class="alert alert-<?= htmlspecialchars($message_type, ENT_QUOTES); ?>">
        <pre style="margin:0;border:0;background:transparent;padding:0;white-space:pre-wrap;word-break:break-word;"><?= htmlspecialchars($message, ENT_QUOTES); ?></pre>
    </div>
</div>
<?php endif; ?>

<?php if (!isMigrated()): ?>
<div class="alert alert-danger">
    <strong><?= dgettext('mihomo', 'Migration required!') ?></strong>
    <?= dgettext('mihomo', 'Please run migrate.sh or re-run install.sh to upgrade your configuration to v2 format.') ?>
    <pre style="margin:8px 0 0;white-space:pre-wrap;"><?= htmlspecialchars(getMigrationError() ?: '', ENT_QUOTES); ?></pre>
</div>
<?php endif; ?>

<section class="page-content-main">
<div class="container-fluid">
<div class="row">

<!-- ====== Service Status ====== -->
<section class="col-xs-12">
    <div class="content-box tab-content table-responsive __mb">
        <table class="table table-striped">
            <tbody>
                <tr>
                    <td class="mihomo-panel-cell">
                        <div class="mihomo-section-title">
                            <i class="fa fa-heartbeat"></i>
                            <span><?= dgettext('mihomo', 'Service Status') ?></span>
                        </div>
                    </td>
                </tr>
                <tr>
                    <td>
                        <div id="mihomo-status-box" class="mihomo-status-box">
                            <span id="mihomo-status-light" class="mihomo-status-light"></span>
                            <span id="mihomo-status-text" style="font-weight:600;"></span>
                            <span id="mihomo-status-detail" style="color:#666;font-size:12px;"></span>
                        </div>
                        <div class="mihomo-action-bar" style="margin-top:10px;">
                            <form method="post" style="display:inline;">
                                <button type="submit" name="action" value="start" class="btn btn-success" id="btn-start">
                                    <i class="fa fa-play"></i> <?= dgettext('mihomo', 'Start') ?>
                                </button>
                                <button type="submit" name="action" value="stop" class="btn btn-danger" id="btn-stop">
                                    <i class="fa fa-stop"></i> <?= dgettext('mihomo', 'Stop') ?>
                                </button>
                                <button type="submit" name="action" value="restart" class="btn btn-warning" id="btn-restart">
                                    <i class="fa fa-refresh"></i> <?= dgettext('mihomo', 'Restart') ?>
                                </button>
                            </form>
                            <?php if ($dashboardUrl): ?>
                            <a href="<?= htmlspecialchars($dashboardUrl, ENT_QUOTES); ?>" target="_blank" class="btn btn-default">
                                <i class="fa fa-external-link"></i> <?= dgettext('mihomo', 'Open Dashboard UI') ?>
                            </a>
                            <?php else: ?>
                            <span class="mihomo-localhost-hint">
                                <i class="fa fa-info-circle"></i>
                                <?= dgettext('mihomo', 'Dashboard listens on localhost. Access via LAN or allow firewall port.') ?>
                            </span>
                            <?php endif; ?>
                        </div>
                    </td>
                </tr>
            </tbody>
        </table>
    </div>
</section>

<!-- ====== Active Profile ====== -->
<section class="col-xs-12">
    <div class="content-box tab-content table-responsive __mb">
        <table class="table table-striped">
            <tbody>
                <tr>
                    <td class="mihomo-panel-cell">
                        <div class="mihomo-section-title">
                            <i class="fa fa-tag"></i>
                            <span><?= dgettext('mihomo', 'Active Profile') ?></span>
                        </div>
                    </td>
                </tr>
                <tr>
                    <td>
                        <div id="profile-info">
                            <?php if ($profile): ?>
                            <strong><?= htmlspecialchars($profile, ENT_QUOTES); ?></strong>
                            <?php if ($currentProfileMeta): ?>
                            <span style="color:#888;margin-left:8px;">
                                <?= (int)($currentProfileMeta['node_count'] ?? 0); ?> <?= dgettext('mihomo', 'nodes') ?>
                                |
                                <?= dgettext('mihomo', 'Updated') ?>: <?= htmlspecialchars($currentProfileMeta['last_update'] ?? 'N/A', ENT_QUOTES); ?>
                            </span>
                            <?php endif; ?>
                            <?php else: ?>
                            <span style="color:#999;"><?= dgettext('mihomo', 'No active profile') ?></span>
                            <?php endif; ?>
                        </div>
                        <div class="mihomo-action-bar" style="margin-top:10px;">
                            <form method="post" style="display:flex;gap:8px;align-items:center;">
                                <select name="profile" class="form-control" style="width:auto;" id="profile-select">
                                    <option value=""><?= dgettext('mihomo', 'Switch Profile') ?>...</option>
                                    <?php foreach ($profiles as $p): ?>
                                    <option value="<?= htmlspecialchars($p['name'], ENT_QUOTES); ?>" <?= $profile === $p['name'] ? 'selected' : ''; ?>>
                                        <?= htmlspecialchars($p['name'], ENT_QUOTES); ?>
                                        (<?= $p['source_type'] === 'subscription' ? dgettext('mihomo', 'sub') : dgettext('mihomo', 'manual'); ?>
                                        | <?= (int)($p['node_count'] ?? 0); ?> <?= dgettext('mihomo', 'nodes') ?>)
                                    </option>
                                    <?php endforeach; ?>
                                </select>
                                <button type="submit" name="action" value="activate_profile" class="btn btn-primary" id="btn-switch">
                                    <i class="fa fa-check"></i> <?= dgettext('mihomo', 'Activate') ?>
                                </button>
                            </form>
                            <?php if ($currentProfileMeta && $currentProfileMeta['source_type'] === 'subscription'): ?>
                            <form method="post" style="display:inline;">
                                <button type="submit" name="action" value="refresh_subscription" class="btn btn-default" id="btn-refresh-sub">
                                    <i class="fa fa-sync"></i> <?= dgettext('mihomo', 'Refresh Subscription') ?>
                                </button>
                            </form>
                            <?php endif; ?>
                            <form method="post" style="display:inline;">
                                <input type="hidden" name="mode" value="quick">
                                <button type="submit" name="action" value="health_check" class="btn btn-info" id="btn-health">
                                    <i class="fa fa-heartbeat"></i> <?= dgettext('mihomo', 'Health Check') ?>
                                </button>
                            </form>
                        </div>
                        <div id="health-result" class="health-result" style="display:none;"></div>
                    </td>
                </tr>
            </tbody>
        </table>
    </div>
</section>

<!-- ====== Realtime Metrics ====== -->
<section class="col-xs-12">
    <div class="content-box tab-content table-responsive __mb">
        <table class="table table-striped">
            <tbody>
                <tr>
                    <td class="mihomo-panel-cell">
                        <div class="mihomo-section-title">
                            <i class="fa fa-tachometer"></i>
                            <span><?= dgettext('mihomo', 'Realtime Metrics') ?></span>
                            <span style="font-size:11px;color:#aaa;margin-left:auto;"><?= dgettext('mihomo', 'poll every 2s') ?></span>
                        </div>
                    </td>
                </tr>
                <tr>
                    <td>
                        <div class="mihomo-metrics" id="metrics-grid">
                            <div class="mihomo-metric-card">
                                <div class="mihomo-metric-value" id="metric-up">--</div>
                                <div class="mihomo-metric-label"><?= dgettext('mihomo', 'Upload') ?></div>
                            </div>
                            <div class="mihomo-metric-card">
                                <div class="mihomo-metric-value" id="metric-down">--</div>
                                <div class="mihomo-metric-label"><?= dgettext('mihomo', 'Download') ?></div>
                            </div>
                            <div class="mihomo-metric-card">
                                <div class="mihomo-metric-value" id="metric-conns">--</div>
                                <div class="mihomo-metric-label"><?= dgettext('mihomo', 'Connections') ?></div>
                            </div>
                            <div class="mihomo-metric-card">
                                <div class="mihomo-metric-value" id="metric-mem">--</div>
                                <div class="mihomo-metric-label"><?= dgettext('mihomo', 'Memory') ?></div>
                            </div>
                        </div>
                        <div id="metrics-error" style="display:none;color:#d9534f;margin-top:8px;"></div>
                    </td>
                </tr>
            </tbody>
        </table>
    </div>
</section>

<!-- ====== Recent Log Tail ====== -->
<section class="col-xs-12">
    <div class="content-box tab-content table-responsive __mb">
        <table class="table table-striped">
            <tbody>
                <tr>
                    <td class="mihomo-panel-cell">
                        <div class="mihomo-section-title">
                            <i class="fa fa-file-text-o"></i>
                            <span><?= dgettext('mihomo', 'Recent Log') ?></span>
                            <span style="font-size:11px;color:#aaa;margin-left:auto;"><?= dgettext('mihomo', 'last 30 lines') ?></span>
                        </div>
                    </td>
                </tr>
                <tr>
                    <td>
                        <textarea id="log-tail" class="form-control mihomo-log-area" rows="12" readonly style="max-width:none;"></textarea>
                    </td>
                </tr>
            </tbody>
        </table>
    </div>
</section>

</div>
</div>
</section>

<script>
(function() {
    'use strict';

    // ── State ──
    var pollTimer = null;
    var logTimer = null;
    var retryDelay = 1000;
    var maxRetryDelay = 10000;
    var visible = true;
    var healthUuid = null;
    var healthTimer = null;

    // ── Helpers ──
    function fmtBytes(bytes) {
        if (bytes === 0) return '0 B/s';
        var units = ['B/s', 'KB/s', 'MB/s', 'GB/s'];
        var i = 0;
        var v = Math.abs(bytes);
        while (v >= 1000 && i < units.length - 1) { v /= 1000; i++; }
        return (bytes < 0 ? '-' : '') + v.toFixed(1) + ' ' + units[i];
    }

    function fmtMem(bytes) {
        if (bytes === 0) return '0 B';
        var units = ['B', 'KB', 'MB', 'GB'];
        var i = 0;
        var v = bytes;
        while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
        return v.toFixed(1) + ' ' + units[i];
    }

    function fmtNum(n) {
        if (n >= 1000000000) return (n / 1000000000).toFixed(1) + 'G';
        if (n >= 1000000) return (n / 1000000).toFixed(1) + 'M';
        if (n >= 1000) return (n / 1000).toFixed(1) + 'K';
        return String(n);
    }

    // ── Service Status ──
    function updateStatus() {
        fetch('/status_mihomo.php', { cache: 'no-store' })
            .then(function(r) { return r.json(); })
            .then(function(data) {
                retryDelay = 1000;
                var box = document.getElementById('mihomo-status-box');
                var light = document.getElementById('mihomo-status-light');
                var text = document.getElementById('mihomo-status-text');
                var detail = document.getElementById('mihomo-status-detail');
                var running = data.status === 'running';

                box.className = 'mihomo-status-box ' + (running ? 'is-running' : 'is-stopped');
                light.className = 'mihomo-status-light ' + (running ? 'is-running' : 'is-stopped');
                text.textContent = running ? '<?= dgettext('mihomo', 'mihomo is running') ?>' : '<?= dgettext('mihomo', 'mihomo is stopped') ?>';

                var parts = [];
                if (data.uptime) parts.push('uptime ' + data.uptime);
                if (data.pid) parts.push('PID ' + data.pid);
                detail.textContent = parts.join('  |  ');

                // Enable/disable buttons
                document.getElementById('btn-start').disabled = running;
                document.getElementById('btn-stop').disabled = !running;
                document.getElementById('btn-restart').disabled = !running;
            })
            .catch(function() {
                retryDelay = Math.min(retryDelay * 2, maxRetryDelay);
                var text = document.getElementById('mihomo-status-text');
                text.innerHTML = '<span class="mihomo-reconnect"><?= dgettext('mihomo', 'Reconnecting...') ?></span>';
            });
    }

    // ── Metrics ──
    function updateMetrics() {
        fetch('/status_mihomo_traffic.php', { cache: 'no-store' })
            .then(function(r) { return r.json(); })
            .then(function(d) {
                document.getElementById('metric-up').textContent = fmtBytes(d.upRate);
                document.getElementById('metric-down').textContent = fmtBytes(d.downRate);
                document.getElementById('metric-conns').textContent = fmtNum(d.connections);
                document.getElementById('metric-mem').textContent = fmtMem(d.memory);
                var errEl = document.getElementById('metrics-error');
                errEl.style.display = 'none';
            })
            .catch(function() {
                var errEl = document.getElementById('metrics-error');
                errEl.style.display = 'block';
                errEl.textContent = '<?= dgettext('mihomo', 'API unavailable, check external-controller settings') ?>';
            });
    }

    // ── Log Tail ──
    function updateLogs() {
        fetch('/status_mihomo_logs.php?lines=30', { cache: 'no-store' })
            .then(function(r) {
                if (!r.ok) throw new Error('HTTP ' + r.status);
                return r.text();
            })
            .then(function(text) {
                var ta = document.getElementById('log-tail');
                ta.value = text;
                ta.scrollTop = ta.scrollHeight;
            })
            .catch(function() {});
    }

    // ── Health Check Polling ──
    function pollHealth() {
        if (!healthUuid) return;
        fetch('/status_mihomo_health.php?uuid=' + encodeURIComponent(healthUuid), { cache: 'no-store' })
            .then(function(r) { return r.json(); })
            .then(function(data) {
                var el = document.getElementById('health-result');
                el.style.display = 'block';
                if (data.state === 'running') {
                    el.innerHTML = '<i class="fa fa-spinner fa-spin"></i> ' +
                        '<?= dgettext('mihomo', 'Checking') ?>... ' + data.progress.done + '/' + data.progress.total;
                } else if (data.state === 'done') {
                    var r = data.result;
                    el.innerHTML =
                        '<span class="alive"><i class="fa fa-check-circle"></i> <?= dgettext('mihomo', 'Alive') ?>: ' + r.alive + '</span>' +
                        ' &nbsp;|&nbsp; ' +
                        '<span class="dead"><i class="fa fa-times-circle"></i> <?= dgettext('mihomo', 'Dead') ?>: ' + r.dead + '</span>';
                    if (r.dead_list && r.dead_list.length > 0) {
                        el.innerHTML += '<br><small style="color:#999;">' + r.dead_list.join(', ') + '</small>';
                    }
                    healthUuid = null;
                    if (healthTimer) { clearInterval(healthTimer); healthTimer = null; }
                } else {
                    el.innerHTML = '<span class="dead"><?= dgettext('mihomo', 'Health check failed') ?></span>';
                    healthUuid = null;
                    if (healthTimer) { clearInterval(healthTimer); healthTimer = null; }
                }
            });
    }

    // ── Main loop ──
    function startPolling() {
        updateStatus();
        updateMetrics();
        updateLogs();
        pollTimer = setInterval(function() {
            updateStatus();
            updateMetrics();
        }, 2000);
        logTimer = setInterval(updateLogs, 5000);
    }

    function stopPolling() {
        if (pollTimer) { clearInterval(pollTimer); pollTimer = null; }
        if (logTimer) { clearInterval(logTimer); logTimer = null; }
    }

    // ── Visibility change ──
    document.addEventListener('visibilitychange', function() {
        visible = !document.hidden;
        if (visible) {
            startPolling();
        } else {
            stopPolling();
        }
    });

    // ── Init ──
    startPolling();

    // Check for health check redirect (after POST)
    <?php if (isset($uuid)): ?>
    healthUuid = '<?= htmlspecialchars($uuid, ENT_QUOTES); ?>';
    if (healthTimer) clearInterval(healthTimer);
    healthTimer = setInterval(pollHealth, 2000);
    pollHealth();
    <?php endif; ?>
})();
</script>

<?php include 'foot.inc'; ?>
