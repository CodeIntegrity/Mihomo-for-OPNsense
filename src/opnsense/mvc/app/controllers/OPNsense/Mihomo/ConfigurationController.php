<?php

/**
 * Configuration page — renders all 8 Tabs into a single Volt view.
 *
 * Forms XML loaded here are referenced by configuration.volt via
 * base_form / base_dialog / base_bootgrid_table partials.
 */

namespace OPNsense\Mihomo;

use OPNsense\Base\IndexController as BaseIndexController;

class ConfigurationController extends BaseIndexController
{
    public function indexAction()
    {
        // Settings Tab — 6 forms (Group A-F).
        $this->view->formGeneral    = $this->getForm('general');
        $this->view->formController = $this->getForm('controller');
        $this->view->formTun        = $this->getForm('tun');
        $this->view->formDns        = $this->getForm('dns');
        $this->view->formSniffer    = $this->getForm('sniffer');
        $this->view->formUpdate     = $this->getForm('update');

        // Subscriptions Tab — bootgrid + dialog.
        $this->view->formDialogSubscription = $this->getForm('dialogSubscription');

        $this->view->pick('OPNsense/Mihomo/configuration');
    }
}
