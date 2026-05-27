<?php

/**
 * /api/mihomo/backup/* — Backup tab.
 *
 * Bundle = tar.gz of {base.yaml, override.yaml, profiles/}. Optional
 * AES-256-CBC encryption via `openssl enc -pbkdf2`.
 *
 * Note: subscriptions live in OPNsense config.xml so they are NOT included
 * here — the OPNsense built-in backup already covers them.
 */

namespace OPNsense\Mihomo\Api;

use OPNsense\Base\ApiControllerBase;

class BackupController extends ApiControllerBase
{
    use MihomoFileTrait;

    /**
     * POST /api/mihomo/backup/export
     * Multipart form fields: encrypt=1, password=...
     * Streams the tar.gz (optionally encrypted) as a download.
     */
    public function exportAction()
    {
        if (!$this->request->isPost()) {
            return ['status' => 'failed', 'message' => 'POST required'];
        }
        $encrypt = ((int)$this->request->getPost('encrypt', null, 0)) === 1;
        $password = (string)$this->request->getPost('password', null, '');
        if ($encrypt && strlen($password) < 8) {
            return ['status' => 'failed', 'message' => 'password must be at least 8 chars'];
        }

        try {
            $tarFile = $this->createBackup('export');
        } catch (\Exception $e) {
            return ['status' => 'failed', 'message' => $e->getMessage()];
        }

        // Encrypt if requested.
        $outFile = $tarFile;
        if ($encrypt) {
            $encFile = $tarFile . '.enc';
            $cmd = sprintf(
                'openssl enc -aes-256-cbc -pbkdf2 -salt -in %s -out %s -pass env:MIHOMO_BACKUP_PASS 2>&1',
                escapeshellarg($tarFile),
                escapeshellarg($encFile)
            );
            putenv('MIHOMO_BACKUP_PASS=' . $password);
            list($out, $rc) = $this->safeExec($cmd);
            putenv('MIHOMO_BACKUP_PASS=');
            if ($rc !== 0) {
                @unlink($encFile);
                @unlink($tarFile);
                return ['status' => 'failed', 'message' => 'openssl: ' . implode("\n", $out)];
            }
            @unlink($tarFile);
            $outFile = $encFile;
        }

        // Stream to client.
        $downloadName = basename($outFile);
        header('Content-Type: application/octet-stream');
        header('Content-Disposition: attachment; filename="' . $downloadName . '"');
        header('Content-Length: ' . filesize($outFile));
        @readfile($outFile);
        // Keep the artifact under backups/ unless the caller asked us to
        // discard. For now we always keep — pruning is handled by createBackup.
        exit;
    }

    /**
     * POST /api/mihomo/backup/import
     * Multipart: file=<upload>, password=..., strategy=overwrite|merge,
     *            restart=0|1
     */
    public function importAction()
    {
        if (!$this->request->isPost()) {
            return ['status' => 'failed', 'message' => 'POST required'];
        }
        if (empty($_FILES['file']) || $_FILES['file']['error'] !== UPLOAD_ERR_OK) {
            return ['status' => 'failed', 'message' => 'no file uploaded'];
        }
        $strategy = (string)$this->request->getPost('strategy', null, 'overwrite');
        if (!in_array($strategy, ['overwrite', 'merge'], true)) {
            return ['status' => 'failed', 'message' => 'invalid strategy'];
        }
        $password = (string)$this->request->getPost('password', null, '');
        $restart  = ((int)$this->request->getPost('restart', null, 0)) === 1;

        $upload = $_FILES['file']['tmp_name'];
        $isEncrypted = preg_match('/\.enc$/', $_FILES['file']['name']);

        // Decrypt if needed.
        $tarFile = '/tmp/mihomo-restore-' . posix_getpid() . '.tar.gz';
        try {
            if ($isEncrypted) {
                if (strlen($password) < 8) {
                    return ['status' => 'failed', 'message' => 'encrypted backup requires a password'];
                }
                putenv('MIHOMO_BACKUP_PASS=' . $password);
                $cmd = sprintf(
                    'openssl enc -d -aes-256-cbc -pbkdf2 -in %s -out %s -pass env:MIHOMO_BACKUP_PASS 2>&1',
                    escapeshellarg($upload),
                    escapeshellarg($tarFile)
                );
                list($out, $rc) = $this->safeExec($cmd);
                putenv('MIHOMO_BACKUP_PASS=');
                if ($rc !== 0) {
                    return ['status' => 'failed', 'message' => 'decryption failed (wrong password?)'];
                }
            } else {
                if (!@copy($upload, $tarFile)) {
                    return ['status' => 'failed', 'message' => 'cannot stage upload'];
                }
            }

            // Safety: take a fallback backup of current state.
            try { $this->createBackup('pre-restore'); }
            catch (\Exception $e) { /* fall through */ }

            // Extract to a staging dir.
            $stage = '/tmp/mihomo-restore-' . posix_getpid();
            @mkdir($stage, 0750, true);
            $cmd = sprintf('tar -xzf %s -C %s 2>&1', escapeshellarg($tarFile), escapeshellarg($stage));
            list($out, $rc) = $this->safeExec($cmd);
            if ($rc !== 0) {
                $this->recursiveRm($stage);
                return ['status' => 'failed', 'message' => 'tar extract failed: ' . implode("\n", $out)];
            }

            // Apply.
            if ($strategy === 'overwrite') {
                $this->applyOverwrite($stage);
            } else {
                $this->applyMerge($stage);
            }
            $this->recursiveRm($stage);
        } finally {
            @unlink($tarFile);
        }

        // Reload mihomo.
        $apply = $this->atomicConfigUpdate();
        if (!$apply['success']) {
            return ['status' => 'failed', 'message' => 'restore wrote files but reload failed: ' . $apply['message']];
        }
        if ($restart) {
            try { $this->configdRun('restart'); }
            catch (\Exception $e) { /* logged via configd */ }
        }
        return ['status' => 'ok', 'message' => 'restore complete'];
    }

    /** GET /api/mihomo/backup/list */
    public function listAction()
    {
        return ['rows' => $this->listBackups()];
    }

    /**
     * GET /api/mihomo/backup/download?file=<basename>
     * Stream an existing backup to the client.
     */
    public function downloadAction()
    {
        $file = (string)$this->request->get('file', null, '');
        $path = $this->resolveBackup($file);
        if ($path === null) {
            return ['status' => 'failed', 'message' => 'backup not found'];
        }
        header('Content-Type: application/octet-stream');
        header('Content-Disposition: attachment; filename="' . basename($path) . '"');
        header('Content-Length: ' . filesize($path));
        @readfile($path);
        exit;
    }

    /** POST /api/mihomo/backup/restore — restore an existing local backup. */
    public function restoreAction()
    {
        if (!$this->request->isPost()) {
            return ['status' => 'failed', 'message' => 'POST required'];
        }
        $file = (string)$this->request->getPost('file', null, '');
        $path = $this->resolveBackup($file);
        if ($path === null) {
            return ['status' => 'failed', 'message' => 'backup not found'];
        }

        // Reuse import path by spoofing _FILES.
        // importAction reads password + strategy from $_POST directly.
        $_FILES['file'] = [
            'name'     => basename($path),
            'type'     => 'application/octet-stream',
            'tmp_name' => $path,
            'error'    => UPLOAD_ERR_OK,
            'size'     => filesize($path),
        ];
        return $this->importAction();
    }

    /** POST /api/mihomo/backup/delete — drop a local backup file. */
    public function deleteAction()
    {
        if (!$this->request->isPost()) {
            return ['status' => 'failed', 'message' => 'POST required'];
        }
        $file = (string)$this->request->getPost('file', null, '');
        $path = $this->resolveBackup($file);
        if ($path === null) {
            return ['status' => 'failed', 'message' => 'backup not found'];
        }
        @unlink($path);
        return ['status' => 'ok'];
    }

    // ----- internals ---------------------------------------------------

    /** Validate a user-supplied filename against the backups directory. */
    private function resolveBackup($name)
    {
        $name = basename(trim((string)$name));
        if ($name === '' || !preg_match('/^mihomo-[a-zA-Z0-9_.-]+\.tar\.gz(\.enc)?$/', $name)) {
            return null;
        }
        $path = $this->mihomoPath('backups/' . $name);
        return is_file($path) ? $path : null;
    }

    private function applyOverwrite($stage)
    {
        foreach (['base.yaml', 'override.yaml'] as $f) {
            $src = $stage . '/' . $f;
            if (is_file($src)) {
                $this->lockedWrite($this->mihomoPath($f), (string)@file_get_contents($src));
            }
        }
        if (is_dir($stage . '/profiles')) {
            // Replace the entire profiles directory.
            $this->recursiveRm($this->mihomoPath('profiles'));
            @mkdir($this->mihomoPath('profiles'), 0750, true);
            foreach (glob($stage . '/profiles/*') ?: [] as $p) {
                @copy($p, $this->mihomoPath('profiles/' . basename($p)));
                @chmod($this->mihomoPath('profiles/' . basename($p)), 0640);
            }
        }
    }

    private function applyMerge($stage)
    {
        // Merge: backup wins for files it contains, local keeps the rest.
        foreach (['base.yaml', 'override.yaml'] as $f) {
            $src = $stage . '/' . $f;
            if (is_file($src)) {
                $this->lockedWrite($this->mihomoPath($f), (string)@file_get_contents($src));
            }
        }
        if (is_dir($stage . '/profiles')) {
            foreach (glob($stage . '/profiles/*') ?: [] as $p) {
                @copy($p, $this->mihomoPath('profiles/' . basename($p)));
                @chmod($this->mihomoPath('profiles/' . basename($p)), 0640);
            }
        }
    }

    private function recursiveRm($path)
    {
        if (!file_exists($path)) {
            return;
        }
        if (is_dir($path) && !is_link($path)) {
            foreach (glob($path . '/*') ?: [] as $child) {
                $this->recursiveRm($child);
            }
            @rmdir($path);
        } else {
            @unlink($path);
        }
    }
}
