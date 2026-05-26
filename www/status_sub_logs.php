<?php
/**
 * Subscription log endpoint.
 *
 * Query params:
 *   ?lines=N — return last N lines (default 200)
 */
require_once 'guiconfig.inc';
require_once __DIR__ . '/includes/mihomo_lib.inc.php';

define('SUB_LOG_FILE', '/var/log/mihomo_sub.log');

$displayLines = min((int)($_GET['lines'] ?? 200), 2000);

header('Content-Type: text/plain; charset=utf-8');
header('Cache-Control: no-store');

if (!is_file(SUB_LOG_FILE)) {
    echo dgettext('mihomo', 'Subscription log file does not exist yet.');
    exit;
}

$logLines = @file(SUB_LOG_FILE);
if ($logLines === false) {
    echo dgettext('mihomo', 'Cannot read subscription log file.');
    exit;
}

$logTail = array_slice($logLines, -$displayLines);
echo implode('', $logTail);
