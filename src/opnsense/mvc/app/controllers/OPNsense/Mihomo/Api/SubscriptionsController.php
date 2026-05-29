<?php

/**
 * /api/mihomo/subscriptions/* — Subscriptions tab CRUD + refresh + log.
 *
 * CRUD is provided by ApiMutableModelControllerBase against the model's
 * `subscriptions.subscription` ArrayField. Two extra actions:
 *
 *  - refreshAction(uuid)  — kick sub.sh via configd in background.
 *  - logAction()          — tail /var/log/mihomo_sub.log.
 */

namespace OPNsense\Mihomo\Api;

use OPNsense\Base\ApiMutableModelControllerBase;

class SubscriptionsController extends ApiMutableModelControllerBase
{
    use MihomoFileTrait;

    protected static $internalModelClass = 'OPNsense\\Mihomo\\Mihomo';
    protected static $internalModelName  = 'mihomo';

    public function searchItemAction()
    {
        return $this->searchBase('subscriptions.subscription', null, 'name');
    }

    public function getItemAction($uuid = null)
    {
        return $this->getBase('subscription', 'subscriptions.subscription', $uuid);
    }

    public function setItemAction($uuid = null)
    {
        return $this->setBase('subscription', 'subscriptions.subscription', $uuid);
    }

    public function addItemAction()
    {
        return $this->addBase('subscription', 'subscriptions.subscription');
    }

    public function delItemAction($uuid = null)
    {
        return $this->delBase('subscriptions.subscription', $uuid);
    }

    public function toggleItemAction($uuid = null, $enabled = null)
    {
        return $this->toggleBase('subscriptions.subscription', $uuid, $enabled);
    }

    /**
     * POST /api/mihomo/subscriptions/refresh/<uuid>
     * Kick sub.sh in background and activate the resulting profile (arg2=1).
     * UI polls last_status via searchItem to track.
     */
    public function refreshAction($uuid = null)
    {
        if (!$this->request->isPost()) {
            return ['status' => 'failed', 'message' => 'POST required'];
        }
        if (!preg_match('/^[0-9a-f-]{36}$/', (string)$uuid)) {
            return ['status' => 'failed', 'message' => 'invalid uuid'];
        }
        try {
            $this->configdRun('sub-refresh', [$uuid, '1']);
        } catch (\Exception $e) {
            return ['status' => 'failed', 'message' => $e->getMessage()];
        }
        return ['status' => 'ok'];
    }

    /** GET /api/mihomo/subscriptions/log?lines=N */
    public function logAction()
    {
        $lines = max(1, min(2000, (int)$this->request->get('lines', null, 200)));
        return ['logs' => $this->tailLines(self::$MIHOMO_SUB_LOG, $lines)];
    }
}
