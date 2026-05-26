<?php
/**
 * Mihomo log viewer endpoint.
 *
 * Query params:
 *   ?lines=N   — return last N lines (default 200, max 5000)
 *   ?level=X   — filter by log level (error/warning/info/debug)
 *   ?offset=N  — start from line N
 */
require_once __DIR__ . '/includes/mihomo_lib.inc.php';

$logFile = MIHOMO_LOG;
$maxLines = 5000;
$displayLines = min((int)($_GET['lines'] ?? 200), $maxLines);
$levelFilter = $_GET['level'] ?? '';
$offset = (int)($_GET['offset'] ?? 0);

// Handle clear action via POST
if ($_SERVER['REQUEST_METHOD'] === 'POST' && ($_GET['action'] ?? '') === 'clear') {
    if (file_exists($logFile) && is_writable($logFile)) {
        file_put_contents($logFile, '', LOCK_EX);
    }
    header('Content-Type: text/plain; charset=utf-8');
    echo '';
    exit;
}

header('Content-Type: text/plain; charset=utf-8');
header('Cache-Control: no-store');

if (!file_exists($logFile)) {
    echo gettext('Log file not found.');
    exit;
}

$log = new SplFileObject($logFile, 'r');
$log->seek(PHP_INT_MAX);
$totalLines = $log->key();

$log->rewind();
$startLine = max(0, $totalLines - $maxLines);
$log->seek($startLine);

$lines = [];
while (!$log->eof()) {
    $line = trim($log->fgets());
    if ($line === '') continue;
    $lines[] = $line;
}

// Trim old lines if too many
if ($totalLines > $maxLines) {
    file_put_contents($logFile, implode("\n", $lines) . "\n");
}

// Apply level filter (simple string match)
if ($levelFilter && in_array($levelFilter, ['error', 'warning', 'info', 'debug'])) {
    $upperLevel = strtoupper($levelFilter);
    $lines = array_filter($lines, function($l) use ($upperLevel) {
        return stripos($l, $upperLevel) !== false || stripos($l, 'level=' . $upperLevel) !== false;
    });
    $lines = array_values($lines);
}

// Apply offset
if ($offset > 0) {
    $lines = array_slice($lines, $offset);
}

// Return last N lines
$lines = array_slice($lines, -$displayLines);
echo implode("\n", $lines);
