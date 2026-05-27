<?php

/**
 * /api/mihomo/settings/* — Settings tab CRUD via ApiMutableModelControllerBase.
 *
 * Endpoints (provided by the base class):
 *   GET  settings/get           → current model values
 *   POST settings/set           → write model + trigger reconfigure
 *
 * The `setAction` from the base class only writes to config.xml; we override
 * it to also run `configctl mihomo reconfigure` so the new base.yaml takes
 * effect immediately. Caller can also click the global Apply button which
 * hits /api/mihomo/service/reconfigure — both paths are idempotent.
 */

namespace OPNsense\Mihomo\Api;

use OPNsense\Base\ApiMutableModelControllerBase;

class SettingsController extends ApiMutableModelControllerBase
{
    use MihomoFileTrait;

    protected static $internalModelClass = 'OPNsense\\Mihomo\\Mihomo';
    protected static $internalModelName  = 'mihomo';

    /**
     * GET /api/mihomo/settings/get
     * Surface the model state to the front-end form. Default impl is fine;
     * we add a couple of read-only computed fields (`interface_choices`) so
     * the Volt template can populate the interface dropdown.
     */
    public function getAction()
    {
        $base = parent::getAction();
        if (is_array($base) && isset($base['mihomo'])) {
            // Inject the list of physical interfaces as a sibling so the
            // front-end can hydrate the interface-name dropdown.
            $base['mihomo']['_interface_choices'] = $this->detectInterfaces();
        }
        return $base;
    }

    /**
     * POST /api/mihomo/settings/set
     * After writing the model we trigger reconfigure so base.yaml is
     * regenerated and mihomo reloads.
     */
    public function setAction()
    {
        if (!$this->request->isPost()) {
            return ['status' => 'failed', 'message' => 'POST required'];
        }
        $result = parent::setAction();
        if (is_array($result) && ($result['result'] ?? '') === 'saved') {
            $apply = $this->atomicConfigUpdate();
            $result['reconfigure'] = $apply['success'] ? 'ok' : 'failed';
            if (!$apply['success']) {
                $result['result']  = 'failed';
                $result['message'] = $apply['message'];
            }
        }
        return $result;
    }

    /**
     * Detect physical interfaces from OPNsense config.xml. The user picks
     * one via the Interface dropdown for the mihomo `interface-name` option.
     */
    private function detectInterfaces()
    {
        $choices = [['value' => '', 'label' => '(auto)']];
        try {
            $root = simplexml_load_file('/conf/config.xml');
        } catch (\Exception $e) {
            return $choices;
        }
        if (!$root || !isset($root->interfaces)) {
            return $choices;
        }
        foreach ($root->interfaces->children() as $name => $node) {
            $if = (string)($node->if ?? '');
            $descr = (string)($node->descr ?? $name);
            if ($if === '' || $if === 'tun_3000') {
                continue;
            }
            $choices[] = [
                'value' => $if,
                'label' => $descr . ' (' . $if . ')',
            ];
        }
        return $choices;
    }
}
