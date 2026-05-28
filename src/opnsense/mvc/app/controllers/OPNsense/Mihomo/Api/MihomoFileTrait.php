<?php

/**
 * MihomoFileTrait — shared helpers for Mihomo MVC controllers.
 *
 * Responsibilities (PHP side, intentionally thin):
 *   * Locking and atomic file writes (flock + rename).
 *   * Path constants and permission enforcement.
 *   * Reading / tailing log files with size guards.
 *   * Talking to the Mihomo RESTful API on 127.0.0.1:9090.
 *   * Invoking configd actions (start / stop / restart / reconfigure / ...).
 *   * Tar-based backup create / list / restore.
 *
 * Heavy YAML work (parse, merge of base+override+profile, validation via
 * `mihomo -t`) is delegated to `scripts/mihomo/reconfigure.py` so we get
 * a real YAML parser without depending on PECL yaml.
 */

namespace OPNsense\Mihomo\Api;

use OPNsense\Core\Backend;
use OPNsense\Core\Config;

trait MihomoFileTrait
{
    /** Mihomo working directory. */
    public static $MIHOMO_DIR = '/usr/local/etc/mihomo';

    /** Logs (FHS compliant). */
    public static $MIHOMO_LOG = '/var/log/mihomo.log';
    public static $MIHOMO_SUB_LOG = '/var/log/mihomo_sub.log';

    /** Lock timeout for lockedWrite (seconds). */
    public static $LOCK_TIMEOUT = 5;

    /**
     * Return a path relative to the mihomo data dir.
     */
    protected function mihomoPath($rel = '')
    {
        $base = rtrim(self::$MIHOMO_DIR, '/');
        if ($rel === '') {
            return $base;
        }
        // Reject parent traversal.
        if (strpos($rel, '..') !== false) {
            throw new \InvalidArgumentException("path traversal rejected: {$rel}");
        }
        return $base . '/' . ltrim($rel, '/');
    }

    /**
     * Write `$content` to `$file` under an exclusive flock.
     *
     * Returns true on success, throws RuntimeException on lock timeout or IO error.
     * Caller is responsible for setting the desired mode / owner via chmod/chown
     * (this helper preserves an existing file's owner/group when possible).
     */
    protected function lockedWrite($file, $content, $timeout = null)
    {
        $timeout = $timeout === null ? self::$LOCK_TIMEOUT : $timeout;
        $dir = dirname($file);
        if (!is_dir($dir) && !@mkdir($dir, 0770, true) && !is_dir($dir)) {
            throw new \RuntimeException("cannot create directory: {$dir}");
        }

        $fp = @fopen($file, 'c+');
        if ($fp === false) {
            throw new \RuntimeException("cannot open file for writing: {$file}");
        }

        $deadline = microtime(true) + $timeout;
        $locked = false;
        while (microtime(true) < $deadline) {
            if (flock($fp, LOCK_EX | LOCK_NB)) {
                $locked = true;
                break;
            }
            usleep(100000); // 100ms
        }
        if (!$locked) {
            fclose($fp);
            throw new \RuntimeException("lock timeout for: {$file}");
        }

        ftruncate($fp, 0);
        rewind($fp);
        $written = fwrite($fp, $content);
        fflush($fp);
        flock($fp, LOCK_UN);
        fclose($fp);

        if ($written === false || $written !== strlen($content)) {
            throw new \RuntimeException("partial write: {$file}");
        }

        @chmod($file, 0660);
        return true;
    }

    /**
     * Atomic file write (tmp + rename). Suitable for files that should never
     * be observed in a half-written state.
     */
    protected function atomicWrite($file, $content)
    {
        $dir = dirname($file);
        if (!is_dir($dir) && !@mkdir($dir, 0770, true) && !is_dir($dir)) {
            throw new \RuntimeException("cannot create directory: {$dir}");
        }
        $tmp = $file . '.tmp.' . posix_getpid();
        if (@file_put_contents($tmp, $content) === false) {
            throw new \RuntimeException("cannot write tmp file: {$tmp}");
        }
        @chmod($tmp, 0660);
        if (!@rename($tmp, $file)) {
            @unlink($tmp);
            throw new \RuntimeException("rename failed: {$tmp} -> {$file}");
        }
        return true;
    }

    /**
     * Read a file with a size cap (default 5 MiB) to protect PHP memory.
     */
    protected function readFileBounded($file, $maxBytes = 5242880)
    {
        if (!is_file($file)) {
            return '';
        }
        $size = filesize($file);
        if ($size === false) {
            return '';
        }
        if ($size > $maxBytes) {
            // tail the file
            $fp = @fopen($file, 'rb');
            if (!$fp) {
                return '';
            }
            fseek($fp, -$maxBytes, SEEK_END);
            $data = stream_get_contents($fp);
            fclose($fp);
            return $data === false ? '' : $data;
        }
        $data = @file_get_contents($file);
        return $data === false ? '' : $data;
    }

    /**
     * Tail `$lines` lines from a file (efficient for large logs).
     */
    protected function tailLines($file, $lines = 100)
    {
        if (!is_file($file)) {
            return '';
        }
        $lines = max(1, (int)$lines);
        $cmd = sprintf('tail -n %d %s 2>/dev/null', $lines, escapeshellarg($file));
        return $this->execRead($cmd);
    }

    /**
     * Run a shell command and return its stdout. Tries shell_exec first,
     * then proc_open as a fallback (for environments where shell_exec is
     * disabled via disable_functions).
     */
    protected function execRead($cmd)
    {
        $out = (string)@shell_exec($cmd);
        if ($out !== '') {
            return $out;
        }
        if (function_exists('proc_open')) {
            $proc = @proc_open($cmd, [
                0 => ['pipe', 'r'],
                1 => ['pipe', 'w'],
                2 => ['pipe', 'w'],
            ], $pipes);
            if (is_resource($proc)) {
                fclose($pipes[0]);
                $out = stream_get_contents($pipes[1]);
                fclose($pipes[1]);
                fclose($pipes[2]);
                proc_close($proc);
                return (string)$out;
            }
        }
        return '';
    }

    /**
     * Execute a command and return [stdout_lines, exit_code].
     *
     * Tries the native exec() first; falls back to proc_open when exec is
     * disabled via php.ini (disable_functions).
     */
    protected function safeExec($cmd)
    {
        if (function_exists('exec')) {
            $out = []; $rc = 0;
            @exec($cmd, $out, $rc);
            return [$out, $rc];
        }
        if (function_exists('proc_open')) {
            $proc = @proc_open($cmd, [
                0 => ['pipe', 'r'],
                1 => ['pipe', 'w'],
                2 => ['pipe', 'w'],
            ], $pipes);
            if (is_resource($proc)) {
                fclose($pipes[0]);
                $stdout = stream_get_contents($pipes[1]);
                $stderr = stream_get_contents($pipes[2]);
                fclose($pipes[1]);
                fclose($pipes[2]);
                $rc = proc_close($proc);
                $out = array_filter(explode("\n", $stdout . $stderr), function ($l) {
                    return $l !== '';
                });
                return [array_values($out), $rc];
            }
        }
        throw new \RuntimeException('neither exec() nor proc_open() is available');
    }

    /**
     * Invoke a configd action: `configctl mihomo <action> [args...]`.
     *
     * Returns the raw configd response string (caller parses).
     * Falls back to throwing RuntimeException on backend failure.
     */
    protected function configdRun($action, array $args = [])
    {
        // Validate action name — must match configd [section] label (alphanum + dash).
        if (!preg_match('/^[a-zA-Z][a-zA-Z0-9_-]*$/', $action)) {
            throw new \InvalidArgumentException("invalid configd action: {$action}");
        }
        $backend = new Backend();
        $cmd = 'mihomo ' . $action;
        foreach ($args as $a) {
            $a = (string)$a;
            // Args go through configd regex parameter validation — validate safe chars only.
            if (!preg_match('/^[a-zA-Z0-9_.:\/,\-]+$/', $a)) {
                throw new \InvalidArgumentException("invalid configd arg: {$a}");
            }
            $cmd .= ' ' . $a;
        }
        $resp = $backend->configdRun($cmd);
        if ($resp === false) {
            throw new \RuntimeException("configd action failed: mihomo {$action}");
        }
        return $resp;
    }

    /**
     * Atomic config apply.
     *
     * Hands off to `configctl mihomo reconfigure`, which (in reconfigure.py):
     *   1. Renders base.yaml from OPNsense config.xml.
     *   2. Merges base + override.yaml + active profile.
     *   3. Writes /tmp/config.yaml.new and runs `mihomo -t -f` to validate.
     *   4. On success: rename to /usr/local/etc/mihomo/config.yaml + PUT /configs.
     *   5. On failure: leave existing config.yaml untouched and exit non-zero.
     *
     * Returns ['success' => bool, 'message' => string].
     */
    protected function atomicConfigUpdate()
    {
        try {
            $out = $this->configdRun('reconfigure');
        } catch (\Exception $e) {
            return ['success' => false, 'message' => $e->getMessage()];
        }
        $ok = (stripos($out, 'OK') !== false) && (stripos($out, 'fail') === false);
        return ['success' => $ok, 'message' => trim($out)];
    }

    /**
     * Call the Mihomo RESTful API. Reads the controller bind + secret from
     * OPNsense config.xml so we follow Settings changes without a reload.
     */
    protected function mihomoApiCall($path, $method = 'GET', $body = null, $timeout = 5)
    {
        $cfg = Config::getInstance()->object();
        $controller = (string)($cfg->OPNsense->Mihomo->mihomo->controller->external_controller ?? '127.0.0.1:9090');
        $secret     = (string)($cfg->OPNsense->Mihomo->mihomo->controller->secret ?? '');
        // Normalize 0.0.0.0 to 127.0.0.1 for local API calls.
        $controller = preg_replace('/^0\.0\.0\.0/', '127.0.0.1', $controller);
        $url = 'http://' . $controller . '/' . ltrim($path, '/');

        $ch = curl_init($url);
        $headers = ['Accept: application/json'];
        if ($secret !== '') {
            $headers[] = 'Authorization: Bearer ' . $secret;
        }
        if ($body !== null) {
            $headers[] = 'Content-Type: application/json';
            curl_setopt($ch, CURLOPT_POSTFIELDS, is_string($body) ? $body : json_encode($body));
        }
        curl_setopt_array($ch, [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_CUSTOMREQUEST  => $method,
            CURLOPT_HTTPHEADER     => $headers,
            CURLOPT_TIMEOUT        => $timeout,
            CURLOPT_CONNECTTIMEOUT => 2,
        ]);
        $resp = curl_exec($ch);
        $code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
        $err  = curl_error($ch);
        curl_close($ch);

        if ($resp === false) {
            return ['ok' => false, 'status' => 0, 'error' => $err, 'body' => null];
        }
        $decoded = json_decode($resp, true);
        return [
            'ok'     => $code >= 200 && $code < 300,
            'status' => $code,
            'body'   => $decoded === null ? $resp : $decoded,
            'error'  => null,
        ];
    }

    /**
     * Read all profile meta files and return a list:
     *   [{ name, source_type, source_url, sub_id, last_update, node_count, active }]
     */
    protected function readProfiles()
    {
        $dir = $this->mihomoPath('profiles');
        if (!is_dir($dir)) {
            return [];
        }
        $active = $this->getActiveProfileName();
        $result = [];
        foreach (glob($dir . '/*.yaml') ?: [] as $yaml) {
            $name = basename($yaml, '.yaml');
            $metaFile = $dir . '/' . $name . '.meta.json';
            $meta = [];
            if (is_file($metaFile)) {
                $meta = json_decode((string)@file_get_contents($metaFile), true) ?: [];
            }
            $result[] = [
                'name'        => $name,
                'source_type' => $meta['source_type'] ?? 'manual',
                'source_url'  => $meta['source_url']  ?? '',
                'sub_id'      => $meta['sub_id']      ?? '',
                'last_update' => $meta['last_update'] ?? '',
                'node_count'  => $meta['node_count']  ?? 0,
                'active'      => ($name === $active),
            ];
        }
        return $result;
    }

    /** Read the active profile name from OPNsense state.active_profile. */
    protected function getActiveProfileName()
    {
        $cfg = Config::getInstance()->object();
        $name = (string)($cfg->OPNsense->Mihomo->mihomo->state->active_profile ?? '');
        return $name !== '' ? $name : 'default';
    }

    /**
     * Backup helpers — produce / list / restore tar.gz snapshots stored under
     * /usr/local/etc/mihomo/backups/. Encryption is layered by the controller.
     */
    protected function createBackup($label = 'auto')
    {
        $dir = $this->mihomoPath('backups');
        if (!is_dir($dir) && !@mkdir($dir, 0770, true)) {
            throw new \RuntimeException("cannot create backup dir: {$dir}");
        }
        // Only archive files that actually exist — tar exits non-zero
        // when a listed path is missing.
        $mihomoDir = $this->mihomoPath();
        $files = [];
        foreach (['base.yaml', 'override.yaml'] as $f) {
            if (is_file($mihomoDir . '/' . $f)) {
                $files[] = $f;
            }
        }
        if (is_dir($mihomoDir . '/profiles')) {
            $files[] = 'profiles';
        }
        if (empty($files)) {
            throw new \RuntimeException('nothing to backup — no base.yaml or profiles/ found');
        }
        $ts = date('Ymd-His');
        $safeLabel = preg_replace('/[^a-zA-Z0-9_-]/', '_', $label);
        $file = sprintf('%s/mihomo-%s-%s.tar.gz', $dir, $safeLabel, $ts);
        $cmd = sprintf(
            'tar -czf %s -C %s %s 2>&1',
            escapeshellarg($file),
            escapeshellarg($mihomoDir),
            implode(' ', array_map('escapeshellarg', $files))
        );
        list($out, $rc) = $this->safeExec($cmd);
        if ($rc !== 0) {
            @unlink($file);
            throw new \RuntimeException('tar failed: ' . implode("\n", $out));
        }
        @chmod($file, 0660);
        $this->pruneBackups($dir, 10);
        return $file;
    }

    protected function listBackups()
    {
        $dir = $this->mihomoPath('backups');
        if (!is_dir($dir)) {
            return [];
        }
        $files = glob($dir . '/mihomo-*.tar.gz*') ?: [];
        $out = [];
        foreach ($files as $f) {
            $out[] = [
                'file'  => basename($f),
                'path'  => $f,
                'size'  => filesize($f) ?: 0,
                'mtime' => filemtime($f) ?: 0,
            ];
        }
        usort($out, function ($a, $b) { return $b['mtime'] <=> $a['mtime']; });
        return $out;
    }

    /** Keep only the newest `$keep` backups. */
    private function pruneBackups($dir, $keep)
    {
        $files = glob($dir . '/mihomo-*.tar.gz*') ?: [];
        usort($files, function ($a, $b) { return filemtime($b) <=> filemtime($a); });
        for ($i = $keep; $i < count($files); $i++) {
            @unlink($files[$i]);
        }
    }
}
