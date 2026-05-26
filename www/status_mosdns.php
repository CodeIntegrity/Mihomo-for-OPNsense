<?php
// status_mosdns.php
header('Content-Type: application/json');

// 通过 OPNsense configd action 检查服务状态，和页面控制逻辑保持一致。
exec("/usr/local/sbin/configctl mosdns status 2>&1", $output, $return_var);
$status_output = implode("\n", $output);

if (stripos($status_output, 'is running') !== false) {
    echo json_encode(['status' => 'running']);
} else {
    echo json_encode(['status' => 'stopped']);
}
?>
