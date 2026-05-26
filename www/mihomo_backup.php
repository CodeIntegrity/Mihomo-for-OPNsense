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

    // Export
    if ($action === 'export') {
        $encrypt = !empty($_POST['encrypt']);
        $password = $_POST['export_password'] ?? '';

        $hostname = trim(shell_exec('hostname -s') ?: 'opnsense');
        $ts = date('Ymd_His');
        $tmpTar = "/tmp/mihomo-backup-{$hostname}-{$ts}.tar.gz";
        $tmpOut = $tmpTar;

        // Collect files
        $files = [];
        foreach ([MIHOMO_BASE_YAML, MIHOMO_OVERRIDE_YAML, MIHOMO_SUBS_JSON, MIHOMO_ACTIVE_JSON] as $f) {
            if (file_exists($f)) $files[] = escapeshellarg(basename($f));
        }
        if (is_dir(MIHOMO_PROFILES_DIR)) {
            $files[] = 'profiles';
        }

        if (empty($files)) {
            $message = gettext('No configuration files to export.');
            $message_type = 'warning';
        } else {
            $fileList = implode(' ', $files);
            list(, $rc) = mihomoExecCommand(
                "tar -czf " . escapeshellarg($tmpTar) .
                " -C " . escapeshellarg(MIHOMO_DIR) . " $fileList"
            );

            if ($rc !== 0) {
                $message = gettext('Failed to create backup archive.');
                $message_type = 'danger';
            } else {
                // Encrypt if requested
                if ($encrypt && !empty($password)) {
                    $tmpEnc = $tmpTar . '.enc';
                    list(, $rc) = mihomoExecCommand(
                        "openssl enc -aes-256-cbc -pbkdf2 -pass pass:" .
                        escapeshellarg($password) . " -in " . escapeshellarg($tmpTar) .
                        " -out " . escapeshellarg($tmpEnc)
                    );
                    if ($rc === 0) {
                        $tmpOut = $tmpEnc;
                        @unlink($tmpTar);
                    }
                }

                // Output file
                header('Content-Type: application/octet-stream');
                header('Content-Disposition: attachment; filename="' . basename($tmpOut) . '"');
                header('Content-Length: ' . filesize($tmpOut));
                readfile($tmpOut);
                @unlink($tmpOut);
                @unlink($tmpTar);
                exit;
            }
        }
    }

    // Import
    if ($action === 'import') {
        if (!isset($_FILES['backup_file']) || $_FILES['backup_file']['error'] !== UPLOAD_ERR_OK) {
            $message = gettext('File upload failed.');
            $message_type = 'danger';
        } else {
            $tmpPath = '/tmp/mihomo-import-' . bin2hex(random_bytes(8)) . '.tar.gz';
            move_uploaded_file($_FILES['backup_file']['tmp_name'], $tmpPath);

            // Decrypt if needed
            $isEncrypted = !empty($_POST['import_encrypted']);
            $password = $_POST['import_password'] ?? '';

            if ($isEncrypted && !empty($password)) {
                $tmpDec = $tmpPath . '.dec';
                list(, $rc) = mihomoExecCommand(
                    "openssl enc -d -aes-256-cbc -pbkdf2 -pass pass:" .
                    escapeshellarg($password) . " -in " . escapeshellarg($tmpPath) .
                    " -out " . escapeshellarg($tmpDec)
                );
                if ($rc !== 0) {
                    $message = gettext('Decryption failed. Wrong password?');
                    $message_type = 'danger';
                    @unlink($tmpPath);
                    goto import_end;
                }
                @unlink($tmpPath);
                $tmpPath = $tmpDec;
            }

            // Create fallback backup
            createBackup('pre-import');

            $policy = $_POST['conflict_policy'] ?? 'merge';

            if ($policy === 'overwrite') {
                list(, $rc) = mihomoExecCommand(
                    "tar -xzf " . escapeshellarg($tmpPath) .
                    " -C " . escapeshellarg(MIHOMO_DIR)
                );
            } else {
                // Merge: extract to tmp, then merge subs.json and profiles
                $tmpExtract = '/tmp/mihomo-import-extract';
                mkdir($tmpExtract, 0750, true);
                mihomoExecCommand(
                    "tar -xzf " . escapeshellarg($tmpPath) .
                    " -C " . escapeshellarg($tmpExtract)
                );

                // Merge subs.json by id
                $importSubs = [];
                if (file_exists("$tmpExtract/subs.json")) {
                    $importSubs = json_decode(file_get_contents("$tmpExtract/subs.json"), true) ?: [];
                }
                $currentSubs = readSubs();
                $currentIds = array_column($currentSubs, 'id');
                foreach ($importSubs as $is) {
                    if (!in_array($is['id'] ?? '', $currentIds)) {
                        $currentSubs[] = $is;
                    }
                }
                writeSubs($currentSubs);

                // Copy profiles (overwrite same name, keep unique)
                if (is_dir("$tmpExtract/profiles")) {
                    if (!is_dir(MIHOMO_PROFILES_DIR)) mkdir(MIHOMO_PROFILES_DIR, 0750, true);
                    foreach (glob("$tmpExtract/profiles/*") as $f) {
                        $dest = MIHOMO_PROFILES_DIR . '/' . basename($f);
                        copy($f, $dest);
                    }
                }

                // base.yaml and override.yaml are file-level overwrites
                if (file_exists("$tmpExtract/base.yaml")) {
                    copy("$tmpExtract/base.yaml", MIHOMO_BASE_YAML);
                }
                if (file_exists("$tmpExtract/override.yaml")) {
                    copy("$tmpExtract/override.yaml", MIHOMO_OVERRIDE_YAML);
                }

                // Cleanup
                mihomoExecCommand("rm -rf " . escapeshellarg($tmpExtract));

                $rc = 0;
            }

            if ($rc !== 0) {
                $message = gettext('Import failed.');
                $message_type = 'danger';
            } else {
                // Validate and apply
                $base = file_exists(MIHOMO_BASE_YAML) ? mihomoYamlParse(file_get_contents(MIHOMO_BASE_YAML)) : [];
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

            @unlink($tmpPath);
        }
    }

    import_end:
    if (isset($tmpPath)) @unlink($tmpPath);

    // Restore backup
    if ($action === 'restore_backup') {
        $filename = $_POST['filename'] ?? '';
        list($ok, $msg) = restoreBackup($filename);
        $message = $msg;
        $message_type = $ok ? 'success' : 'danger';
    }

    // Delete backup
    if ($action === 'delete_backup') {
        $filename = $_POST['filename'] ?? '';
        $path = MIHOMO_BACKUPS_DIR . '/' . basename($filename);
        if (file_exists($path)) {
            @unlink($path);
            $message = gettext('Backup deleted.');
            $message_type = 'success';
        }
    }
}

$backups = listBackups();
?>

<style>
.mihomo-section-title { display: flex; align-items: center; gap: 8px; font-weight: 700; color: #333; padding: 2px 0; }
.mihomo-section-title .fa { color: #777; width: 14px; text-align: center; }
.mihomo-panel-cell { padding-top: 10px !important; padding-bottom: 10px !important; }
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

<!-- ====== Export ====== -->
<section class="col-xs-12">
    <div class="content-box tab-content table-responsive __mb">
        <table class="table table-striped">
            <tbody>
                <tr>
                    <td class="mihomo-panel-cell">
                        <div class="mihomo-section-title">
                            <i class="fa fa-download"></i>
                            <span><?= gettext('Export Configuration') ?></span>
                        </div>
                    </td>
                </tr>
                <tr>
                    <td>
                        <div class="alert alert-warning">
                            <i class="fa fa-exclamation-triangle"></i>
                            <?= gettext('Contains sensitive data (API secret, subscription URLs, proxy credentials). Store securely.') ?>
                        </div>
                        <form method="post">
                            <input type="hidden" name="action" value="export">
                            <div class="checkbox"><label>
                                <input type="checkbox" name="encrypt" id="export-encrypt" onchange="document.getElementById('export-pass-group').style.display=this.checked?'block':'none';">
                                <?= gettext('Encrypt with AES-256-CBC (password required)') ?>
                            </label></div>
                            <div id="export-pass-group" style="display:none;margin-top:8px;">
                                <input type="password" name="export_password" class="form-control" style="width:300px;" placeholder="<?= gettext('Enter encryption password'); ?>">
                            </div>
                            <button type="submit" class="btn btn-primary" style="margin-top:10px;">
                                <i class="fa fa-download"></i> <?= gettext('Download Backup') ?>
                            </button>
                        </form>
                    </td>
                </tr>
            </tbody>
        </table>
    </div>
</section>

<!-- ====== Import ====== -->
<section class="col-xs-12">
    <div class="content-box tab-content table-responsive __mb">
        <table class="table table-striped">
            <tbody>
                <tr>
                    <td class="mihomo-panel-cell">
                        <div class="mihomo-section-title">
                            <i class="fa fa-upload"></i>
                            <span><?= gettext('Import Configuration') ?></span>
                        </div>
                    </td>
                </tr>
                <tr>
                    <td>
                        <form method="post" enctype="multipart/form-data">
                            <input type="hidden" name="action" value="import">
                            <div class="checkbox"><label>
                                <input type="checkbox" name="import_encrypted" id="import-encrypted" onchange="document.getElementById('import-pass-group').style.display=this.checked?'block':'none';">
                                <?= gettext('Backup file is encrypted (enter password)') ?>
                            </label></div>
                            <div id="import-pass-group" style="display:none;margin-top:8px;">
                                <input type="password" name="import_password" class="form-control" style="width:300px;" placeholder="<?= gettext('Enter decryption password'); ?>">
                            </div>
                            <div class="form-group" style="margin-top:10px;">
                                <label><?= gettext('Conflict policy') ?>:</label>
                                <select name="conflict_policy" class="form-control" style="width:300px;">
                                    <option value="merge"><?= gettext('Merge (keep existing items not in backup)') ?></option>
                                    <option value="overwrite"><?= gettext('Overwrite all') ?></option>
                                </select>
                            </div>
                            <div class="form-group">
                                <input type="file" name="backup_file" accept=".tar.gz" required>
                            </div>
                            <button type="submit" class="btn btn-warning">
                                <i class="fa fa-upload"></i> <?= gettext('Import Backup') ?>
                            </button>
                        </form>
                    </td>
                </tr>
            </tbody>
        </table>
    </div>
</section>

<!-- ====== Recent Local Backups ====== -->
<section class="col-xs-12">
    <div class="content-box tab-content table-responsive __mb">
        <table class="table table-striped">
            <tbody>
                <tr>
                    <td class="mihomo-panel-cell">
                        <div class="mihomo-section-title">
                            <i class="fa fa-archive"></i>
                            <span><?= gettext('Recent Local Backups') ?></span>
                        </div>
                    </td>
                </tr>
                <tr>
                    <td>
                        <table class="table table-striped">
                            <thead>
                                <tr>
                                    <th><?= gettext('Date') ?></th>
                                    <th><?= gettext('Size') ?></th>
                                    <th><?= gettext('Actions') ?></th>
                                </tr>
                            </thead>
                            <tbody>
                                <?php foreach ($backups as $b): ?>
                                <tr>
                                    <td><?= date('Y-m-d H:i:s', $b['mtime']); ?></td>
                                    <td><?= number_format($b['size'] / 1024, 1); ?> KB</td>
                                    <td>
                                        <a href="data:application/octet-stream,<?= urlencode(''); ?>" class="btn btn-xs btn-default" onclick="downloadBackup('<?= htmlspecialchars($b['filename'], ENT_QUOTES); ?>'); return false;">
                                            <i class="fa fa-download"></i> <?= gettext('Download') ?>
                                        </a>
                                        <form method="post" style="display:inline;" onsubmit="return confirm('<?= gettext('Restore this backup? Current config will be replaced.'); ?>');">
                                            <input type="hidden" name="action" value="restore_backup">
                                            <input type="hidden" name="filename" value="<?= htmlspecialchars($b['filename'], ENT_QUOTES); ?>">
                                            <button type="submit" class="btn btn-xs btn-warning">
                                                <i class="fa fa-undo"></i> <?= gettext('Restore') ?>
                                            </button>
                                        </form>
                                        <form method="post" style="display:inline;" onsubmit="return confirm('<?= gettext('Delete this backup?') ?>');">
                                            <input type="hidden" name="action" value="delete_backup">
                                            <input type="hidden" name="filename" value="<?= htmlspecialchars($b['filename'], ENT_QUOTES); ?>">
                                            <button type="submit" class="btn btn-xs btn-danger">
                                                <i class="fa fa-trash"></i> <?= gettext('Delete') ?>
                                            </button>
                                        </form>
                                    </td>
                                </tr>
                                <?php endforeach; ?>
                                <?php if (empty($backups)): ?>
                                <tr><td colspan="3" style="text-align:center;color:#999;"><i><?= gettext('No local backups found.') ?></i></td></tr>
                                <?php endif; ?>
                            </tbody>
                        </table>
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
function downloadBackup(filename) {
    window.location.href = '/mihomo_backup.php?download=' + encodeURIComponent(filename);
}
</script>

<?php include 'foot.inc'; ?>
