<?php

/**
 * /api/mihomo/dashboard/* — realtime data forwarder.
 *
 * - trafficAction         — back-end differential rate (up/down + connections + mem).
 * - logsAction            — tail mihomo.log with optional level filter.
 * - healthCheckAction     — kick off async health check, returns uuid.
 * - healthProgressAction  — poll /tmp/mihomo-health-<uuid>.json progress.
 */

namespace OPNsense\Mihomo\Api;

use OPNsense\Base\ApiControllerBase;

class DashboardController extends ApiControllerBase
{
    use MihomoFileTrait;

    /** Back-end traffic state — survives FPM workers via /tmp file. */
    private static $TRAFFIC_STATE_FILE = '/tmp/mihomo-traffic-state.json';

    /** GET /api/mihomo/dashboard/traffic */
    public function trafficAction()
    {
        $now = microtime(true);

        $tr  = $this->mihomoApiCall('traffic',     'GET', null, 2);
        $mem = $this->mihomoApiCall('memory',      'GET', null, 2);
        $cs  = $this->mihomoApiCall('connections', 'GET', null, 2);

        $upTotal   = 0;
        $downTotal = 0;
        if (!empty($tr['ok']) && is_array($tr['body'])) {
            $upTotal   = (int)($tr['body']['up'] ?? 0);
            $downTotal = (int)($tr['body']['down'] ?? 0);
        } elseif (!empty($tr['ok']) && is_string($tr['body'])) {
            // /traffic streams chunked JSON — first frame is enough.
            $first = strtok($tr['body'], "\n");
            $j = json_decode((string)$first, true);
            if (is_array($j)) {
                $upTotal   = (int)($j['up']   ?? 0);
                $downTotal = (int)($j['down'] ?? 0);
            }
        }

        $memory      = 0;
        if (!empty($mem['ok']) && is_array($mem['body'])) {
            $memory = (int)($mem['body']['inuse'] ?? 0);
        } elseif (!empty($mem['ok']) && is_string($mem['body'])) {
            $first = strtok($mem['body'], "\n");
            $j = json_decode((string)$first, true);
            if (is_array($j)) {
                $memory = (int)($j['inuse'] ?? 0);
            }
        }

        $connCount    = 0;
        $connUpTotal  = 0;
        $connDnTotal  = 0;
        if (!empty($cs['ok']) && is_array($cs['body'])) {
            $connCount   = is_array($cs['body']['connections'] ?? null)
                            ? count($cs['body']['connections']) : 0;
            $connUpTotal = (int)($cs['body']['uploadTotal']   ?? 0);
            $connDnTotal = (int)($cs['body']['downloadTotal'] ?? 0);
        }

        // Differential rate based on previous totals.
        $prev = [];
        if (is_file(self::$TRAFFIC_STATE_FILE)) {
            $prev = json_decode((string)@file_get_contents(self::$TRAFFIC_STATE_FILE), true) ?: [];
        }
        $upRate   = 0;
        $downRate = 0;
        if (!empty($prev) && isset($prev['ts'])) {
            $dt = max(0.5, $now - (float)$prev['ts']);
            $upRate   = max(0, (int)(($connUpTotal - (int)($prev['up']   ?? 0)) / $dt));
            $downRate = max(0, (int)(($connDnTotal - (int)($prev['down'] ?? 0)) / $dt));
        }

        @file_put_contents(self::$TRAFFIC_STATE_FILE, json_encode([
            'ts'   => $now,
            'up'   => $connUpTotal,
            'down' => $connDnTotal,
        ]));

        return [
            'upRate'          => $upRate,
            'downRate'        => $downRate,
            'upTotal'         => $connUpTotal,
            'downTotal'       => $connDnTotal,
            'memory'          => $memory,
            'connections'     => $connCount,
            'connectionTotal' => $connUpTotal + $connDnTotal,
        ];
    }

    /** GET /api/mihomo/dashboard/logs?lines=N&level=warning */
    public function logsAction()
    {
        $lines = max(1, min(2000, (int)$this->request->get('lines', null, 100)));
        $level = (string)$this->request->get('level', null, '');
        $logs  = $this->tailLines(self::$MIHOMO_LOG, $lines);

        if ($level !== '') {
            $kept = [];
            $needle = strtolower($level);
            foreach (explode("\n", $logs) as $l) {
                if (stripos($l, $needle) !== false) {
                    $kept[] = $l;
                }
            }
            $logs = implode("\n", $kept);
        }
        return ['logs' => $logs];
    }

    /**
     * POST /api/mihomo/dashboard/healthCheck
     * Body: {"mode": "quick"|"full"}
     */
    public function healthCheckAction()
    {
        if (!$this->request->isPost()) {
            return ['status' => 'failed', 'message' => 'POST required'];
        }
        $mode = (string)$this->request->getPost('mode', null, 'quick');
        if (!in_array($mode, ['quick', 'full'], true)) {
            $mode = 'quick';
        }

        $uuid = bin2hex(random_bytes(8));
        $profile = $this->getActiveProfileName();

        // Seed the progress file so the front-end has something to read.
        $jobFile = '/tmp/mihomo-health-' . $uuid . '.json';
        @file_put_contents($jobFile, json_encode([
            'state'    => 'running',
            'progress' => ['done' => 0, 'total' => 0],
            'result'   => null,
            'started'  => time(),
        ]));
        @chmod($jobFile, 0640);

        try {
            // Fire and forget — configd action runs in background.
            $this->configdRun('health-check', [$uuid, $profile, $mode]);
        } catch (\Exception $e) {
            @file_put_contents($jobFile, json_encode([
                'state'   => 'failed',
                'message' => $e->getMessage(),
            ]));
            return ['status' => 'failed', 'message' => $e->getMessage()];
        }
        return ['status' => 'ok', 'uuid' => $uuid];
    }

    /** GET /api/mihomo/dashboard/healthProgress?uuid=<uuid> */
    public function healthProgressAction()
    {
        $uuid = (string)$this->request->get('uuid', null, '');
        if (!preg_match('/^[a-f0-9]{8,64}$/', $uuid)) {
            return ['state' => 'failed', 'message' => 'invalid uuid'];
        }
        $file = '/tmp/mihomo-health-' . $uuid . '.json';
        if (!is_file($file)) {
            return ['state' => 'failed', 'message' => 'job not found'];
        }
        $data = json_decode((string)@file_get_contents($file), true);
        if (!is_array($data)) {
            return ['state' => 'failed', 'message' => 'corrupt progress file'];
        }
        // Stale watchdog: if the worker hasn't touched the file in 90s while
        // still claiming to be running, treat it as dead. Catches the rare case
        // where `daemon -f` forks successfully but the script aborts before
        // updating progress.
        if (($data['state'] ?? '') === 'running') {
            $mtime = @filemtime($file) ?: 0;
            if ($mtime > 0 && (time() - $mtime) > 90) {
                $data['state'] = 'failed';
                $data['message'] = 'worker timed out (no progress for 90s)';
            }
        }
        return $data;
    }
}
