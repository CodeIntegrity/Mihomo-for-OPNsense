<?php

/**
 * Default landing for /ui/mihomo/ — 302 redirect to /ui/mihomo/dashboard.
 */

namespace OPNsense\Mihomo;

use OPNsense\Base\IndexController as BaseIndexController;

class IndexController extends BaseIndexController
{
    public function indexAction()
    {
        $this->response->redirect('/ui/mihomo/dashboard');
    }
}
