<?php

/**
 * /api/mihomo/update/* — Updates tab.
 *
 * Three resources: core (mihomo binary), geoip (Country.mmdb), ui (Dashboard
 * UI). Each is independently checkable and updatable.
 *
 * Check uses a 1-hour cached GitHub /releases/latest response in
 * /tmp/mihomo-release-cache-<resource>.json. With an optional GitHub Token
 * the API rate limit jumps from 60/h to 5000/h.
 *
 * Update kicks the matching configd action (update-core / update-geoip /
 * update-ui) which is wrapped in `daemon -f`. The bash script writes
 * progress into /tmp/mihomo-update-<resource>.json which we surface via
 * progressAction.
 */

namespace OPNsense\Mihomo\Api;

use OPNsense\Base\ApiControllerBase;
use OPNsense\Core\Config;

class UpdateController extends ApiControllerBase
{
    use MihomoFileTrait;

    /** Resource → GitHub repo. */
    private static $RESOURCES = [
        'core'  => 'MetaCubeX/mihomo',
        'geoip' => 'MetaCubeX/meta-rules-dat',
        'ui'    => null, // resolved at runtime per variant
    ];

    /** UI variant → GitHub repo (used when resource=ui). */
    private static $UI_REPOS = [
        'zashboard'   => 'Zephyruso/zashboard',
        'metacubexd' => 'MetaCubeX/metacubexd',
        'yacd'       => 'haishanh/yacd',
    ];

    /** Last fetch error details (set by fetchLatestRelease). */
    private $_lastFetchCode = 0;
    private $_lastFetchError = null;

    /**
     * GET /api/mihomo/update/check?resource=<core|geoip|ui>&variant=<...>
     * Returns { current, latest, hasUpdate, cached_at }.
     */
    public function checkAction()
    {
        $resource = (string)$this->request->get('resource', null, '');
        if (!in_array($resource, ['core', 'geoip', 'ui'], true)) {
            return ['status' => 'failed', 'message' => 'unknown resource'];
        }
        $variant = (string)$this->request->get('variant', null, 'zashboard');
        $force   = ((int)$this->request->get('force', null, 0)) === 1;

        // GeoIP with custom URL — bypass GitHub entirely.
        if ($resource === 'geoip') {
            $customUrl = $this->getGeoipCustomUrl();
            if ($customUrl !== '') {
                return $this->checkGeoipCustomUrl($customUrl);
            }
        }

        $repo = $resource === 'ui'
            ? (self::$UI_REPOS[$variant] ?? null)
            : self::$RESOURCES[$resource];
        if ($repo === null) {
            return ['status' => 'failed', 'message' => 'unknown variant'];
        }

        $cacheKey = $resource === 'ui' ? $resource . '-' . $variant : $resource;
        $cacheFile = '/tmp/mihomo-release-cache-' . $cacheKey . '.json';
        $latest = $this->loadCachedRelease($cacheFile, $force);
        if ($latest === null) {
            $latest = $this->fetchLatestRelease($repo);
            if ($latest === null) {
                // Surface a sensible message when offline or rate-limited.
                if (is_file($cacheFile)) {
                    $latest = json_decode((string)@file_get_contents($cacheFile), true) ?: null;
                }
                if ($latest === null) {
                    $msg = 'GitHub API unavailable';
                    $code = $this->_lastFetchCode ?? 0;
                    if ($code === 403) {
                        $msg = 'GitHub API rate limited — configure a token in Settings > Auto Update';
                    } elseif ($code > 0) {
                        $msg = "GitHub API returned HTTP {$code}";
                    } elseif ($err = $this->_lastFetchError ?? null) {
                        $msg = "GitHub API unreachable: {$err}";
                    }
                    return ['status' => 'failed', 'message' => $msg];
                }
            } else {
                @file_put_contents($cacheFile, json_encode($latest));
                @chmod($cacheFile, 0640);
            }
        }

        return [
            'status'     => 'ok',
            'resource'   => $resource,
            'variant'    => $resource === 'ui' ? $variant : null,
            'current'    => $this->detectCurrentVersion($resource, $variant),
            'latest'     => (string)($latest['tag_name'] ?? ''),
            'cached_at'  => is_file($cacheFile) ? filemtime($cacheFile) : null,
        ];
    }

    /**
     * POST /api/mihomo/update/run
     * Body: { resource: "...", variant: "..." (optional) }
     * Kick the configd update action (runs in background via daemon -f).
     */
    public function runAction()
    {
        if (!$this->request->isPost()) {
            return ['status' => 'failed', 'message' => 'POST required'];
        }
        $resource = (string)$this->request->getPost('resource', null, '');
        if (!in_array($resource, ['core', 'geoip', 'ui'], true)) {
            return ['status' => 'failed', 'message' => 'unknown resource'];
        }
        $variant = (string)$this->request->getPost('variant', null, 'zashboard');

        // Seed progress file so the front-end always has something to read.
        $progressFile = '/tmp/mihomo-update-' . $resource . '.json';
        @file_put_contents($progressFile, json_encode([
            'state'   => 'running',
            'step'    => 'starting',
            'percent' => 0,
            'started' => time(),
        ]));
        @chmod($progressFile, 0640);

        try {
            if ($resource === 'ui') {
                if (!isset(self::$UI_REPOS[$variant])) {
                    return ['status' => 'failed', 'message' => 'unknown variant'];
                }
                $this->configdRun('update-ui', [$variant]);
            } else {
                $this->configdRun('update-' . $resource);
            }
        } catch (\Exception $e) {
            @unlink($progressFile);
            return ['status' => 'failed', 'message' => $e->getMessage()];
        }

        // Verify the background worker actually started.
        // daemon -f returns immediately (its job is to fork), so a successful
        // configd response does NOT mean the Python script is running.  We
        // sleep 2 s then check whether the progress file has been touched by
        // the worker (the `updated` field is only written by the Python
        // side).  If it is still our original seed the worker likely crashed.
        sleep(2);
        $check = json_decode((string)@file_get_contents($progressFile), true);
        if (!is_array($check) || ($check['step'] ?? '') === 'starting') {
            @unlink($progressFile);
            return ['status' => 'failed', 'message' => 'update worker failed to start'];
        }

        return ['status' => 'ok'];
    }

    /** GET /api/mihomo/update/progress?resource=<...> */
    public function progressAction()
    {
        $resource = (string)$this->request->get('resource', null, '');
        if (!in_array($resource, ['core', 'geoip', 'ui'], true)) {
            return ['state' => 'failed', 'message' => 'unknown resource'];
        }
        $file = '/tmp/mihomo-update-' . $resource . '.json';
        if (!is_file($file)) {
            return ['state' => 'idle'];
        }
        $data = json_decode((string)@file_get_contents($file), true);
        if (!is_array($data)) {
            return ['state' => 'failed', 'message' => 'corrupt progress file'];
        }
        // Stale watchdog (5 min — updates can legitimately be slow).
        if (($data['state'] ?? '') === 'running') {
            $mtime = @filemtime($file) ?: 0;
            if ($mtime > 0 && (time() - $mtime) > 300) {
                $data['state'] = 'failed';
                $data['message'] = 'worker timed out (no progress for 5 minutes)';
            }
        }
        return $data;
    }

    // ----- internals ---------------------------------------------------

    /** TTL: 1 hour. */
    private function loadCachedRelease($cacheFile, $force)
    {
        if ($force || !is_file($cacheFile)) {
            return null;
        }
        if ((time() - filemtime($cacheFile)) > 3600) {
            return null;
        }
        $data = json_decode((string)@file_get_contents($cacheFile), true);
        return is_array($data) ? $data : null;
    }

    private function fetchLatestRelease($repo)
    {
        $cfg = Config::getInstance()->object();
        $mirror = (string)($cfg->OPNsense->Mihomo->mihomo->update->github_mirror ?? '');
        $token  = (string)($cfg->OPNsense->Mihomo->mihomo->update->github_token  ?? '');

        $url = rtrim($mirror, '/');
        // Mirrors typically prefix the GitHub URL; if no mirror, hit api directly.
        if ($url === '') {
            $url = 'https://api.github.com/repos/' . $repo . '/releases/latest';
        } else {
            $url .= '/https://api.github.com/repos/' . $repo . '/releases/latest';
        }

        $ch = curl_init($url);
        $headers = [
            'Accept: application/vnd.github+json',
            'User-Agent: Mihomo-for-OPNsense',
        ];
        if ($token !== '') {
            $headers[] = 'Authorization: Bearer ' . $token;
        }
        curl_setopt_array($ch, [
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_HTTPHEADER     => $headers,
            CURLOPT_TIMEOUT        => 8,
            CURLOPT_CONNECTTIMEOUT => 4,
            CURLOPT_FOLLOWLOCATION => true,
            CURLOPT_MAXREDIRS      => 3,
        ]);
        $body = curl_exec($ch);
        $code = curl_getinfo($ch, CURLINFO_HTTP_CODE);
        $error = curl_error($ch) ?: null;
        curl_close($ch);
        if ($body === false || $code < 200 || $code >= 300) {
            $this->_lastFetchCode = $code;
            $this->_lastFetchError = $error;
            return null;
        }
        $data = json_decode((string)$body, true);
        if (!is_array($data) || empty($data['tag_name'])) {
            $this->_lastFetchCode = $code;
            $this->_lastFetchError = 'empty or malformed response';
            return null;
        }
        // Slim down — we only ever need a few fields.
        // Include "assets" so the Python update scripts can reuse this cache
        // (they require both "tag_name" AND "assets" to consider a cache valid).
        return [
            'tag_name'     => (string)$data['tag_name'],
            'published_at' => (string)($data['published_at'] ?? ''),
            'html_url'     => (string)($data['html_url'] ?? ''),
            'assets'       => array_map(function ($a) {
                return [
                    'name' => (string)($a['name'] ?? ''),
                    'url'  => (string)($a['browser_download_url'] ?? ''),
                ];
            }, $data['assets'] ?? []),
        ];
    }

    private function detectCurrentVersion($resource, $variant)
    {
        if ($resource === 'core') {
            $bin = '/usr/local/bin/mihomo';
            if (!is_executable($bin)) {
                return '';
            }
            $out = $this->execRead(escapeshellarg($bin) . ' -v 2>&1');
            if (preg_match('/\b(v?\d+\.\d[\d.]*)/', $out, $m)) {
                $ver = $m[1];
                if ($ver[0] !== 'v') {
                    $ver = 'v' . $ver;
                }
                return $ver;
            }
            return trim(strtok($out, "\n"));
        }
        if ($resource === 'geoip') {
            $file = '/usr/local/etc/mihomo/Country.mmdb';
            if (!is_file($file)) {
                return '';
            }
            return date('Y-m-d', filemtime($file) ?: time());
        }
        if ($resource === 'ui') {
            $verFile = '/usr/local/etc/mihomo/ui/.version-' . $variant;
            if (is_file($verFile)) {
                return trim((string)@file_get_contents($verFile));
            }
            return '';
        }
        return '';
    }

    /** Read geoip_url from config.xml. */
    private function getGeoipCustomUrl()
    {
        try {
            $cfg = Config::getInstance()->object();
            return trim((string)($cfg->OPNsense->Mihomo->mihomo->update->geoip_url ?? ''));
        } catch (\Exception $e) {
            return '';
        }
    }

    /**
     * Check GeoIP update via custom URL (HEAD request for Last-Modified /
     * Content-Length). Falls back gracefully — always enables the update
     * button so the user can force a re-download.
     */
    private function checkGeoipCustomUrl($url)
    {
        $current = $this->detectCurrentVersion('geoip', '');
        $latest = '';
        $remoteDate = null;
        $headOk = false;

        // Best-effort HEAD to compare Last-Modified and Content-Length.
        $ch = curl_init($url);
        curl_setopt_array($ch, [
            CURLOPT_NOBODY         => true,
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_TIMEOUT        => 5,
            CURLOPT_CONNECTTIMEOUT => 3,
            CURLOPT_FOLLOWLOCATION => true,
            CURLOPT_MAXREDIRS      => 2,
        ]);
        curl_exec($ch);
        $httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
        if ($httpCode >= 200 && $httpCode < 400) {
            $headOk = true;
            $lastMod = curl_getinfo($ch, CURLINFO_FILETIME);
            if ($lastMod > 0) {
                $remoteDate = date('Y-m-d', $lastMod);
                $latest = $remoteDate;
            }
            $remoteSize = curl_getinfo($ch, CURLINFO_CONTENT_LENGTH_DOWNLOAD);
            // Never show raw byte count as a version string.
            if ($remoteSize > 0 && $remoteDate === null) {
                $latest = 'custom URL';
            }
        }
        curl_close($ch);

        if ($latest === '') {
            $latest = $headOk ? 'custom URL' : 'unreachable';
        }

        return [
            'status'     => 'ok',
            'resource'   => 'geoip',
            'variant'    => null,
            'current'    => $current,
            'latest'     => $latest,
            'custom_url' => true,
            'cached_at'  => null,
        ];
    }
}
