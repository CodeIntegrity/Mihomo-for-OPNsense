<?php

/**
 * /api/mihomo/service/* — lifecycle endpoints.
 *
 * Returns plain JSON. All mutating actions require POST. Service state is
 * read by parsing `service mihomo status` output and `ps`.
 */

namespace OPNsense\Mihomo\Api;

use OPNsense\Base\ApiControllerBase;

class ServiceController extends ApiControllerBase
{
    use MihomoFileTrait;

    /** GET /api/mihomo/service/status */
    public function statusAction()
    {
        $out = '';
        try {
            $out = $this->configdRun('status');
        } catch (\Exception $e) {
            return ['status' => 'unknown', 'message' => $e->getMessage()];
        }

        $notRunning = preg_match('/\bis not running\b|pid file exists but process is not running/i', $out);
        $running = !$notRunning && (
            preg_match('/\bis running\b/i', $out) ||
            preg_match('/\bwrapper is running as pid\s+\d+/i', $out) ||
            preg_match('/\bprocess is running as pid\s+\d+/i', $out)
        );
        $pid = null;
        // rc.d/mihomo prints "daemon pid X, mihomo pid Y" — prefer the mihomo
        // child so uptime reflects the actual process, not the daemon(8) wrapper.
        if (preg_match('/mihomo pid\s+(\d+)/i', $out, $m)) {
            $pid = (int)$m[1];
        } elseif (preg_match('/pid\s+(\d+)/i', $out, $m)) {
            $pid = (int)$m[1];
        }

        $uptime = null;
        if ($running && $pid) {
            // FreeBSD ps -o etimes= gives elapsed seconds.
            $val = trim($this->execRead(sprintf('ps -o etimes= -p %d 2>/dev/null', $pid)));
            if ($val !== '' && ctype_digit($val)) {
                $uptime = (int)$val;
            }
        }

        $version = $this->readMihomoVersion();

        return [
            'status'  => $running ? 'running' : 'stopped',
            'pid'     => $pid,
            'uptime'  => $uptime,
            'version' => $version,
        ];
    }

    /** POST /api/mihomo/service/start */
    public function startAction()
    {
        return $this->mutate('start');
    }

    /** POST /api/mihomo/service/stop */
    public function stopAction()
    {
        return $this->mutate('stop');
    }

    /** POST /api/mihomo/service/restart */
    public function restartAction()
    {
        return $this->mutate('restart');
    }

    /** POST /api/mihomo/service/reconfigure */
    public function reconfigureAction()
    {
        if (!$this->request->isPost()) {
            return ['status' => 'failed', 'message' => 'POST required'];
        }
        $result = $this->atomicConfigUpdate();
        return [
            'status'  => $result['success'] ? 'ok' : 'failed',
            'message' => $result['message'],
        ];
    }

    private function mutate($action)
    {
        if (!$this->request->isPost()) {
            return ['status' => 'failed', 'message' => 'POST required'];
        }
        try {
            $out = $this->configdRun($action);
            return ['status' => 'ok', 'message' => trim($out)];
        } catch (\Exception $e) {
            return ['status' => 'failed', 'message' => $e->getMessage()];
        }
    }

    /** Cache mihomo -v output (cheap but not free). */
    private function readMihomoVersion()
    {
        static $cached = null;
        if ($cached !== null) {
            return $cached;
        }
        $bin = '/usr/local/bin/mihomo';
        if (!is_executable($bin)) {
            return $cached = '';
        }
        $out = $this->execRead(escapeshellarg($bin) . ' -v 2>&1');
        if ($out === '') {
            return $cached = '';
        }
        // Typical first line: "Mihomo Meta vX.Y.Z linux amd64 with go..."
        $line = strtok($out, "\n");
        if (preg_match('/v[\d.]+/', $line, $m)) {
            return $cached = $m[0];
        }
        return $cached = trim($line);
    }
}
