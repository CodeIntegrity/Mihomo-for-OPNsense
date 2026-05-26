<?php

/**
 * Mihomo for OPNsense — Public Library
 *
 * Single require_once entry for all Mihomo Web UI pages.
 * Sections:
 *   CONFIG PATHS / FILE LOCKING / ATOMIC CONFIG / SERVICE CONTROL
 *   API / YAML / CONFIG MERGE / PROFILE / SUBSCRIPTION
 *   BACKUP / MIGRATION / UTILITY
 */

// ============================================================
// === CONFIG PATHS
// ============================================================

define('MIHOMO_DIR', '/usr/local/etc/mihomo');
define('MIHOMO_BASE_YAML', MIHOMO_DIR . '/base.yaml');
define('MIHOMO_OVERRIDE_YAML', MIHOMO_DIR . '/override.yaml');
define('MIHOMO_CONFIG_YAML', MIHOMO_DIR . '/config.yaml');
define('MIHOMO_SUBS_JSON', MIHOMO_DIR . '/subs.json');
define('MIHOMO_ACTIVE_JSON', MIHOMO_DIR . '/active.json');
define('MIHOMO_PROFILES_DIR', MIHOMO_DIR . '/profiles');
define('MIHOMO_BACKUPS_DIR', MIHOMO_DIR . '/backups');
define('MIHOMO_LOG', '/var/log/mihomo.log');
define('MIHOMO_SUB_LOG', '/var/log/mihomo_sub.log');
define('MIHOMO_MIGRATED_FLAG', MIHOMO_DIR . '/.migrated-v2');
define('MIHOMO_MIGRATE_ERROR', '/tmp/mihomo-migrate-error.txt');
define('MIHOMO_TRAFFIC_STATE', '/tmp/mihomo-traffic-state.json');
define('MIHOMO_RELEASE_CACHE', '/tmp/mihomo-latest-release.json');

// ============================================================
// === UTILITY
// ============================================================

function mihomoExecCommand($command) {
    $output = [];
    $return_var = 0;
    exec($command . ' 2>&1', $output, $return_var);
    return [implode("\n", $output), $return_var];
}

function mihomoExecBackground($command) {
    $bg = 'nohup sh -c ' . escapeshellarg($command) . ' >/dev/null 2>&1 &';
    exec($bg);
}

// ============================================================
// === FILE LOCKING
// ============================================================

/**
 * Write file with exclusive lock. Returns true on success, throws on timeout.
 */
function lockedWrite($file, $content, $timeout = 5) {
    $dir = dirname($file);
    if (!is_dir($dir)) {
        @mkdir($dir, 0750, true);
    }

    $fp = @fopen($file, 'c+');
    if (!$fp) {
        throw new RuntimeException("Cannot open file for writing: $file");
    }

    $deadline = microtime(true) + $timeout;
    $locked = false;

    while (microtime(true) < $deadline) {
        if (flock($fp, LOCK_EX | LOCK_NB)) {
            $locked = true;
            break;
        }
        usleep(50000); // 50ms
    }

    if (!$locked) {
        fclose($fp);
        throw new RuntimeException("Lock timeout on file: $file");
    }

    ftruncate($fp, 0);
    rewind($fp);
    $written = fwrite($fp, $content);
    fflush($fp);
    flock($fp, LOCK_UN);
    fclose($fp);

    if ($written === false || $written !== strlen($content)) {
        throw new RuntimeException("Write incomplete for file: $file");
    }

    return true;
}

// ============================================================
// === ATOMIC CONFIG UPDATE
// ============================================================

/**
 * Atomically update config.yaml with validation.
 * All config.yaml modification paths MUST use this function.
 *
 * @return array [success: bool, message: string]
 */
function atomicConfigUpdate($newContent) {
    $tmpFile = '/tmp/config.yaml.new';
    $configFile = MIHOMO_CONFIG_YAML;

    // 1. Write tmp
    if (@file_put_contents($tmpFile, $newContent, LOCK_EX) === false) {
        return [false, gettext('Failed to write temporary config file.')];
    }

    // 2. Validate with mihomo -t
    list($output, $rc) = mihomoExecCommand(
        '/usr/local/bin/mihomo -d ' . escapeshellarg(MIHOMO_DIR) .
        ' -t -f ' . escapeshellarg($tmpFile)
    );

    if ($rc !== 0) {
        @unlink($tmpFile);
        return [false, gettext('Config validation failed:') . "\n" . $output];
    }

    // 3. Create backup of current config
    if (file_exists($configFile)) {
        $bak = $configFile . '.bak.' . date('Ymd_His');
        @copy($configFile, $bak);
    }

    // 4. Atomic mv
    if (!@rename($tmpFile, $configFile)) {
        @unlink($tmpFile);
        return [false, gettext('Failed to replace config file.')];
    }

    // 5. Reload mihomo
    list($ok, $msg) = reloadMihomo();
    if (!$ok) {
        return [false, gettext('Config saved but reload failed:') . ' ' . $msg];
    }

    return [true, gettext('Config saved and reloaded successfully.')];
}

// ============================================================
// === SERVICE CONTROL
// ============================================================

/**
 * Hot-reload mihomo config via API, fallback to restart.
 */
function reloadMihomo() {
    $secret = secretFromBase();
    $controller = controllerFromBase();

    if ($controller && $secret) {
        // Try PUT /configs?force=true
        $ctx = stream_context_create([
            'http' => [
                'method' => 'PUT',
                'header' => "Authorization: Bearer $secret\r\nContent-Type: application/json\r\n",
                'content' => json_encode(['path' => '', 'payload' => '']),
                'timeout' => 5,
                'ignore_errors' => true,
            ],
        ]);
        $url = "http://{$controller}/configs?force=true";
        $result = @file_get_contents($url, false, $ctx);

        if ($result !== false) {
            // Delay to avoid false-positive status check
            usleep(1500000); // 1.5s
            $status = getMihomoStatus();
            if ($status['status'] === 'running') {
                return [true, gettext('Config hot-reloaded.')];
            }
        }
    }

    // Fallback: restart
    return restartMihomo();
}

function restartMihomo() {
    list($output, $rc) = mihomoExecCommand('/usr/local/sbin/configctl mihomo restart');

    // Poll up to 10s for running state
    for ($i = 0; $i < 20; $i++) {
        usleep(500000);
        $status = getMihomoStatus();
        if ($status['status'] === 'running') {
            return [true, gettext('Service restarted and running.')];
        }
    }

    return [false, gettext('Service restart failed or not running after 10s.')];
}

/**
 * Get mihomo service status with pid and uptime.
 *
 * @return array [status: 'running'|'stopped', pid: int|null, uptime: string|null]
 */
function getMihomoStatus() {
    list($output, $rc) = mihomoExecCommand('/usr/local/sbin/configctl mihomo status');

    if (stripos($output, 'is running') !== false) {
        $pid = null;
        $uptime = null;

        // Extract mihomo pid from status output
        if (preg_match('/mihomo pid (\d+)/', $output, $m)) {
            $pid = (int)$m[1];
        } elseif (preg_match('/daemon pid (\d+)/', $output, $m)) {
            // Try to find child mihomo process
            $ppid = (int)$m[1];
            $childPid = trim(shell_exec("pgrep -P $ppid mihomo 2>/dev/null | head -n 1") ?: '');
            if ($childPid && ctype_digit($childPid)) {
                $pid = (int)$childPid;
            }
        }

        // Calculate uptime from pid
        if ($pid) {
            $uptime = trim(shell_exec("ps -o etime= -p $pid 2>/dev/null") ?: '');
        }

        return ['status' => 'running', 'pid' => $pid, 'uptime' => $uptime];
    }

    return ['status' => 'stopped', 'pid' => null, 'uptime' => null];
}

// ============================================================
// === API HELPERS
// ============================================================

/**
 * Call Mihomo REST API.
 *
 * @return array [success: bool, data: mixed]
 */
function mihomoApiCall($path, $method = 'GET', $body = null) {
    $controller = controllerFromBase();
    $secret = secretFromBase();

    if (!$controller) {
        return [false, 'External controller not configured.'];
    }

    $url = "http://{$controller}{$path}";
    $header = $secret ? "Authorization: Bearer $secret\r\n" : '';
    $header .= "Content-Type: application/json\r\n";

    $opts = [
        'http' => [
            'method' => $method,
            'header' => $header,
            'timeout' => 5,
            'ignore_errors' => true,
        ],
    ];

    if ($body !== null) {
        $opts['http']['content'] = is_array($body) ? json_encode($body) : $body;
    }

    $ctx = stream_context_create($opts);
    $result = @file_get_contents($url, false, $ctx);

    if ($result === false) {
        return [false, "API request failed: $path"];
    }

    $data = json_decode($result, true);
    return [true, $data ?: $result];
}

function secretFromBase() {
    static $secret = null;
    if ($secret !== null) return $secret;

    if (!file_exists(MIHOMO_BASE_YAML)) return '';

    $yaml = mihomoYamlParse(file_get_contents(MIHOMO_BASE_YAML));
    $secret = isset($yaml['secret']) ? (string)$yaml['secret'] : '';
    return $secret;
}

function controllerFromBase() {
    static $controller = null;
    if ($controller !== null) return $controller;

    if (!file_exists(MIHOMO_BASE_YAML)) return '';

    $yaml = mihomoYamlParse(file_get_contents(MIHOMO_BASE_YAML));
    $controller = isset($yaml['external-controller']) ? (string)$yaml['external-controller'] : '';
    return $controller;
}

// ============================================================
// === YAML (simplified parser/dumper for Mihomo config subset)
// ============================================================

/**
 * Parse Mihomo-config-subset YAML into PHP array.
 *
 * Handles: nested mappings, lists of scalars, lists of mappings,
 * quoted strings, comments. Does NOT handle anchors/aliases/tags.
 */
function mihomoYamlParse($yaml) {
    $lines = explode("\n", $yaml);
    return mihomoYamlParseLines($lines, 0, 0)[0];
}

function mihomoYamlParseLines(&$lines, $i, $indent) {
    $result = [];
    $listContext = false;
    $listIndex = 0;
    $key = null;

    while ($i < count($lines)) {
        $line = $lines[$i];
        $trimmed = rtrim($line);

        // Empty or comment-only
        if ($trimmed === '' || preg_match('/^\s*#/', $trimmed)) {
            $i++;
            continue;
        }

        // Detect indent level
        if (!preg_match('/^(\s*)(.*)$/', $line, $m)) {
            $i++;
            continue;
        }
        $curIndent = strlen($m[1]);
        $content = $m[2];

        // Comment after content
        $content = preg_replace('/\s+#.*$/', '', $content);

        // Back to parent level
        if ($curIndent < $indent) {
            break;
        }

        // List item
        if (preg_match('/^-\s+(.*)$/', $content, $lm)) {
            $value = $lm[1];

            // Look ahead: next line at deeper indent → list of mappings
            if ($i + 1 < count($lines)) {
                $nextLine = $lines[$i + 1];
                preg_match('/^(\s*)(.*)$/', $nextLine, $nm);
                $nextIndent = strlen($nm[1]);
                $nextContent = $nm[2];

                if ($nextContent !== '' && $nextIndent > $curIndent && !preg_match('/^\s*#/', $nextLine)) {
                    // Recurse: parse nested mapping
                    list($nested, $i) = mihomoYamlParseLines($lines, $i + 1, $nextIndent);
                    $result[] = $nested;
                    continue;
                }
            }

            // Scalar list item
            if ($value === '' || $value === '""' || $value === "''") {
                $result[] = '';
            } elseif (is_numeric($value)) {
                $result[] = strpos($value, '.') !== false ? (float)$value : (int)$value;
            } elseif ($value === 'true' || $value === 'false') {
                $result[] = $value === 'true';
            } else {
                $result[] = mihomoYamlUnquote($value);
            }
            $i++;
            continue;
        }

        // Key: value
        if (preg_match('/^([^:]+):\s*(.*)$/', $content, $km)) {
            $key = trim($km[1]);
            $value = $km[2];

            // Quoted key
            $key = mihomoYamlUnquote($key);

            // Look ahead for nested content (next line(s) at deeper indent)
            if ($i + 1 < count($lines)) {
                $nextLine = $lines[$i + 1];
                preg_match('/^(\s*)(.*)$/', $nextLine, $nm);
                $nextIndent = strlen($nm[1]);
                $nextContent = $nm[2];

                if ($nextContent !== '' && $nextIndent > $curIndent && !preg_match('/^\s*#/', $nextLine)) {
                    // Recursively parse nested
                    list($nested, $i) = mihomoYamlParseLines($lines, $i + 1, $nextIndent);
                    $result[$key] = $nested;
                    continue;
                }
            }

            // Scalar value
            if ($value === '' || $value === '""' || $value === "''") {
                $result[$key] = '';
            } elseif (is_numeric($value)) {
                $result[$key] = strpos($value, '.') !== false ? (float)$value : (int)$value;
            } elseif ($value === 'true') {
                $result[$key] = true;
            } elseif ($value === 'false') {
                $result[$key] = false;
            } else {
                $result[$key] = mihomoYamlUnquote($value);
            }
            $i++;
            continue;
        }

        $i++;
    }

    return [$result, $i];
}

function mihomoYamlUnquote($s) {
    $s = trim($s);
    if ((strpos($s, "'") === 0 && strrpos($s, "'") === strlen($s) - 1) ||
        (strpos($s, '"') === 0 && strrpos($s, '"') === strlen($s) - 1)) {
        $s = substr($s, 1, -1);
    }
    return $s;
}

/**
 * Dump PHP array to YAML string.
 */
function mihomoYamlDump($data, $indent = 0) {
    $out = '';
    $pad = str_repeat('  ', $indent);

    foreach ($data as $k => $v) {
        if (is_array($v) && mihomoYamlIsList($v)) {
            $out .= $pad . $k . ":\n";
            foreach ($v as $item) {
                if (is_array($item)) {
                    $out .= $pad . '  - ' . rtrim(mihomoYamlDumpMapItem($item, $indent + 2));
                } else {
                    $out .= $pad . '  - ' . mihomoYamlScalar($item) . "\n";
                }
            }
        } elseif (is_array($v)) {
            $out .= $pad . $k . ":\n";
            $out .= mihomoYamlDump($v, $indent + 1);
        } else {
            $out .= $pad . $k . ': ' . mihomoYamlScalar($v) . "\n";
        }
    }

    return $out;
}

function mihomoYamlIsList($arr) {
    if (empty($arr)) return true; // empty arrays treated as lists
    return array_keys($arr) === range(0, count($arr) - 1);
}

function mihomoYamlDumpMapItem($item, $indent) {
    $pad = str_repeat('  ', $indent);
    $lines = '';
    foreach ($item as $k => $v) {
        if (is_array($v) && mihomoYamlIsList($v)) {
            $lines .= $pad . $k . ":\n";
            foreach ($v as $sub) {
                $lines .= $pad . '  - ' . mihomoYamlScalar($sub) . "\n";
            }
        } elseif (is_array($v)) {
            $lines .= $pad . $k . ":\n";
            $lines .= mihomoYamlDump($v, $indent + 1);
        } else {
            $lines .= $pad . $k . ': ' . mihomoYamlScalar($v) . "\n";
        }
    }
    return $lines;
}

function mihomoYamlScalar($v) {
    if (is_bool($v)) return $v ? 'true' : 'false';
    if (is_int($v) || is_float($v)) return (string)$v;
    $s = (string)$v;
    // Quote if contains special chars
    if (preg_match('/[:\{\}\[\],&*?#|>%@`!\- ]/', $s) || $s === '') {
        return "'" . str_replace("'", "''", $s) . "'";
    }
    return $s;
}

// ============================================================
// === CONFIG MERGE
// ============================================================

/**
 * Three-layer config merge: base + override + profile → config.yaml
 *
 * Merge order:
 *   1. Start with base
 *   2. Apply override positional keys (prepend/append)
 *   3. Merge profile's proxies/proxy-groups/rules
 *   4. Deep-merge override's remaining top-level keys
 */
function mergeAll($base, $override, $profile) {
    $result = $base;

    // Extract override positional keys
    $prependRules = $override['prepend-rules'] ?? [];
    $appendRules = $override['append-rules'] ?? [];
    $appendProxies = $override['append-proxies'] ?? [];
    $prependProxyGroups = $override['prepend-proxy-groups'] ?? [];
    $appendProxyGroups = $override['append-proxy-groups'] ?? [];

    // Remove positional keys so they don't get deep-merged later
    $overrideRest = $override;
    unset($overrideRest['prepend-rules'], $overrideRest['append-rules'],
          $overrideRest['append-proxies'], $overrideRest['prepend-proxy-groups'],
          $overrideRest['append-proxy-groups']);

    // Build proxies: profile proxies + override append-proxies
    $result['proxies'] = array_merge(
        $profile['proxies'] ?? [],
        $appendProxies
    );

    // Build rules: prepend + profile rules + append
    $result['rules'] = array_merge(
        $prependRules,
        $profile['rules'] ?? [],
        $appendRules
    );

    // Build proxy-groups: prepend + profile proxy-groups + append
    // Handle name conflicts: override proxies list APPENDS to profile's
    $profileGroups = $profile['proxy-groups'] ?? [];
    $mergedGroups = [];

    // First add prepend groups
    foreach ($prependProxyGroups as $g) {
        $mergedGroups[] = $g;
    }

    // Then profile groups (with override conflict resolution)
    foreach ($profileGroups as $pg) {
        $name = $pg['name'] ?? '';
        // Check if override has append-proxy-groups with same name
        if ($name) {
            foreach ($appendProxyGroups as $ag) {
                if (($ag['name'] ?? '') === $name) {
                    // Append override proxies to profile's list
                    if (isset($ag['proxies']) && is_array($ag['proxies'])) {
                        $pg['proxies'] = array_merge($pg['proxies'] ?? [], $ag['proxies']);
                    }
                    // Remove from append list
                    $appendProxyGroups = array_filter($appendProxyGroups, fn($g) => ($g['name'] ?? '') !== $name);
                }
            }
        }
        $mergedGroups[] = $pg;
    }

    // Then remaining append groups
    foreach ($appendProxyGroups as $g) {
        $mergedGroups[] = $g;
    }

    $result['proxy-groups'] = $mergedGroups;

    // Deep-merge remaining override keys into result
    foreach ($overrideRest as $key => $value) {
        if (!isset($result[$key])) {
            $result[$key] = $value;
        } elseif (is_array($result[$key]) && is_array($value)) {
            // Deep merge for mappings, replace for lists
            if (mihomoYamlIsList($result[$key]) && mihomoYamlIsList($value)) {
                $result[$key] = $value; // List: override replaces
            } else {
                $result[$key] = array_merge($result[$key], $value);
            }
        } else {
            $result[$key] = $value;
        }
    }

    return $result;
}

// ============================================================
// === PROFILE MANAGEMENT
// ============================================================

function readProfiles() {
    $profiles = [];
    $dir = MIHOMO_PROFILES_DIR;

    if (!is_dir($dir)) return $profiles;

    $files = glob($dir . '/*.yaml');
    foreach ($files as $f) {
        $name = basename($f, '.yaml');
        $metaFile = $dir . '/' . $name . '.meta.json';
        $meta = [];

        if (file_exists($metaFile)) {
            $meta = json_decode(file_get_contents($metaFile), true) ?: [];
        }

        $profiles[$name] = [
            'name' => $name,
            'file' => $f,
            'meta_file' => $metaFile,
            'source_type' => $meta['source_type'] ?? 'manual',
            'sub_id' => $meta['sub_id'] ?? null,
            'source_url' => $meta['source_url'] ?? null,
            'last_update' => $meta['last_update'] ?? null,
            'node_count' => $meta['node_count'] ?? null,
        ];
    }

    ksort($profiles);
    return $profiles;
}

function readActiveProfile() {
    if (!file_exists(MIHOMO_ACTIVE_JSON)) return null;
    $data = json_decode(file_get_contents(MIHOMO_ACTIVE_JSON), true);
    return $data['profile'] ?? null;
}

function activateProfile($name) {
    $profiles = readProfiles();
    if (!isset($profiles[$name])) {
        return [false, sprintf(gettext('Profile "%s" not found.'), $name)];
    }

    // Read source files
    $base = file_exists(MIHOMO_BASE_YAML)
        ? mihomoYamlParse(file_get_contents(MIHOMO_BASE_YAML))
        : [];
    $override = file_exists(MIHOMO_OVERRIDE_YAML)
        ? mihomoYamlParse(file_get_contents(MIHOMO_OVERRIDE_YAML))
        : [];
    $profileData = file_exists($profiles[$name]['file'])
        ? mihomoYamlParse(file_get_contents($profiles[$name]['file']))
        : [];

    // Merge
    $merged = mergeAll($base, $override, $profileData);

    // Write active.json
    try {
        lockedWrite(MIHOMO_ACTIVE_JSON, json_encode(['profile' => $name], JSON_PRETTY_PRINT));
    } catch (RuntimeException $e) {
        return [false, gettext('Failed to write active profile:') . ' ' . $e->getMessage()];
    }

    // Atomic config update
    $yaml = mihomoYamlDump($merged);
    return atomicConfigUpdate($yaml);
}

// ============================================================
// === SUBSCRIPTION MANAGEMENT
// ============================================================

function readSubs() {
    if (!file_exists(MIHOMO_SUBS_JSON)) return [];
    $data = json_decode(file_get_contents(MIHOMO_SUBS_JSON), true);
    return is_array($data) ? $data : [];
}

function writeSubs($data) {
    try {
        lockedWrite(MIHOMO_SUBS_JSON, json_encode($data, JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE));
        return [true, ''];
    } catch (RuntimeException $e) {
        return [false, $e->getMessage()];
    }
}

function getSubById($id) {
    $subs = readSubs();
    foreach ($subs as $sub) {
        if (($sub['id'] ?? '') === $id) return $sub;
    }
    return null;
}

function updateSubStatus($id, $status, $errorMsg = '') {
    $subs = readSubs();
    foreach ($subs as &$sub) {
        if (($sub['id'] ?? '') === $id) {
            $sub['last_status'] = $status;
            $sub['last_update'] = date('Y-m-d H:i:s');
            if ($errorMsg) $sub['last_error'] = $errorMsg;
            break;
        }
    }
    return writeSubs($subs);
}

// ============================================================
// === BACKUP HELPERS
// ============================================================

function createBackup($label = 'auto') {
    if (!is_dir(MIHOMO_BACKUPS_DIR)) {
        @mkdir(MIHOMO_BACKUPS_DIR, 0750, true);
    }

    $hostname = trim(shell_exec('hostname -s') ?: 'opnsense');
    $ts = date('Ymd_His');
    $filename = "mihomo-backup-{$hostname}-{$ts}.tar.gz";
    $filepath = MIHOMO_BACKUPS_DIR . '/' . $filename;

    $files = [];
    foreach ([MIHOMO_BASE_YAML, MIHOMO_OVERRIDE_YAML, MIHOMO_SUBS_JSON, MIHOMO_ACTIVE_JSON] as $f) {
        if (file_exists($f)) $files[] = escapeshellarg(basename($f));
    }
    if (is_dir(MIHOMO_PROFILES_DIR)) {
        $files[] = 'profiles';
    }

    if (empty($files)) return false;

    $fileList = implode(' ', $files);
    list(, $rc) = mihomoExecCommand(
        "tar -czf " . escapeshellarg($filepath) .
        " -C " . escapeshellarg(MIHOMO_DIR) . " $fileList"
    );

    if ($rc !== 0) return false;

    // Purge old backups (keep 10)
    $backups = listBackups();
    if (count($backups) > 10) {
        $toDelete = array_slice($backups, 10);
        foreach ($toDelete as $b) {
            @unlink(MIHOMO_BACKUPS_DIR . '/' . $b);
        }
    }

    return $filepath;
}

function listBackups() {
    if (!is_dir(MIHOMO_BACKUPS_DIR)) return [];
    $files = glob(MIHOMO_BACKUPS_DIR . '/mihomo-backup-*.tar.gz');
    $result = [];
    foreach ($files as $f) {
        $name = basename($f);
        $result[] = [
            'filename' => $name,
            'size' => filesize($f),
            'mtime' => filemtime($f),
        ];
    }
    usort($result, fn($a, $b) => $b['mtime'] <=> $a['mtime']);
    return $result;
}

function restoreBackup($filename) {
    $filepath = MIHOMO_BACKUPS_DIR . '/' . basename($filename);
    if (!file_exists($filepath)) {
        return [false, gettext('Backup file not found.')];
    }

    // Create fallback backup before restore
    createBackup('pre-restore');

    list(, $rc) = mihomoExecCommand(
        "tar -xzf " . escapeshellarg($filepath) .
        " -C " . escapeshellarg(MIHOMO_DIR)
    );

    if ($rc !== 0) {
        return [false, gettext('Failed to extract backup.')];
    }

    // Validate merged result
    $base = file_exists(MIHOMO_BASE_YAML) ? mihomoYamlParse(file_get_contents(MIHOMO_BASE_YAML)) : [];
    $override = file_exists(MIHOMO_OVERRIDE_YAML) ? mihomoYamlParse(file_get_contents(MIHOMO_OVERRIDE_YAML)) : [];
    $activeName = readActiveProfile();
    $profile = [];
    if ($activeName) {
        $pf = MIHOMO_PROFILES_DIR . '/' . $activeName . '.yaml';
        if (file_exists($pf)) $profile = mihomoYamlParse(file_get_contents($pf));
    }
    $merged = mergeAll($base, $override, $profile);
    $yaml = mihomoYamlDump($merged);

    return atomicConfigUpdate($yaml);
}

// ============================================================
// === MIGRATION CHECK
// ============================================================

function isMigrated() {
    return file_exists(MIHOMO_MIGRATED_FLAG);
}

function getMigrationError() {
    if (!file_exists(MIHOMO_MIGRATE_ERROR)) return null;
    return file_get_contents(MIHOMO_MIGRATE_ERROR);
}

// ============================================================
// === FORM HELPERS
// ============================================================

/**
 * Read OPNsense physical interfaces for dropdown population.
 */
function getNetworkInterfaces() {
    $ifconfig = trim(shell_exec('ifconfig -l 2>/dev/null') ?: '');
    if (empty($ifconfig)) return ['(auto)'];
    $ifs = preg_split('/\s+/', $ifconfig);
    $ifs = array_filter($ifs, fn($i) => $i !== 'lo0' && $i !== 'pflog0' && $i !== 'pfsync0');
    sort($ifs);
    array_unshift($ifs, '(auto)');
    return $ifs;
}

/**
 * Check if port 53 is in use (for DNS listen conflict detection).
 */
function checkPort53Conflict() {
    $sockstat = trim(shell_exec('sockstat -4l 2>/dev/null | grep ":53 " 2>/dev/null') ?: '');
    if (empty($sockstat)) return [];
    $lines = explode("\n", $sockstat);
    $conflicts = [];
    foreach ($lines as $line) {
        if (preg_match('/^\S+\s+(\d+)\s+\S+$/', trim($line), $m)) {
            $conflicts[] = $m[1];
        }
    }
    return $conflicts;
}

// ============================================================
// === GITHUB API HELPERS
// ============================================================

/**
 * Fetch latest GitHub release with 1h cache and optional token.
 *
 * @return array|null Release data or null on failure.
 */
function fetchLatestRelease($repo, $token = '', $mirror = '') {
    $cacheFile = MIHOMO_RELEASE_CACHE;
    $cacheKey = md5($repo);

    // Check cache
    if (file_exists($cacheFile)) {
        $cache = json_decode(file_get_contents($cacheFile), true);
        if ($cache && isset($cache[$cacheKey]) && (time() - $cache[$cacheKey]['ts']) < 3600) {
            return $cache[$cacheKey]['data'];
        }
    }

    $url = $mirror
        ? $mirror . "https://api.github.com/repos/$repo/releases/latest"
        : "https://api.github.com/repos/$repo/releases/latest";

    $ctxOpts = [
        'http' => [
            'method' => 'GET',
            'header' => "User-Agent: Mihomo-OPNsense\r\nAccept: application/vnd.github+json\r\n",
            'timeout' => 10,
            'ignore_errors' => true,
        ],
    ];

    if ($token) {
        $ctxOpts['http']['header'] .= "Authorization: Bearer $token\r\n";
    }

    $ctx = stream_context_create($ctxOpts);
    $result = @file_get_contents($url, false, $ctx);

    if ($result === false) return null;

    $data = json_decode($result, true);
    if (!$data || isset($data['message'])) return null;

    // Update cache
    $cache = file_exists($cacheFile) ? json_decode(file_get_contents($cacheFile), true) : [];
    if (!$cache) $cache = [];
    $cache[$cacheKey] = ['ts' => time(), 'data' => $data];
    file_put_contents($cacheFile, json_encode($cache, JSON_PRETTY_PRINT), LOCK_EX);

    return $data;
}
