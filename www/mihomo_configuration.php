<?php
require_once 'guiconfig.inc';
require_once 'includes/mihomo_lib.inc.php';
include 'head.inc';
include 'fbegin.inc';

// ── State ──
$message = '';
$message_type = 'info';
$activeTab = 'settings';

// ── Handle POST ──
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $action = $_POST['action'] ?? '';
    $activeTab = $_POST['_tab'] ?? $activeTab;

    // --- Settings Save ---
    if ($action === 'save_settings') {
        $base = file_exists(MIHOMO_BASE_YAML) ? mihomoYamlParse(file_get_contents(MIHOMO_BASE_YAML)) : [];

        // Group A: General
        if (isset($_POST['port'])) $base['port'] = (int)$_POST['port'];
        if (isset($_POST['socks-port'])) $base['socks-port'] = (int)$_POST['socks-port'];
        if (isset($_POST['mixed-port'])) $base['mixed-port'] = (int)$_POST['mixed-port'];
        $base['allow-lan'] = !empty($_POST['allow-lan']);
        if (isset($_POST['bind-address'])) $base['bind-address'] = trim($_POST['bind-address']);
        if (isset($_POST['mode'])) $base['mode'] = trim($_POST['mode']);
        if (isset($_POST['log-level'])) $base['log-level'] = trim($_POST['log-level']);
        $base['ipv6'] = !empty($_POST['ipv6']);
        $base['tcp-concurrent'] = !empty($_POST['tcp-concurrent']);
        if (isset($_POST['find-process-mode'])) $base['find-process-mode'] = trim($_POST['find-process-mode']);
        if (isset($_POST['global-client-fingerprint'])) $base['global-client-fingerprint'] = trim($_POST['global-client-fingerprint']);
        $base['unified-delay'] = !empty($_POST['unified-delay']);
        if (isset($_POST['interface-name']) && $_POST['interface-name'] !== '(auto)') $base['interface-name'] = trim($_POST['interface-name']);

        // Group B: External Controller
        if (isset($_POST['external-controller'])) $base['external-controller'] = trim($_POST['external-controller']);
        if (isset($_POST['secret']) && trim($_POST['secret']) !== '') $base['secret'] = trim($_POST['secret']);
        $base['external-ui'] = '/usr/local/etc/mihomo/ui';

        // Group C: TUN
        if (!isset($base['tun'])) $base['tun'] = [];
        $base['tun']['enable'] = !empty($_POST['tun-enable']);
        if (isset($_POST['tun-stack'])) $base['tun']['stack'] = trim($_POST['tun-stack']);
        if (isset($_POST['tun-device'])) $base['tun']['device'] = trim($_POST['tun-device']);
        if (isset($_POST['tun-mtu'])) $base['tun']['mtu'] = (int)$_POST['tun-mtu'];
        $base['tun']['auto-route'] = !empty($_POST['tun-auto-route']);
        $base['tun']['strict-route'] = !empty($_POST['tun-strict-route']);
        $base['tun']['auto-detect-interface'] = !empty($_POST['tun-auto-detect-interface']);
        if (isset($_POST['tun-dns-hijack'])) {
            $base['tun']['dns-hijack'] = array_filter(array_map('trim', explode("\n", $_POST['tun-dns-hijack'])));
        }

        // Group D: DNS
        if (!isset($base['dns'])) $base['dns'] = [];
        $base['dns']['enable'] = !empty($_POST['dns-enable']);
        if (isset($_POST['dns-listen'])) $base['dns']['listen'] = trim($_POST['dns-listen']);
        $base['dns']['ipv6'] = !empty($_POST['dns-ipv6']);
        if (isset($_POST['dns-enhanced-mode'])) $base['dns']['enhanced-mode'] = trim($_POST['dns-enhanced-mode']);
        if (isset($_POST['dns-fake-ip-range'])) $base['dns']['fake-ip-range'] = trim($_POST['dns-fake-ip-range']);
        if (isset($_POST['dns-default-nameserver'])) {
            $base['dns']['default-nameserver'] = array_filter(array_map('trim', explode("\n", $_POST['dns-default-nameserver'])));
        }
        if (isset($_POST['dns-nameserver'])) {
            $base['dns']['nameserver'] = array_filter(array_map('trim', explode("\n", $_POST['dns-nameserver'])));
        }
        if (isset($_POST['dns-fallback'])) {
            $base['dns']['fallback'] = array_filter(array_map('trim', explode("\n", $_POST['dns-fallback'])));
        }
        if (isset($_POST['dns-fake-ip-filter'])) {
            $base['dns']['fake-ip-filter'] = array_filter(array_map('trim', explode("\n", $_POST['dns-fake-ip-filter'])));
        }
        $base['dns']['use-hosts'] = !empty($_POST['dns-use-hosts']);

        // Group E: Sniffer
        if (!isset($base['sniffer'])) $base['sniffer'] = [];
        $base['sniffer']['enable'] = !empty($_POST['sniffer-enable']);
        $base['sniffer']['force-dns-mapping'] = !empty($_POST['sniffer-force-dns-mapping']);
        $base['sniffer']['parse-pure-ip'] = !empty($_POST['sniffer-parse-pure-ip']);
        if (!isset($base['sniffer']['sniff'])) $base['sniffer']['sniff'] = [];
        if (isset($_POST['sniffer-http-ports'])) {
            $ports = array_map('trim', explode(',', $_POST['sniffer-http-ports']));
            $base['sniffer']['sniff']['HTTP'] = ['ports' => $ports, 'override-destination' => !empty($_POST['sniffer-override-destination'])];
        }
        if (isset($_POST['sniffer-tls-ports'])) {
            $ports = array_map('trim', explode(',', $_POST['sniffer-tls-ports']));
            $base['sniffer']['sniff']['TLS'] = ['ports' => $ports];
        }
        if (isset($_POST['sniffer-quic-ports'])) {
            $ports = array_map('trim', explode(',', $_POST['sniffer-quic-ports']));
            $base['sniffer']['sniff']['QUIC'] = ['ports' => $ports];
        }
        if (isset($_POST['sniffer-skip-domain'])) {
            $base['sniffer']['skip-domain'] = array_filter(array_map('trim', explode("\n", $_POST['sniffer-skip-domain'])));
        }

        // Write base.yaml
        try {
            lockedWrite(MIHOMO_BASE_YAML, mihomoYamlDump($base));
        } catch (RuntimeException $e) {
            $message = dgettext('mihomo', 'Failed to write base.yaml:') . ' ' . $e->getMessage();
            $message_type = 'danger';
        }

        if (!$message) {
            // Merge and apply
            $override = file_exists(MIHOMO_OVERRIDE_YAML) ? mihomoYamlParse(file_get_contents(MIHOMO_OVERRIDE_YAML)) : [];
            $activeName = readActiveProfile();
            $profileData = [];
            if ($activeName) {
                $pf = MIHOMO_PROFILES_DIR . '/' . $activeName . '.yaml';
                if (file_exists($pf)) $profileData = mihomoYamlParse(file_get_contents($pf));
            }
            $merged = mergeAll($base, $override, $profileData);
            list($ok, $msg) = atomicConfigUpdate(mihomoYamlDump($merged));
            $message = $msg;
            $message_type = $ok ? 'success' : 'danger';
        }
    }

    // --- Override Save ---
    if ($action === 'save_override') {
        $content = $_POST['override_content'] ?? '';
        if ($action === 'validate_override') {
            // Validate only
            $base = file_exists(MIHOMO_BASE_YAML) ? mihomoYamlParse(file_get_contents(MIHOMO_BASE_YAML)) : [];
            $override = mihomoYamlParse($content);
            $activeName = readActiveProfile();
            $profileData = [];
            if ($activeName) {
                $pf = MIHOMO_PROFILES_DIR . '/' . $activeName . '.yaml';
                if (file_exists($pf)) $profileData = mihomoYamlParse(file_get_contents($pf));
            }
            $merged = mergeAll($base, $override, $profileData);
            $tmpFile = '/tmp/config.yaml.validate';
            file_put_contents($tmpFile, mihomoYamlDump($merged));
            list($out, $rc) = mihomoExecCommand('/usr/local/bin/mihomo -d ' . escapeshellarg(MIHOMO_DIR) . ' -t -f ' . escapeshellarg($tmpFile));
            @unlink($tmpFile);
            $message = $rc === 0 ? dgettext('mihomo', 'Override config is valid.') : dgettext('mihomo', 'Validation failed:') . "\n" . $out;
            $message_type = $rc === 0 ? 'success' : 'danger';
        } elseif ($action === 'save_override') {
            try {
                lockedWrite(MIHOMO_OVERRIDE_YAML, $content);
                $base = file_exists(MIHOMO_BASE_YAML) ? mihomoYamlParse(file_get_contents(MIHOMO_BASE_YAML)) : [];
                $override = mihomoYamlParse($content);
                $activeName = readActiveProfile();
                $profileData = [];
                if ($activeName) {
                    $pf = MIHOMO_PROFILES_DIR . '/' . $activeName . '.yaml';
                    if (file_exists($pf)) $profileData = mihomoYamlParse(file_get_contents($pf));
                }
                $merged = mergeAll($base, $override, $profileData);
                list($ok, $msg) = atomicConfigUpdate(mihomoYamlDump($merged));
                $message = $msg;
                $message_type = $ok ? 'success' : 'danger';
            } catch (RuntimeException $e) {
                $message = dgettext('mihomo', 'Failed to save override:') . ' ' . $e->getMessage();
                $message_type = 'danger';
            }
        } elseif ($action === 'reset_override') {
            $default = "# " . dgettext('mihomo', 'User override — subscription refresh will not overwrite this file.') . "\n";
            try {
                lockedWrite(MIHOMO_OVERRIDE_YAML, $default);
                $message = dgettext('mihomo', 'Override reset to default.');
                $message_type = 'success';
            } catch (RuntimeException $e) {
                $message = $e->getMessage();
                $message_type = 'danger';
            }
        }
    }

    // --- Profile Actions ---
    if ($action === 'activate_profile') {
        $name = $_POST['profile_name'] ?? '';
        list($ok, $msg) = activateProfile($name);
        $message = $msg;
        $message_type = $ok ? 'success' : 'danger';
    }
    if ($action === 'delete_profile') {
        $name = $_POST['profile_name'] ?? '';
        $activeName = readActiveProfile();
        if ($name === $activeName) {
            $message = dgettext('mihomo', 'Cannot delete the active profile.');
            $message_type = 'danger';
        } else {
            $pf = MIHOMO_PROFILES_DIR . '/' . $name . '.yaml';
            $meta = MIHOMO_PROFILES_DIR . '/' . $name . '.meta.json';
            @unlink($pf);
            @unlink($meta);
            $message = sprintf(dgettext('mihomo', 'Profile "%s" deleted.'), $name);
            $message_type = 'success';
        }
    }
    if ($action === 'create_profile') {
        $name = preg_replace('/[^a-zA-Z0-9_-]/', '', $_POST['new_profile_name'] ?? '');
        if ($name === '') {
            $message = dgettext('mihomo', 'Invalid profile name. Only letters, numbers, hyphens and underscores allowed.');
            $message_type = 'danger';
        } else {
            $pf = MIHOMO_PROFILES_DIR . '/' . $name . '.yaml';
            if (file_exists($pf)) {
                $message = dgettext('mihomo', 'Profile already exists.');
                $message_type = 'danger';
            } else {
                if (!is_dir(MIHOMO_PROFILES_DIR)) mkdir(MIHOMO_PROFILES_DIR, 0750, true);
                file_put_contents($pf, "# Manual profile: $name\nproxies:\nproxy-groups:\nrules:\n");
                file_put_contents(MIHOMO_PROFILES_DIR . '/' . $name . '.meta.json', json_encode([
                    'source_type' => 'manual',
                    'last_update' => date('Y-m-d H:i:s'),
                    'node_count' => 0,
                ]));
                $message = sprintf(dgettext('mihomo', 'Profile "%s" created.'), $name);
                $message_type = 'success';
            }
        }
    }

    // --- Update Actions ---
    if (in_array($action, ['check_core', 'check_geoip', 'check_ui', 'update_core', 'update_geoip', 'update_ui'])) {
        $resource = str_replace(['check_', 'update_'], '', $action);
        $mode = strpos($action, 'check_') === 0 ? 'check' : 'update';

        $cmd = '';
        if ($resource === 'core' || $resource === 'geoip') {
            $cmd = '/usr/local/sbin/configctl mihomo update-' . $resource . ' ' . escapeshellarg($mode);
        } elseif ($resource === 'ui') {
            $variant = preg_replace('/[^a-z]/', '', $_POST['ui_variant'] ?? 'metacubexd');
            if (!in_array($variant, ['metacubexd', 'zashboard', 'yacd'], true)) {
                $variant = 'metacubexd';
            }
            $cmd = '/usr/local/sbin/configctl mihomo update-ui ' . escapeshellarg($mode) . ' ' . escapeshellarg($variant);
        }

        if ($cmd) {
            // Reset state file so the UI sees fresh progress immediately
            @file_put_contents("/tmp/mihomo-update-{$resource}.json",
                json_encode(['state' => 'checking', 'progress' => 1, 'message' => 'Starting...']));
            mihomoExecBackground($cmd);
            $message = $mode === 'check'
                ? sprintf(dgettext('mihomo', 'Checking %s updates...'), $resource)
                : sprintf(dgettext('mihomo', '%s update started. Do not leave this page.'), $resource);
            $message_type = 'info';
        }
    }
}

// ── Read current state ──
$base = file_exists(MIHOMO_BASE_YAML) ? mihomoYamlParse(file_get_contents(MIHOMO_BASE_YAML)) : [];
$overrideContent = file_exists(MIHOMO_OVERRIDE_YAML) ? file_get_contents(MIHOMO_OVERRIDE_YAML) : '';
$configContent = file_exists(MIHOMO_CONFIG_YAML) ? file_get_contents(MIHOMO_CONFIG_YAML) : '';
$profiles = readProfiles();
$activeProfile = readActiveProfile();
$interfaces = getNetworkInterfaces();
$logContent = '';

// Log
if (file_exists(MIHOMO_LOG)) {
    $logLines = file(MIHOMO_LOG);
    $logContent = htmlspecialchars(implode('', array_slice($logLines, -200)), ENT_QUOTES);
}

// ── Helper: generate select options ──
function selectOptions($options, $selected, $labels = null) {
    $out = '';
    foreach ($options as $i => $opt) {
        $label = $labels ? ($labels[$i] ?? $opt) : $opt;
        $sel = ($opt === $selected) ? ' selected' : '';
        $out .= '<option value="' . htmlspecialchars((string)$opt, ENT_QUOTES) . '"' . $sel . '>' . htmlspecialchars($label, ENT_QUOTES) . '</option>';
    }
    return $out;
}

function boolCheck($arr, $key, $default = false) {
    $val = $arr[$key] ?? $default;
    return $val ? 'checked' : '';
}

function nestedVal($arr, $path, $default = '') {
    $keys = explode('.', $path);
    $cur = $arr;
    foreach ($keys as $k) {
        if (!is_array($cur) || !isset($cur[$k])) return $default;
        $cur = $cur[$k];
    }
    return is_bool($cur) ? ($cur ? 'checked' : '') : (is_array($cur) ? implode("\n", $cur) : htmlspecialchars((string)$cur, ENT_QUOTES));
}
?>

<style>
.mihomo-tab-nav { margin-bottom: 0; border-bottom: 2px solid #ddd; }
.mihomo-tab-nav .btn { border-radius: 3px 3px 0 0; margin-bottom: -2px; }
.mihomo-tab-panel { display: none; }
.mihomo-tab-panel.active { display: block; }
.mihomo-section-title { display: flex; align-items: center; gap: 8px; font-weight: 700; color: #333; padding: 2px 0; }
.mihomo-section-title .fa { color: #777; width: 14px; text-align: center; }
.mihomo-field-group { margin-bottom: 20px; padding: 12px; background: #fafafa; border: 1px solid #e8e8e8; border-radius: 3px; }
.mihomo-field-group legend { font-weight: 600; color: #555; border-bottom: 1px solid #e0e0e0; padding-bottom: 6px; margin-bottom: 12px; font-size: 14px; }
.mihomo-field-group .form-group { margin-bottom: 8px; }
.mihomo-yaml-area { font-family: 'Courier New', monospace; font-size: 13px; }
.mihomo-actions { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; margin-top: 12px; }
.mihomo-table-actions { display: flex; gap: 4px; flex-wrap: wrap; }
.mihomo-update-card { padding: 14px; background: #f9f9f9; border: 1px solid #e0e0e0; border-radius: 3px; margin-bottom: 12px; }
.mihomo-update-card h4 { margin-top: 0; }
</style>

<?php if ($message): ?>
<div>
    <div class="alert alert-<?= htmlspecialchars($message_type, ENT_QUOTES); ?>">
        <pre style="margin:0;border:0;background:transparent;padding:0;white-space:pre-wrap;word-break:break-word;"><?= htmlspecialchars($message, ENT_QUOTES); ?></pre>
    </div>
</div>
<?php endif; ?>

<section class="page-content-main">
<div class="container-fluid">
<div class="row">
<section class="col-xs-12">
<div class="content-box __mb">

<!-- Tab Navigation -->
<div class="mihomo-tab-nav" style="padding:10px 10px 0 10px;">
    <a href="#settings" class="btn btn-default mihomo-tab-btn active" data-tab="settings"><?= dgettext('mihomo', 'Settings') ?></a>
    <a href="#override" class="btn btn-default mihomo-tab-btn" data-tab="override"><?= dgettext('mihomo', 'Override') ?></a>
    <a href="#profiles" class="btn btn-default mihomo-tab-btn" data-tab="profiles"><?= dgettext('mihomo', 'Profiles') ?></a>
    <a href="#yaml" class="btn btn-default mihomo-tab-btn" data-tab="yaml"><?= dgettext('mihomo', 'YAML') ?></a>
    <a href="#log" class="btn btn-default mihomo-tab-btn" data-tab="log"><?= dgettext('mihomo', 'Log') ?></a>
    <a href="#updates" class="btn btn-default mihomo-tab-btn" data-tab="updates"><?= dgettext('mihomo', 'Updates') ?></a>
</div>

<div style="padding:10px;">

<!-- ====== Tab: Settings ====== -->
<div id="tab-settings" class="mihomo-tab-panel active">
<form method="post">
<input type="hidden" name="_tab" value="settings">
<input type="hidden" name="action" value="save_settings">

<!-- Group A: General -->
<fieldset class="mihomo-field-group">
<legend><i class="fa fa-cog"></i> <?= dgettext('mihomo', 'A: General') ?></legend>
<div class="row">
<div class="col-sm-4"><div class="form-group">
<label><?= dgettext('mihomo', 'HTTP Proxy Port') ?></label>
<input type="number" name="port" class="form-control" value="<?= nestedVal($base, 'port', '7890'); ?>" min="0" max="65535">
</div></div>
<div class="col-sm-4"><div class="form-group">
<label><?= dgettext('mihomo', 'SOCKS Proxy Port') ?></label>
<input type="number" name="socks-port" class="form-control" value="<?= nestedVal($base, 'socks-port', '7891'); ?>" min="0" max="65535">
</div></div>
<div class="col-sm-4"><div class="form-group">
<label><?= dgettext('mihomo', 'Mixed Port') ?></label>
<input type="number" name="mixed-port" class="form-control" value="<?= nestedVal($base, 'mixed-port', '0'); ?>" min="0" max="65535">
</div></div>
</div>
<div class="row">
<div class="col-sm-4"><div class="form-group">
<label><?= dgettext('mihomo', 'Mode') ?></label>
<select name="mode" class="form-control">
    <?= selectOptions(['rule', 'global', 'direct'], $base['mode'] ?? 'rule'); ?>
</select>
</div></div>
<div class="col-sm-4"><div class="form-group">
<label><?= dgettext('mihomo', 'Log Level') ?></label>
<select name="log-level" class="form-control">
    <?= selectOptions(['silent', 'error', 'warning', 'info', 'debug'], $base['log-level'] ?? 'warning'); ?>
</select>
</div></div>
<div class="col-sm-4"><div class="form-group">
<label><?= dgettext('mihomo', 'Bind Address') ?></label>
<input type="text" name="bind-address" class="form-control" value="<?= nestedVal($base, 'bind-address', '*'); ?>">
</div></div>
</div>
<div class="row">
<div class="col-sm-3"><div class="checkbox"><label>
    <input type="checkbox" name="allow-lan" <?= boolCheck($base, 'allow-lan', true); ?>> <?= dgettext('mihomo', 'Allow LAN') ?>
</label></div></div>
<div class="col-sm-3"><div class="checkbox"><label>
    <input type="checkbox" name="ipv6" <?= boolCheck($base, 'ipv6', true); ?>> <?= dgettext('mihomo', 'IPv6') ?>
</label></div></div>
<div class="col-sm-3"><div class="checkbox"><label>
    <input type="checkbox" name="tcp-concurrent" <?= boolCheck($base, 'tcp-concurrent', true); ?>> <?= dgettext('mihomo', 'TCP Concurrent') ?>
</label></div></div>
<div class="col-sm-3"><div class="checkbox"><label>
    <input type="checkbox" name="unified-delay" <?= boolCheck($base, 'unified-delay'); ?>> <?= dgettext('mihomo', 'Unified Delay') ?>
</label></div></div>
</div>
<div class="row">
<div class="col-sm-4"><div class="form-group">
<label><?= dgettext('mihomo', 'Find Process Mode') ?></label>
<select name="find-process-mode" class="form-control">
    <?= selectOptions(['off', 'strict', 'always'], $base['find-process-mode'] ?? 'off'); ?>
</select>
</div></div>
<div class="col-sm-4"><div class="form-group">
<label><?= dgettext('mihomo', 'Client Fingerprint') ?></label>
<select name="global-client-fingerprint" class="form-control">
    <?= selectOptions(['chrome', 'firefox', 'safari', 'ios', 'random'], $base['global-client-fingerprint'] ?? 'chrome'); ?>
</select>
</div></div>
<div class="col-sm-4"><div class="form-group">
<label><?= dgettext('mihomo', 'Interface Name') ?></label>
<select name="interface-name" class="form-control">
    <?= selectOptions($interfaces, $base['interface-name'] ?? '(auto)'); ?>
</select>
</div></div>
</div>
</fieldset>

<!-- Group B: External Controller -->
<fieldset class="mihomo-field-group">
<legend><i class="fa fa-plug"></i> <?= dgettext('mihomo', 'B: External Controller') ?></legend>
<div class="row">
<div class="col-sm-6"><div class="form-group">
<label><?= dgettext('mihomo', 'External Controller') ?></label>
<input type="text" name="external-controller" class="form-control" value="<?= nestedVal($base, 'external-controller', '0.0.0.0:9090'); ?>">
</div></div>
<div class="col-sm-6"><div class="form-group">
<label><?= dgettext('mihomo', 'Secret') ?></label>
<div class="input-group">
    <input type="text" name="secret" class="form-control" id="secret-field" value="<?= nestedVal($base, 'secret', ''); ?>">
    <span class="input-group-btn">
        <button type="button" class="btn btn-default" id="gen-secret"><i class="fa fa-random"></i> <?= dgettext('mihomo', 'Generate') ?></button>
    </span>
</div>
</div></div>
</div>
<div class="form-group">
<label><?= dgettext('mihomo', 'External UI Path') ?> (<?= dgettext('mihomo', 'readonly') ?>)</label>
<input type="text" class="form-control" value="/usr/local/etc/mihomo/ui" readonly>
</div>
</fieldset>

<!-- Group C: TUN -->
<fieldset class="mihomo-field-group">
<legend><i class="fa fa-exchange"></i> <?= dgettext('mihomo', 'C: TUN') ?></legend>
<div class="row">
<div class="col-sm-3"><div class="checkbox"><label>
    <input type="checkbox" name="tun-enable" <?= boolCheck($base['tun'] ?? [], 'enable', true); ?>> <?= dgettext('mihomo', 'Enable TUN') ?>
</label></div></div>
<div class="col-sm-3"><div class="form-group">
<label><?= dgettext('mihomo', 'Stack') ?></label>
<select name="tun-stack" class="form-control">
    <?= selectOptions(['gvisor', 'system', 'mixed'], $base['tun']['stack'] ?? 'gvisor'); ?>
</select>
</div></div>
<div class="col-sm-3"><div class="form-group">
<label><?= dgettext('mihomo', 'Device') ?></label>
<input type="text" name="tun-device" class="form-control" value="<?= nestedVal($base, 'tun.device', 'tun_3000'); ?>">
</div></div>
<div class="col-sm-3"><div class="form-group">
<label><?= dgettext('mihomo', 'MTU') ?></label>
<input type="number" name="tun-mtu" class="form-control" value="<?= nestedVal($base, 'tun.mtu', '9000'); ?>" min="1280" max="65535">
</div></div>
</div>
<div class="row">
<div class="col-sm-4"><div class="checkbox"><label>
    <input type="checkbox" name="tun-auto-route" <?= boolCheck($base['tun'] ?? [], 'auto-route', true); ?>> <?= dgettext('mihomo', 'Auto Route') ?>
</label></div></div>
<div class="col-sm-4"><div class="checkbox"><label>
    <input type="checkbox" name="tun-strict-route" <?= boolCheck($base['tun'] ?? [], 'strict-route', true); ?>> <?= dgettext('mihomo', 'Strict Route') ?>
</label></div></div>
<div class="col-sm-4"><div class="checkbox"><label>
    <input type="checkbox" name="tun-auto-detect-interface" <?= boolCheck($base['tun'] ?? [], 'auto-detect-interface', true); ?>> <?= dgettext('mihomo', 'Auto Detect Interface') ?>
</label></div></div>
</div>
<div class="form-group">
<label><?= dgettext('mihomo', 'DNS Hijack') ?></label>
<textarea name="tun-dns-hijack" class="form-control" rows="2"><?= nestedVal($base, 'tun.dns-hijack', "any:53\ntcp://any:53"); ?></textarea>
</div>
</fieldset>

<!-- Group D: DNS -->
<fieldset class="mihomo-field-group">
<legend><i class="fa fa-globe"></i> <?= dgettext('mihomo', 'D: DNS') ?></legend>
<div class="row">
<div class="col-sm-3"><div class="checkbox"><label>
    <input type="checkbox" name="dns-enable" <?= boolCheck($base['dns'] ?? [], 'enable', true); ?>> <?= dgettext('mihomo', 'Enable DNS') ?>
</label></div></div>
<div class="col-sm-3"><div class="checkbox"><label>
    <input type="checkbox" name="dns-ipv6" <?= boolCheck($base['dns'] ?? [], 'ipv6', true); ?>> <?= dgettext('mihomo', 'IPv6') ?>
</label></div></div>
<div class="col-sm-3"><div class="checkbox"><label>
    <input type="checkbox" name="dns-use-hosts" <?= boolCheck($base['dns'] ?? [], 'use-hosts', true); ?>> <?= dgettext('mihomo', 'Use Hosts') ?>
</label></div></div>
<div class="col-sm-3"><div class="form-group">
<label><?= dgettext('mihomo', 'Enhanced Mode') ?></label>
<select name="dns-enhanced-mode" class="form-control">
    <?= selectOptions(['fake-ip', 'redir-host', 'normal'], $base['dns']['enhanced-mode'] ?? 'fake-ip'); ?>
</select>
</div></div>
</div>
<div class="row">
<div class="col-sm-6"><div class="form-group">
<label><?= dgettext('mihomo', 'Listen') ?></label>
<input type="text" name="dns-listen" class="form-control" value="<?= nestedVal($base, 'dns.listen', '0.0.0.0:53'); ?>">
</div></div>
<div class="col-sm-6"><div class="form-group">
<label><?= dgettext('mihomo', 'Fake-IP Range') ?></label>
<input type="text" name="dns-fake-ip-range" class="form-control" value="<?= nestedVal($base, 'dns.fake-ip-range', '198.18.0.1/16'); ?>">
</div></div>
</div>
<div class="row">
<div class="col-sm-6"><div class="form-group">
<label><?= dgettext('mihomo', 'Default Nameserver') ?></label>
<textarea name="dns-default-nameserver" class="form-control" rows="2"><?= nestedVal($base, 'dns.default-nameserver', '127.0.0.1:5355'); ?></textarea>
</div></div>
<div class="col-sm-6"><div class="form-group">
<label><?= dgettext('mihomo', 'Nameserver') ?></label>
<textarea name="dns-nameserver" class="form-control" rows="2"><?= nestedVal($base, 'dns.nameserver', ''); ?></textarea>
</div></div>
</div>
<div class="row">
<div class="col-sm-6"><div class="form-group">
<label><?= dgettext('mihomo', 'Fallback') ?></label>
<textarea name="dns-fallback" class="form-control" rows="2"><?= nestedVal($base, 'dns.fallback', ''); ?></textarea>
</div></div>
<div class="col-sm-6"><div class="form-group">
<label><?= dgettext('mihomo', 'Fake-IP Filter') ?></label>
<textarea name="dns-fake-ip-filter" class="form-control" rows="2"><?= nestedVal($base, 'dns.fake-ip-filter', ''); ?></textarea>
</div></div>
</div>
</fieldset>

<!-- Group E: Sniffer -->
<fieldset class="mihomo-field-group">
<legend><i class="fa fa-search"></i> <?= dgettext('mihomo', 'E: Sniffer') ?></legend>
<div class="row">
<div class="col-sm-3"><div class="checkbox"><label>
    <input type="checkbox" name="sniffer-enable" <?= boolCheck($base['sniffer'] ?? [], 'enable', true); ?>> <?= dgettext('mihomo', 'Enable Sniffer') ?>
</label></div></div>
<div class="col-sm-3"><div class="checkbox"><label>
    <input type="checkbox" name="sniffer-force-dns-mapping" <?= boolCheck($base['sniffer'] ?? [], 'force-dns-mapping', true); ?>> <?= dgettext('mihomo', 'Force DNS Mapping') ?>
</label></div></div>
<div class="col-sm-3"><div class="checkbox"><label>
    <input type="checkbox" name="sniffer-parse-pure-ip" <?= boolCheck($base['sniffer'] ?? [], 'parse-pure-ip', true); ?>> <?= dgettext('mihomo', 'Parse Pure IP') ?>
</label></div></div>
<div class="col-sm-3"><div class="checkbox"><label>
    <input type="checkbox" name="sniffer-override-destination" <?= boolCheck($base['sniffer'] ?? [], 'override-destination', true); ?>> <?= dgettext('mihomo', 'Override Destination') ?>
</label></div></div>
</div>
<div class="row">
<div class="col-sm-4"><div class="form-group">
<label><?= dgettext('mihomo', 'HTTP Ports') ?></label>
<input type="text" name="sniffer-http-ports" class="form-control" value="80, 8080-8880">
</div></div>
<div class="col-sm-4"><div class="form-group">
<label><?= dgettext('mihomo', 'TLS Ports') ?></label>
<input type="text" name="sniffer-tls-ports" class="form-control" value="443, 8443">
</div></div>
<div class="col-sm-4"><div class="form-group">
<label><?= dgettext('mihomo', 'QUIC Ports') ?></label>
<input type="text" name="sniffer-quic-ports" class="form-control" value="443, 8443">
</div></div>
</div>
<div class="form-group">
<label><?= dgettext('mihomo', 'Skip Domains') ?></label>
<textarea name="sniffer-skip-domain" class="form-control" rows="2"><?= nestedVal($base, 'sniffer.skip-domain', '+.push.apple.com'); ?></textarea>
</div>
</fieldset>

<!-- Group F: Auto Update -->
<fieldset class="mihomo-field-group">
<legend><i class="fa fa-cloud-download"></i> <?= dgettext('mihomo', 'F: Auto Update') ?></legend>
<div class="row">
<div class="col-sm-6"><div class="form-group">
<label><?= dgettext('mihomo', 'GitHub Mirror') ?></label>
<input type="text" name="gh-mirror" class="form-control" placeholder="https://ghproxy.com/">
</div></div>
<div class="col-sm-6"><div class="form-group">
<label><?= dgettext('mihomo', 'GitHub Token') ?> (<?= dgettext('mihomo', 'optional') ?>)</label>
<input type="password" name="gh-token" class="form-control" placeholder="ghp_...">
</div></div>
</div>
<div class="row">
<div class="col-sm-4"><div class="checkbox"><label>
    <input type="checkbox" name="auto-update-geoip"> <?= dgettext('mihomo', 'Auto Update GeoIP (weekly)') ?>
</label></div></div>
<div class="col-sm-4"><div class="checkbox"><label>
    <input type="checkbox" name="auto-update-ui"> <?= dgettext('mihomo', 'Auto Update Dashboard UI (monthly)') ?>
</label></div></div>
<div class="col-sm-4"><div class="checkbox"><label>
    <input type="checkbox" name="auto-update-core"> <?= dgettext('mihomo', 'Auto Update Core') ?>
    <small class="text-danger">(<?= dgettext('mihomo', 'not recommended') ?>)</small>
</label></div></div>
</div>
</fieldset>

<div class="mihomo-actions">
    <button type="submit" class="btn btn-danger"><i class="fa fa-save"></i> <?= dgettext('mihomo', 'Save Settings') ?></button>
    <small class="text-muted"><?= dgettext('mihomo', 'Saving will validate and reload mihomo.') ?></small>
</div>
</form>
</div>

<!-- ====== Tab: Override ====== -->
<div id="tab-override" class="mihomo-tab-panel">
<div class="alert alert-info">
    <?= dgettext('mihomo', 'Override fragment — subscription refresh will NOT overwrite this content. Use positional keys to insert rules/proxies/proxy-groups before or after subscription content.') ?>
    <br><a href="#" id="toggle-override-example"><?= dgettext('mihomo', 'Show example') ?></a>
    <pre id="override-example" style="display:none;margin-top:8px;"># 插入到 rules 列表最前面（最高优先级）
prepend-rules:
  - DOMAIN-SUFFIX,my-internal.lan,DIRECT

# 追加到 rules 列表末尾
append-rules:
  - MATCH,Proxy

# 追加私有节点
append-proxies:
  - name: my-private-vpn
    type: ss
    server: 1.2.3.4
    port: 8388
    ...

# 插入 proxy-groups 头部
prepend-proxy-groups:
  - name: Select Proxy
    type: select
    proxies: [my-private-vpn]

# 追加 proxy-groups 尾部
append-proxy-groups:
  - name: Fallback Group
    type: fallback
    ...

# 其他顶层 key 将深度合并覆盖 base.yaml
dns:
  nameserver-policy:
    '+.internal.local': 192.168.1.1</pre>
</div>

<form method="post">
<input type="hidden" name="_tab" value="override">
<input type="hidden" name="action" value="save_override">
<textarea name="override_content" class="form-control mihomo-yaml-area" rows="18" style="max-width:none;"><?= htmlspecialchars($overrideContent, ENT_QUOTES); ?></textarea>
<div class="mihomo-actions">
    <button type="submit" class="btn btn-danger"><i class="fa fa-save"></i> <?= dgettext('mihomo', 'Save Override') ?></button>
    <button type="submit" class="btn btn-default" formaction="?tab=override" onclick="this.form.action.value='validate_override'; return true;">
        <i class="fa fa-check-circle"></i> <?= dgettext('mihomo', 'Validate Only') ?>
    </button>
    <button type="submit" class="btn btn-default" onclick="this.form.action.value='reset_override'; return true;">
        <i class="fa fa-undo"></i> <?= dgettext('mihomo', 'Reset') ?>
    </button>
</div>
</form>
</div>

<!-- ====== Tab: Profiles ====== -->
<div id="tab-profiles" class="mihomo-tab-panel">
<table class="table table-striped">
<thead>
    <tr>
        <th><?= dgettext('mihomo', 'Name') ?></th>
        <th><?= dgettext('mihomo', 'Source') ?></th>
        <th><?= dgettext('mihomo', 'Nodes') ?></th>
        <th><?= dgettext('mihomo', 'Last Updated') ?></th>
        <th><?= dgettext('mihomo', 'Status') ?></th>
        <th><?= dgettext('mihomo', 'Actions') ?></th>
    </tr>
</thead>
<tbody>
<?php foreach ($profiles as $p): ?>
<tr>
    <td>
        <strong><?= htmlspecialchars($p['name'], ENT_QUOTES); ?></strong>
        <?php if ($p['name'] === $activeProfile): ?>
        <span class="label label-success"><?= dgettext('mihomo', 'active') ?></span>
        <?php endif; ?>
    </td>
    <td>
        <?= $p['source_type'] === 'subscription' ? '<span class="label label-info">' . dgettext('mihomo', 'subscription') . '</span>' : '<span class="label label-default">' . dgettext('mihomo', 'manual') . '</span>'; ?>
    </td>
    <td><?= (int)($p['node_count'] ?? 0); ?></td>
    <td><?= htmlspecialchars($p['last_update'] ?? 'N/A', ENT_QUOTES); ?></td>
    <td><?= $p['name'] === $activeProfile ? '<i class="fa fa-check-circle" style="color:#51a351;"></i>' : ''; ?></td>
    <td>
        <div class="mihomo-table-actions">
            <?php if ($p['name'] !== $activeProfile): ?>
            <form method="post" style="display:inline;">
                <input type="hidden" name="_tab" value="profiles">
                <input type="hidden" name="action" value="activate_profile">
                <input type="hidden" name="profile_name" value="<?= htmlspecialchars($p['name'], ENT_QUOTES); ?>">
                <button type="submit" class="btn btn-xs btn-primary"><?= dgettext('mihomo', 'Activate') ?></button>
            </form>
            <?php endif; ?>
            <button type="button" class="btn btn-xs btn-default" onclick="viewProfileYaml('<?= htmlspecialchars($p['name'], ENT_QUOTES); ?>');"><?= dgettext('mihomo', 'View') ?></button>
            <form method="post" style="display:inline;" onsubmit="return confirm('<?= dgettext('mihomo', 'Delete this profile?') ?>');">
                <input type="hidden" name="_tab" value="profiles">
                <input type="hidden" name="action" value="delete_profile">
                <input type="hidden" name="profile_name" value="<?= htmlspecialchars($p['name'], ENT_QUOTES); ?>">
                <button type="submit" class="btn btn-xs btn-danger" <?= $p['name'] === $activeProfile ? 'disabled' : ''; ?>><?= dgettext('mihomo', 'Delete') ?></button>
            </form>
        </div>
    </td>
</tr>
<?php endforeach; ?>
</tbody>
</table>

<form method="post" class="form-inline" style="margin-top:12px;">
<input type="hidden" name="_tab" value="profiles">
<input type="hidden" name="action" value="create_profile">
<div class="input-group">
    <input type="text" name="new_profile_name" class="form-control" placeholder="<?= dgettext('mihomo', 'New profile name'); ?>" pattern="[a-zA-Z0-9_-]+">
    <span class="input-group-btn">
        <button type="submit" class="btn btn-success"><i class="fa fa-plus"></i> <?= dgettext('mihomo', 'Create Empty Profile') ?></button>
    </span>
</div>
</form>

<!-- View YAML Modal -->
<div id="profile-yaml-modal" style="display:none;position:fixed;top:10%;left:10%;width:80%;z-index:9999;background:#fff;border:2px solid #ccc;padding:16px;box-shadow:0 4px 12px rgba(0,0,0,0.3);">
    <h4 id="profile-yaml-title"></h4>
    <textarea id="profile-yaml-content" class="form-control mihomo-yaml-area" rows="20" readonly style="max-width:none;"></textarea>
    <button type="button" class="btn btn-default" onclick="document.getElementById('profile-yaml-modal').style.display='none';" style="margin-top:8px;"><?= dgettext('mihomo', 'Close') ?></button>
</div>
</div>

<!-- ====== Tab: YAML ====== -->
<div id="tab-yaml" class="mihomo-tab-panel">
<div class="alert alert-info">
    <?= dgettext('mihomo', 'This is the currently active merged config.yaml (read-only). To modify, use the Settings, Override, or Profiles tabs.') ?>
</div>
<textarea class="form-control mihomo-yaml-area" rows="24" readonly style="max-width:none;" id="yaml-viewer"><?= htmlspecialchars($configContent, ENT_QUOTES); ?></textarea>
<div class="mihomo-actions">
    <button type="button" class="btn btn-default" id="btn-copy-yaml"><i class="fa fa-clipboard"></i> <?= dgettext('mihomo', 'Copy to Clipboard') ?></button>
    <a href="data:text/yaml;charset=utf-8,<?= urlencode($configContent); ?>" download="config.yaml" class="btn btn-default"><i class="fa fa-download"></i> <?= dgettext('mihomo', 'Download') ?></a>
</div>
</div>

<!-- ====== Tab: Log ====== -->
<div id="tab-log" class="mihomo-tab-panel">
<div class="mihomo-actions" style="margin-bottom:10px;">
    <button type="button" class="btn btn-default" id="btn-pause-log"><i class="fa fa-pause"></i> <?= dgettext('mihomo', 'Pause Auto-refresh') ?></button>
    <button type="button" class="btn btn-default" id="btn-clear-log"><i class="fa fa-trash"></i> <?= dgettext('mihomo', 'Clear Log') ?></button>
    <select id="log-lines" class="form-control" style="width:auto;">
        <option value="100">100 <?= dgettext('mihomo', 'lines') ?></option>
        <option value="200" selected>200 <?= dgettext('mihomo', 'lines') ?></option>
        <option value="500">500 <?= dgettext('mihomo', 'lines') ?></option>
        <option value="1000">1000 <?= dgettext('mihomo', 'lines') ?></option>
    </select>
    <select id="log-level" class="form-control" style="width:auto;">
        <option value=""><?= dgettext('mihomo', 'All levels') ?></option>
        <option value="error">error</option>
        <option value="warning">warning</option>
        <option value="info">info</option>
        <option value="debug">debug</option>
    </select>
</div>
<textarea id="log-viewer" class="form-control mihomo-yaml-area" rows="24" readonly style="max-width:none;"></textarea>
</div>

<!-- ====== Tab: Updates ====== -->
<div id="tab-updates" class="mihomo-tab-panel">
<!-- Core -->
<div class="mihomo-update-card">
<h4><i class="fa fa-cube"></i> <?= dgettext('mihomo', 'Mihomo Core') ?></h4>
<p>
    <span id="core-current"><?= dgettext('mihomo', 'Current') ?>: <?= htmlspecialchars(trim(shell_exec('/usr/local/bin/mihomo -v 2>/dev/null') ?: 'N/A'), ENT_QUOTES); ?></span>
    &nbsp;|&nbsp;
    <span id="core-latest"><?= dgettext('mihomo', 'Latest') ?>: --</span>
</p>
<div class="mihomo-actions">
    <form method="post" style="display:inline;">
        <input type="hidden" name="_tab" value="updates">
        <button type="submit" name="action" value="check_core" class="btn btn-default"><i class="fa fa-refresh"></i> <?= dgettext('mihomo', 'Check') ?></button>
        <button type="submit" name="action" value="update_core" class="btn btn-warning" id="btn-update-core"><i class="fa fa-download"></i> <?= dgettext('mihomo', 'Update') ?></button>
    </form>
</div>
<div id="core-update-progress" style="margin-top:8px;"></div>
</div>

<!-- GeoIP -->
<div class="mihomo-update-card">
<h4><i class="fa fa-map-marker"></i> <?= dgettext('mihomo', 'GeoIP Database') ?></h4>
<p>
    <span id="geoip-current"><?= dgettext('mihomo', 'Current') ?>: <?= htmlspecialchars(date('Y-m-d', filemtime(MIHOMO_DIR . '/Country.mmdb') ?: time()), ENT_QUOTES); ?></span>
    &nbsp;|&nbsp;
    <span id="geoip-latest"><?= dgettext('mihomo', 'Latest') ?>: --</span>
</p>
<div class="mihomo-actions">
    <form method="post" style="display:inline;">
        <input type="hidden" name="_tab" value="updates">
        <button type="submit" name="action" value="check_geoip" class="btn btn-default"><i class="fa fa-refresh"></i> <?= dgettext('mihomo', 'Check') ?></button>
        <button type="submit" name="action" value="update_geoip" class="btn btn-warning" id="btn-update-geoip"><i class="fa fa-download"></i> <?= dgettext('mihomo', 'Update') ?></button>
    </form>
</div>
<div id="geoip-update-progress" style="margin-top:8px;"></div>
</div>

<!-- Dashboard UI -->
<div class="mihomo-update-card">
<h4><i class="fa fa-desktop"></i> <?= dgettext('mihomo', 'Dashboard UI') ?></h4>
<form method="post" style="display:inline;">
    <input type="hidden" name="_tab" value="updates">
    <p>
        <span><?= dgettext('mihomo', 'UI Variant') ?>:</span>
        <select name="ui_variant" id="ui-variant" class="form-control" style="width:auto;display:inline;">
            <option value="metacubexd">metacubexd</option>
            <option value="zashboard">zashboard</option>
            <option value="yacd">yacd</option>
        </select>
    </p>
    <div class="mihomo-actions">
        <button type="submit" name="action" value="check_ui" class="btn btn-default"><i class="fa fa-refresh"></i> <?= dgettext('mihomo', 'Check') ?></button>
        <button type="submit" name="action" value="update_ui" class="btn btn-warning" id="btn-update-ui"><i class="fa fa-download"></i> <?= dgettext('mihomo', 'Update') ?></button>
    </div>
</form>
<div id="ui-update-progress" style="margin-top:8px;"></div>
</div>
</div>

</div><!-- end tab content -->
</div>
</section>
</div>
</div>
</section>

<div id="yaml-backdrop" style="display:none;position:fixed;top:0;left:0;width:100%;height:100%;background:rgba(0,0,0,0.3);z-index:9998;" onclick="document.getElementById('profile-yaml-modal').style.display='none';this.style.display='none';"></div>

<script>
(function() {
    // ── Tab routing ──
    function switchTab(name) {
        document.querySelectorAll('.mihomo-tab-panel').forEach(function(el) { el.classList.remove('active'); });
        document.querySelectorAll('.mihomo-tab-btn').forEach(function(el) { el.classList.remove('active'); });
        var panel = document.getElementById('tab-' + name);
        if (panel) panel.classList.add('active');
        var btn = document.querySelector('[data-tab="' + name + '"]');
        if (btn) btn.classList.add('active');
        if (window.history) {
            window.history.replaceState(null, '', '#' + name);
        }
    }

    document.querySelectorAll('.mihomo-tab-btn').forEach(function(btn) {
        btn.addEventListener('click', function(e) {
            e.preventDefault();
            switchTab(this.dataset.tab);
        });
    });

    // Restore tab from hash
    var hash = window.location.hash.replace('#', '');
    if (hash) {
        var validTabs = ['settings', 'override', 'profiles', 'yaml', 'log', 'updates'];
        if (validTabs.indexOf(hash) >= 0) switchTab(hash);
    }

    // ── Generate Secret ──
    var genBtn = document.getElementById('gen-secret');
    if (genBtn) {
        genBtn.addEventListener('click', function() {
            var chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
            var secret = '';
            for (var i = 0; i < 32; i++) {
                secret += chars.charAt(Math.floor(Math.random() * chars.length));
            }
            document.getElementById('secret-field').value = secret;
        });
    }

    // ── Override example toggle ──
    var toggleLink = document.getElementById('toggle-override-example');
    if (toggleLink) {
        toggleLink.addEventListener('click', function(e) {
            e.preventDefault();
            var el = document.getElementById('override-example');
            el.style.display = el.style.display === 'none' ? 'block' : 'none';
        });
    }

    // ── Copy YAML ──
    var copyBtn = document.getElementById('btn-copy-yaml');
    if (copyBtn) {
        copyBtn.addEventListener('click', function() {
            var ta = document.getElementById('yaml-viewer');
            ta.select();
            document.execCommand('copy');
        });
    }

    // ── Log viewer ──
    var logPaused = false;
    var logTimer = null;

    function refreshLog() {
        if (logPaused) return;
        var lines = document.getElementById('log-lines').value || '200';
        var level = document.getElementById('log-level').value || '';
        var url = '/status_mihomo_logs.php?lines=' + lines;
        if (level) url += '&level=' + level;
        fetch(url, { cache: 'no-store' })
            .then(function(r) { if (!r.ok) throw new Error(); return r.text(); })
            .then(function(t) {
                var ta = document.getElementById('log-viewer');
                ta.value = t;
                ta.scrollTop = ta.scrollHeight;
            })
            .catch(function() {});
    }

    var pauseBtn = document.getElementById('btn-pause-log');
    if (pauseBtn) {
        pauseBtn.addEventListener('click', function() {
            logPaused = !logPaused;
            this.innerHTML = logPaused
                ? '<i class="fa fa-play"></i> <?= dgettext('mihomo', 'Resume Auto-refresh') ?>'
                : '<i class="fa fa-pause"></i> <?= dgettext('mihomo', 'Pause Auto-refresh') ?>';
            if (!logPaused) refreshLog();
        });
    }

    var clearBtn = document.getElementById('btn-clear-log');
    if (clearBtn) {
        clearBtn.addEventListener('click', function() {
            if (!confirm('<?= dgettext('mihomo', 'Clear the log file?') ?>')) return;
            fetch('/status_mihomo_logs.php?action=clear', { method: 'POST', cache: 'no-store' })
                .then(function() { refreshLog(); })
                .catch(function() {});
        });
    }

    // Start log polling when log tab is active
    var logObserver = new MutationObserver(function() {
        var logTab = document.getElementById('tab-log');
        if (logTab && logTab.classList.contains('active')) {
            if (!logTimer) {
                refreshLog();
                logTimer = setInterval(refreshLog, 3000);
            }
        } else {
            if (logTimer) { clearInterval(logTimer); logTimer = null; }
        }
    });

    document.querySelectorAll('.mihomo-tab-panel').forEach(function(p) {
        logObserver.observe(p, { attributes: true, attributeFilter: ['class'] });
    });

    // Initial log load
    refreshLog();
    logTimer = setInterval(refreshLog, 3000);

    // ── Update progress polling ──
    var updateTimers = {};

    function pollUpdate(resource) {
        fetch('/status_mihomo_update.php?resource=' + resource, { cache: 'no-store' })
            .then(function(r) { return r.json(); })
            .then(function(d) {
                var el = document.getElementById(resource + '-update-progress');
                if (!el) return;
                if (d.state === 'idle') {
                    el.innerHTML = '';
                    clearInterval(updateTimers[resource]);
                } else if (d.state === 'running' || d.state === 'downloading' || d.state === 'verifying' || d.state === 'installing') {
                    el.innerHTML = '<div class="progress"><div class="progress-bar progress-bar-striped active" style="width:' + (d.progress || 0) + '%">' + (d.message || '') + '</div></div>';
                    // Lock buttons
                    var btn = document.getElementById('btn-update-' + resource);
                    if (btn) btn.disabled = true;
                } else if (d.state === 'done') {
                    el.innerHTML = '<div class="alert alert-success">' + (d.message || '<?= dgettext('mihomo', 'Update complete') ?>') + '</div>';
                    clearInterval(updateTimers[resource]);
                    var btn = document.getElementById('btn-update-' + resource);
                    if (btn) btn.disabled = false;
                } else if (d.state === 'failed') {
                    el.innerHTML = '<div class="alert alert-danger">' + (d.message || '<?= dgettext('mihomo', 'Update failed') ?>') + '</div>';
                    clearInterval(updateTimers[resource]);
                    var btn = document.getElementById('btn-update-' + resource);
                    if (btn) btn.disabled = false;
                }
            });
    }

    // Start update polling for any active updates
    ['core', 'geoip', 'ui'].forEach(function(r) {
        updateTimers[r] = setInterval(function() { pollUpdate(r); }, 2000);
    });

    // ── CustomEvent for cross-tab refresh ──
    window.addEventListener('mihomo:configChanged', function() {
        // Refresh YAML tab content on next view
        fetch('/status_mihomo.php', { cache: 'no-store' });
    });

    // ── Profile YAML view (simplified: reloads page with modal) ──
    window.viewProfileYaml = function(name) {
        // Fetch profile content via a simple endpoint or embed
        // For now, show modal placeholder
        document.getElementById('profile-yaml-title').textContent = 'Profile: ' + name;
        document.getElementById('profile-yaml-content').value = '<?= dgettext('mihomo', 'Loading...') ?>';
        document.getElementById('profile-yaml-modal').style.display = 'block';
        document.getElementById('yaml-backdrop').style.display = 'block';
    };
})();
</script>

<?php include 'foot.inc'; ?>
