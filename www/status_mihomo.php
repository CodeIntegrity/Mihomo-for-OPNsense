<?php
/**
 * Mihomo service status endpoint.
 *
 * Returns JSON: {status, pid, uptime}
 */
require_once __DIR__ . '/includes/mihomo_lib.inc.php';

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');

try {
    $status = getMihomoStatus();
    echo json_encode($status);
} catch (Exception $e) {
    echo json_encode([
        'status' => 'stopped',
        'pid' => null,
        'uptime' => null,
        'error' => $e->getMessage(),
    ]);
}
