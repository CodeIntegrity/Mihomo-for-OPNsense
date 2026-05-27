<?php

/**
 * Dashboard page controller.
 *
 * Renders dashboard.volt. Reads the current Settings model so the Volt
 * template can compute the "Open Dashboard UI" link without an extra
 * roundtrip. All realtime data is fetched client-side from /api/mihomo/...
 */

namespace OPNsense\Mihomo;

use OPNsense\Base\IndexController as BaseIndexController;
use OPNsense\Core\Config;

class DashboardController extends BaseIndexController
{
    public function indexAction()
    {
        $cfg = Config::getInstance()->object();
        $ec = (string)($cfg->OPNsense->Mihomo->mihomo->controller->external_controller ?? '127.0.0.1:9090');
        $this->view->externalController = $ec;
        $this->view->pick('OPNsense/Mihomo/dashboard');
    }
}
