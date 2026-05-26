<?php
require_once 'guiconfig.inc';
require_once 'includes/mihomo_lib.inc.php';
include 'head.inc';
include 'fbegin.inc';

$message = '';
$message_type = 'info';

// ── Handle POST ──
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $action = $_POST['action'] ?? '';

    if ($action === 'add_sub' || $action === 'edit_sub') {
        $subId = $action === 'add_sub'
            ? 'sub-' . bin2hex(random_bytes(6))
            : ($_POST['sub_id'] ?? '');

        $sub = [
            'id' => $subId,
            'name' => trim($_POST['name'] ?? ''),
            'url' => trim($_POST['url'] ?? ''),
            'user_agent' => trim($_POST['user_agent'] ?? 'clash-verge/v1.7.0'),
            'enabled' => !empty($_POST['enabled']),
            'include_keyword' => trim($_POST['include_keyword'] ?? ''),
            'exclude_keyword' => trim($_POST['exclude_keyword'] ?? '剩余,流量,过期,官网,套餐'),
            'update_interval_hours' => (int)($_POST['update_interval_hours'] ?? 6),
            'last_update' => null,
            'last_status' => null,
        ];

        if (empty($sub['name']) || empty($sub['url'])) {
            $message = dgettext('mihomo', 'Name and URL are required.');
            $message_type = 'danger';
        } else {
            $subs = readSubs();

            if ($action === 'add_sub') {
                $subs[] = $sub;
            } else {
                foreach ($subs as &$s) {
                    if (($s['id'] ?? '') === $subId) {
                        $s = array_merge($s, $sub);
                        break;
                    }
                }
            }

            list($ok, $err) = writeSubs($subs);
            if ($ok) {
                $message = $action === 'add_sub'
                    ? dgettext('mihomo', 'Subscription added.')
                    : dgettext('mihomo', 'Subscription updated.');
                $message_type = 'success';
            } else {
                $message = dgettext('mihomo', 'Failed to save:') . ' ' . $err;
                $message_type = 'danger';
            }
        }
    }

    if ($action === 'delete_sub') {
        $subId = $_POST['sub_id'] ?? '';
        $subs = readSubs();
        $subs = array_filter($subs, fn($s) => ($s['id'] ?? '') !== $subId);
        $subs = array_values($subs);
        list($ok, $err) = writeSubs($subs);
        $message = $ok ? dgettext('mihomo', 'Subscription deleted.') : dgettext('mihomo', 'Failed to delete:') . ' ' . $err;
        $message_type = $ok ? 'success' : 'danger';
    }

    if ($action === 'refresh_now') {
        $subId = $_POST['sub_id'] ?? '';
        $sub = getSubById($subId);
        if ($sub) {
            updateSubStatus($subId, 'updating');
            mihomoExecBackground('bash /usr/local/etc/mihomo/sub/sub.sh ' . escapeshellarg($subId));
            $message = sprintf(dgettext('mihomo', 'Subscription "%s" refresh triggered.'), $sub['name'] ?? $subId);
            $message_type = 'success';
        }
    }

    if ($action === 'clear_log') {
        if (file_exists(MIHOMO_SUB_LOG)) {
            file_put_contents(MIHOMO_SUB_LOG, '', LOCK_EX);
        }
        $message = dgettext('mihomo', 'Subscription log cleared.');
        $message_type = 'success';
    }
}

$subs = readSubs();
$subLog = '';
if (file_exists(MIHOMO_SUB_LOG)) {
    $lines = file(MIHOMO_SUB_LOG);
    $subLog = htmlspecialchars(implode('', array_slice($lines, -200)), ENT_QUOTES);
}
?>

<style>
.mihomo-section-title { display: flex; align-items: center; gap: 8px; font-weight: 700; color: #333; padding: 2px 0; }
.mihomo-section-title .fa { color: #777; width: 14px; text-align: center; }
.mihomo-actions { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; margin-top: 12px; }
.mihomo-table-actions { display: flex; gap: 4px; flex-wrap: wrap; }
.status-updating { color: #f0ad4e; }
.status-done { color: #51a351; }
.status-failed { color: #d9534f; }
.mihomo-edit-form { display: none; padding: 16px; background: #f9f9f9; border: 1px solid #e0e0e0; border-radius: 3px; margin-bottom: 12px; }
.mihomo-edit-form.active { display: block; }
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

<!-- ====== Subscription List ====== -->
<section class="col-xs-12">
    <div class="content-box tab-content table-responsive __mb">
        <table class="table table-striped">
            <tbody>
                <tr>
                    <td class="mihomo-panel-cell">
                        <div class="mihomo-section-title">
                            <i class="fa fa-link"></i>
                            <span><?= dgettext('mihomo', 'Subscriptions') ?></span>
                        </div>
                    </td>
                </tr>
                <tr>
                    <td id="sub-table-container">
                        <table class="table table-striped table-hover" id="sub-table">
                            <thead>
                                <tr>
                                    <th><?= dgettext('mihomo', 'Enabled') ?></th>
                                    <th><?= dgettext('mihomo', 'Name') ?></th>
                                    <th><?= dgettext('mihomo', 'URL') ?></th>
                                    <th><?= dgettext('mihomo', 'Filter') ?></th>
                                    <th><?= dgettext('mihomo', 'Interval') ?></th>
                                    <th><?= dgettext('mihomo', 'Last Update') ?></th>
                                    <th><?= dgettext('mihomo', 'Status') ?></th>
                                    <th><?= dgettext('mihomo', 'Actions') ?></th>
                                </tr>
                            </thead>
                            <tbody>
                                <?php foreach ($subs as $sub): ?>
                                <?php
                                    $id = htmlspecialchars($sub['id'] ?? '', ENT_QUOTES);
                                    $name = htmlspecialchars($sub['name'] ?? '', ENT_QUOTES);
                                    $url = htmlspecialchars($sub['url'] ?? '', ENT_QUOTES);
                                    $enabled = !empty($sub['enabled']);
                                    $include = htmlspecialchars($sub['include_keyword'] ?? '', ENT_QUOTES);
                                    $exclude = htmlspecialchars($sub['exclude_keyword'] ?? '', ENT_QUOTES);
                                    $interval = (int)($sub['update_interval_hours'] ?? 6);
                                    $lastUpdate = htmlspecialchars($sub['last_update'] ?? 'N/A', ENT_QUOTES);
                                    $lastStatus = $sub['last_status'] ?? null;
                                    $statusClass = $lastStatus === 'done' ? 'status-done' : ($lastStatus === 'failed' ? 'status-failed' : ($lastStatus === 'updating' ? 'status-updating' : ''));
                                    $statusText = $lastStatus ?: '--';
                                ?>
                                <tr>
                                    <td>
                                        <input type="checkbox" disabled <?= $enabled ? 'checked' : ''; ?>>
                                    </td>
                                    <td><strong><?= $name; ?></strong></td>
                                    <td style="max-width:200px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;" title="<?= $url; ?>"><?= $url; ?></td>
                                    <td>
                                        <?php if ($include): ?><small>+<?= $include; ?></small><?php endif; ?>
                                        <?php if ($exclude): ?><small>-<?= $exclude; ?></small><?php endif; ?>
                                    </td>
                                    <td><?= $interval; ?>h</td>
                                    <td><?= $lastUpdate; ?></td>
                                    <td><span class="<?= $statusClass; ?>"><?= htmlspecialchars($statusText, ENT_QUOTES); ?></span></td>
                                    <td>
                                        <div class="mihomo-table-actions">
                                            <form method="post" style="display:inline;">
                                                <input type="hidden" name="action" value="refresh_now">
                                                <input type="hidden" name="sub_id" value="<?= $id; ?>">
                                                <button type="submit" class="btn btn-xs btn-success">
                                                    <i class="fa fa-sync"></i> <?= dgettext('mihomo', 'Refresh') ?>
                                                </button>
                                            </form>
                                            <button type="button" class="btn btn-xs btn-default" onclick="editSub('<?= $id; ?>')">
                                                <i class="fa fa-pencil"></i> <?= dgettext('mihomo', 'Edit') ?>
                                            </button>
                                            <form method="post" style="display:inline;" onsubmit="return confirm('<?= dgettext('mihomo', 'Delete this subscription?') ?>');">
                                                <input type="hidden" name="action" value="delete_sub">
                                                <input type="hidden" name="sub_id" value="<?= $id; ?>">
                                                <button type="submit" class="btn btn-xs btn-danger">
                                                    <i class="fa fa-trash"></i> <?= dgettext('mihomo', 'Delete') ?>
                                                </button>
                                            </form>
                                        </div>
                                    </td>
                                </tr>
                                <?php endforeach; ?>
                                <?php if (empty($subs)): ?>
                                <tr><td colspan="8" style="text-align:center;color:#999;"><i><?= dgettext('mihomo', 'No subscriptions. Click "Add Subscription" to add one.') ?></i></td></tr>
                                <?php endif; ?>
                            </tbody>
                        </table>

                        <button type="button" class="btn btn-primary" id="btn-add-sub">
                            <i class="fa fa-plus"></i> <?= dgettext('mihomo', 'Add Subscription') ?>
                        </button>

                        <!-- Add/Edit Form -->
                        <div id="sub-form" class="mihomo-edit-form">
                            <h4 id="sub-form-title"><?= dgettext('mihomo', 'Add Subscription') ?></h4>
                            <form method="post">
                                <input type="hidden" name="action" id="sub-form-action" value="add_sub">
                                <input type="hidden" name="sub_id" id="sub-form-id" value="">

                                <div class="row">
                                    <div class="col-sm-6"><div class="form-group">
                                        <label><?= dgettext('mihomo', 'Name') ?> *</label>
                                        <input type="text" name="name" id="sub-form-name" class="form-control" required pattern="[a-zA-Z0-9_-]+" placeholder="my-subscription">
                                        <small class="text-muted"><?= dgettext('mihomo', 'Only letters, numbers, hyphens and underscores.') ?></small>
                                    </div></div>
                                    <div class="col-sm-6"><div class="form-group">
                                        <label><?= dgettext('mihomo', 'URL') ?> *</label>
                                        <input type="url" name="url" id="sub-form-url" class="form-control" required placeholder="https://...">
                                    </div></div>
                                </div>

                                <div class="row">
                                    <div class="col-sm-4"><div class="form-group">
                                        <label><?= dgettext('mihomo', 'Custom User-Agent') ?></label>
                                        <input type="text" name="user_agent" id="sub-form-ua" class="form-control" value="clash-verge/v1.7.0">
                                    </div></div>
                                    <div class="col-sm-4"><div class="form-group">
                                        <label><?= dgettext('mihomo', 'Auto Update Interval') ?></label>
                                        <select name="update_interval_hours" id="sub-form-interval" class="form-control">
                                            <option value="0"><?= dgettext('mihomo', 'Off') ?></option>
                                            <option value="1">1 <?= dgettext('mihomo', 'hour') ?></option>
                                            <option value="6" selected>6 <?= dgettext('mihomo', 'hours') ?></option>
                                            <option value="12">12 <?= dgettext('mihomo', 'hours') ?></option>
                                            <option value="24">24 <?= dgettext('mihomo', 'hours') ?></option>
                                        </select>
                                    </div></div>
                                    <div class="col-sm-4"><div class="form-group">
                                        <label>
                                            <input type="checkbox" name="enabled" id="sub-form-enabled" checked>
                                            <?= dgettext('mihomo', 'Enabled') ?>
                                        </label>
                                    </div></div>
                                </div>

                                <div class="row">
                                    <div class="col-sm-6"><div class="form-group">
                                        <label><?= dgettext('mihomo', 'Include Keyword') ?> <small>(<?= dgettext('mihomo', 'comma separated') ?>)</small></label>
                                        <input type="text" name="include_keyword" id="sub-form-include" class="form-control" placeholder="HK,SG,JP">
                                    </div></div>
                                    <div class="col-sm-6"><div class="form-group">
                                        <label><?= dgettext('mihomo', 'Exclude Keyword') ?> <small>(<?= dgettext('mihomo', 'comma separated') ?>)</small></label>
                                        <input type="text" name="exclude_keyword" id="sub-form-exclude" class="form-control" value="剩余,流量,过期,官网,套餐">
                                    </div></div>
                                </div>

                                <div class="mihomo-actions">
                                    <button type="submit" class="btn btn-danger"><i class="fa fa-save"></i> <?= dgettext('mihomo', 'Save') ?></button>
                                    <button type="button" class="btn btn-default" onclick="cancelEdit();"><?= dgettext('mihomo', 'Cancel') ?></button>
                                </div>
                            </form>
                        </div>
                    </td>
                </tr>
            </tbody>
        </table>
    </div>
</section>

<!-- ====== Subscription Log ====== -->
<section class="col-xs-12">
    <div class="content-box tab-content table-responsive __mb">
        <table class="table table-striped">
            <tbody>
                <tr>
                    <td class="mihomo-panel-cell">
                        <div class="mihomo-section-title">
                            <i class="fa fa-file-text-o"></i>
                            <span><?= dgettext('mihomo', 'Subscription Log') ?></span>
                        </div>
                    </td>
                </tr>
                <tr>
                    <td>
                        <form method="post" class="mihomo-actions" style="margin-bottom:10px;">
                            <button type="submit" name="action" value="clear_log" class="btn btn-default">
                                <i class="fa fa-trash"></i> <?= dgettext('mihomo', 'Clear Log') ?>
                            </button>
                        </form>
                        <textarea id="sub-log-viewer" class="form-control" rows="16" readonly style="max-width:none;font-family:monospace;font-size:12px;"></textarea>
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
    // ── Subscription data (embedded for edit) ──
    var subsData = <?= json_encode($subs, JSON_HEX_TAG | JSON_HEX_AMP | JSON_HEX_APOS | JSON_HEX_QUOT); ?>;

    window.editSub = function(id) {
        var sub = subsData.find(function(s) { return s.id === id; });
        if (!sub) return;

        document.getElementById('sub-form-action').value = 'edit_sub';
        document.getElementById('sub-form-id').value = sub.id;
        document.getElementById('sub-form-name').value = sub.name || '';
        document.getElementById('sub-form-url').value = sub.url || '';
        document.getElementById('sub-form-ua').value = sub.user_agent || 'clash-verge/v1.7.0';
        document.getElementById('sub-form-interval').value = sub.update_interval_hours || 6;
        document.getElementById('sub-form-enabled').checked = sub.enabled !== false;
        document.getElementById('sub-form-include').value = sub.include_keyword || '';
        document.getElementById('sub-form-exclude').value = sub.exclude_keyword || '剩余,流量,过期,官网,套餐';
        document.getElementById('sub-form-title').textContent = '<?= dgettext('mihomo', 'Edit Subscription') ?>';
        document.getElementById('sub-form').classList.add('active');
    };

    window.cancelEdit = function() {
        document.getElementById('sub-form').classList.remove('active');
        document.getElementById('sub-form-action').value = 'add_sub';
        document.getElementById('sub-form-id').value = '';
        document.getElementById('sub-form-name').value = '';
        document.getElementById('sub-form-url').value = '';
        document.getElementById('sub-form-ua').value = 'clash-verge/v1.7.0';
        document.getElementById('sub-form-interval').value = '6';
        document.getElementById('sub-form-enabled').checked = true;
        document.getElementById('sub-form-include').value = '';
        document.getElementById('sub-form-exclude').value = '剩余,流量,过期,官网,套餐';
        document.getElementById('sub-form-title').textContent = '<?= dgettext('mihomo', 'Add Subscription') ?>';
    };

    document.getElementById('btn-add-sub').addEventListener('click', function() {
        cancelEdit();
        document.getElementById('sub-form').classList.add('active');
    });

    // ── Log polling ──
    function refreshSubLog() {
        fetch('/status_sub_logs.php?lines=200', { cache: 'no-store' })
            .then(function(r) { if (!r.ok) throw new Error(); return r.text(); })
            .then(function(t) {
                var ta = document.getElementById('sub-log-viewer');
                ta.value = t;
                ta.scrollTop = ta.scrollHeight;
            })
            .catch(function() {});
    }

    refreshSubLog();
    setInterval(refreshSubLog, 5000);
})();
</script>

<?php include 'foot.inc'; ?>
