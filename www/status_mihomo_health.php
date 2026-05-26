<?php
/**
 * Async Health Check progress endpoint.
 *
 * Query: ?uuid=<uuid>
 * Returns JSON: {state, progress: {done, total}, result: {alive, dead, dead_list}}
 */
header('Content-Type: application/json; charset=utf-8');
header('Cache-Control: no-store');

$uuid = isset($_GET['uuid']) ? preg_replace('/[^a-zA-Z0-9_-]/', '', $_GET['uuid']) : '';

if (empty($uuid)) {
    echo json_encode(['state' => 'failed', 'error' => 'Missing uuid parameter']);
    exit;
}

$stateFile = "/tmp/mihomo-health-{$uuid}.json";

if (!file_exists($stateFile)) {
    echo json_encode(['state' => 'running', 'progress' => ['done' => 0, 'total' => 0]]);
    exit;
}

$data = json_decode(file_get_contents($stateFile), true);

if (!$data) {
    echo json_encode(['state' => 'failed', 'error' => 'Cannot read health check state']);
    exit;
}

echo json_encode($data);
