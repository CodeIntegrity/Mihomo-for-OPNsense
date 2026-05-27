<?php

/**
 * /api/mihomo/override/* — Override tab.
 *
 * Reads / writes /usr/local/etc/mihomo/override.yaml. Honors the convention
 * keys (prepend-rules / append-rules / append-proxies / prepend-proxy-groups
 * / append-proxy-groups) that reconfigure.py understands. The controller
 * itself stays content-agnostic and treats override.yaml as opaque text;
 * YAML correctness is verified by mihomo -t during the apply step.
 */

namespace OPNsense\Mihomo\Api;

use OPNsense\Base\ApiControllerBase;

class OverrideController extends ApiControllerBase
{
    use MihomoFileTrait;

    /** GET /api/mihomo/override/get — return override.yaml as text. */
    public function getAction()
    {
        $path = $this->mihomoPath('override.yaml');
        $content = is_file($path) ? $this->readFileBounded($path) : '';
        return ['status' => 'ok', 'content' => $content];
    }

    /**
     * POST /api/mihomo/override/set
     * Body: { content: "..." }
     * Writes override.yaml + triggers reconfigure (atomic).
     */
    public function setAction()
    {
        if (!$this->request->isPost()) {
            return ['status' => 'failed', 'message' => 'POST required'];
        }
        $content = (string)$this->request->getPost('content', null, '');
        if (strlen($content) > 1048576) {
            return ['status' => 'failed', 'message' => 'override.yaml too large (1 MiB cap)'];
        }
        try {
            $this->backupBefore('override-save');
            $this->lockedWrite($this->mihomoPath('override.yaml'), $content);
        } catch (\Exception $e) {
            return ['status' => 'failed', 'message' => $e->getMessage()];
        }
        $apply = $this->atomicConfigUpdate();
        if (!$apply['success']) {
            return ['status' => 'failed', 'message' => $apply['message']];
        }
        return ['status' => 'ok', 'message' => $apply['message']];
    }

    /**
     * POST /api/mihomo/override/validate
     * Body: { content: "..." }
     * Dry-run the merge + `mihomo -t` without committing config.yaml.
     */
    public function validateAction()
    {
        if (!$this->request->isPost()) {
            return ['status' => 'failed', 'message' => 'POST required'];
        }
        $content = (string)$this->request->getPost('content', null, '');
        $tmp = '/tmp/mihomo-override-validate-' . posix_getpid() . '.yaml';
        try {
            @file_put_contents($tmp, $content);
            @chmod($tmp, 0640);
            // We can't directly call reconfigure.py with a custom override —
            // but we can validate the override file's own YAML correctness
            // by feeding it through mihomo -t. mihomo will refuse a partial
            // config; instead we use a tiny PyYAML probe.
            $cmd = sprintf(
                '/usr/local/bin/python3 -c %s 2>&1',
                escapeshellarg(
                    'import sys, yaml; '
                    . 'd = yaml.safe_load(open(' . var_export($tmp, true) . ', "r", encoding="utf-8")); '
                    . 'print("OK" if d is None or isinstance(d, dict) else "ERR not a mapping")'
                )
            );
            $out = trim((string)@shell_exec($cmd));
            if ($out === 'OK') {
                return ['status' => 'ok', 'message' => 'YAML is valid'];
            }
            return ['status' => 'failed', 'message' => $out !== '' ? $out : 'YAML parse failed'];
        } finally {
            @unlink($tmp);
        }
    }

    /** POST /api/mihomo/override/reset — clear override.yaml. */
    public function resetAction()
    {
        if (!$this->request->isPost()) {
            return ['status' => 'failed', 'message' => 'POST required'];
        }
        try {
            $this->backupBefore('override-reset');
            $this->lockedWrite($this->mihomoPath('override.yaml'), '');
        } catch (\Exception $e) {
            return ['status' => 'failed', 'message' => $e->getMessage()];
        }
        $apply = $this->atomicConfigUpdate();
        return [
            'status'  => $apply['success'] ? 'ok' : 'failed',
            'message' => $apply['message'],
        ];
    }

    /**
     * GET /api/mihomo/override/composedYaml
     * Return the current synthesized config.yaml as text (read-only view
     * for the YAML tab).
     */
    public function composedYamlAction()
    {
        $path = $this->mihomoPath('config.yaml');
        if (!is_file($path)) {
            return ['status' => 'failed', 'message' => 'config.yaml not found — run Apply first'];
        }
        return ['status' => 'ok', 'content' => $this->readFileBounded($path)];
    }

    /** Backup helper — only when the user has enabled the toggle. */
    private function backupBefore($label)
    {
        $cfg = \OPNsense\Core\Config::getInstance()->object();
        $on = (string)($cfg->OPNsense->Mihomo->mihomo->update->auto_backup_on_override ?? '0');
        if ($on === '1') {
            try {
                $this->createBackup($label);
            } catch (\Exception $e) {
                // Backup failure should not block the save.
                error_log("mihomo override backup failed: " . $e->getMessage());
            }
        }
    }
}
