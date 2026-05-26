<?php
/**
 * Traffic / memory / connection metrics with backend diff-rate calculation.
 *
 * Returns JSON: {upRate, downRate, upTotal, downTotal, memory, connections, connectionTotal}
 * Rate unit: bytes/sec.
 */
require_once __DIR__ . '/includes/mihomo_lib.inc.php';

header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');

$stateFile = MIHOMO_TRAFFIC_STATE;
$now = microtime(true);

// default
$result = [
    'upRate' => 0,
    'downRate' => 0,
    'upTotal' => 0,
    'downTotal' => 0,
    'memory' => 0,
    'connections' => 0,
    'connectionTotal' => 0,
];

try {
    // Fetch traffic data
    $traffic = mihomoApiCall('/traffic');
    $memory = mihomoApiCall('/memory');
    $conns = mihomoApiCall('/connections');

    $upTotal = 0;
    $downTotal = 0;

    if ($traffic[0]) {
        $t = $traffic[1];
        $upTotal = (int)($t['up'] ?? 0);
        $downTotal = (int)($t['down'] ?? 0);
    }

    $memUsage = 0;
    if ($memory[0]) {
        $m = $memory[1];
        $memUsage = (int)($m['inuse'] ?? 0);
    }

    $connCount = 0;
    $connTotal = 0;
    if ($conns[0]) {
        $c = $conns[1];
        $connCount = (int)($c['connections'] ?? count($c['connections'] ?? []));
        $connTotal = (int)($c['uploadTotal'] ?? 0); // connections uploadTotal = cumulative connections
    }

    $result['upTotal'] = $upTotal;
    $result['downTotal'] = $downTotal;
    $result['memory'] = $memUsage;
    $result['connections'] = $connCount;
    $result['connectionTotal'] = $connTotal;

    // Backend diff rate calculation
    $prev = [];
    if (file_exists($stateFile)) {
        $prev = json_decode(file_get_contents($stateFile), true) ?: [];
    }

    if (!empty($prev) && isset($prev['ts'], $prev['upTotal'], $prev['downTotal'])) {
        $deltaT = $now - $prev['ts'];
        if ($deltaT > 0 && $deltaT < 120) {
            $result['upRate'] = (int)(($upTotal - $prev['upTotal']) / $deltaT);
            $result['downRate'] = (int)(($downTotal - $prev['downTotal']) / $deltaT);
            // Clamp negatives (restart resets counters)
            if ($result['upRate'] < 0) $result['upRate'] = 0;
            if ($result['downRate'] < 0) $result['downRate'] = 0;
        }
    }

    // Persist state
    file_put_contents($stateFile, json_encode([
        'ts' => $now,
        'upTotal' => $upTotal,
        'downTotal' => $downTotal,
    ]), LOCK_EX);

} catch (Exception $e) {
    // Return defaults on error
}

echo json_encode($result);
