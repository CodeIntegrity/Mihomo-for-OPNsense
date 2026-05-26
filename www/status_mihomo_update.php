<?php
/**
 * Resource update progress endpoint.
 *
 * Query: ?resource=<core|geoip|ui>
 * Returns JSON: {state, progress, message}
 */
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');

$resource = isset($_GET['resource']) ? preg_replace('/[^a-z]/', '', $_GET['resource']) : '';

if (!in_array($resource, ['core', 'geoip', 'ui'], true)) {
    echo json_encode(['state' => 'failed', 'error' => 'Invalid resource type']);
    exit;
}

$stateFile = "/tmp/mihomo-update-{$resource}.json";

if (!file_exists($stateFile)) {
    echo json_encode(['state' => 'idle', 'progress' => 0, 'message' => '']);
    exit;
}

$data = json_decode(file_get_contents($stateFile), true);

if (!$data) {
    echo json_encode(['state' => 'idle', 'progress' => 0, 'message' => '']);
    exit;
}

echo json_encode($data);
