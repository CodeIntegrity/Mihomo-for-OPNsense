<?php

/**
 * /api/mihomo/profiles/* — Profiles tab + Dashboard helpers.
 *
 * profiles live in /usr/local/etc/mihomo/profiles/ as a (name.yaml, name.meta.json)
 * pair. Activation flips the state.active_profile pointer in OPNsense
 * config.xml so reconfigure.py picks the right file on the next render.
 */

namespace OPNsense\Mihomo\Api;

use OPNsense\Base\ApiControllerBase;
use OPNsense\Core\Config;

class ProfilesController extends ApiControllerBase
{
    use MihomoFileTrait;

    /** GET /api/mihomo/profiles/searchItem — bootgrid feed. */
    public function searchItemAction()
    {
        $rows = $this->readProfiles();
        return [
            'rowCount' => count($rows),
            'total'    => count($rows),
            'current'  => 1,
            'rows'     => $rows,
        ];
    }

    /** GET /api/mihomo/profiles/active — Dashboard widget data. */
    public function activeAction()
    {
        $active = $this->getActiveProfileName();
        $meta = [
            'name'        => $active,
            'source_type' => 'manual',
            'source_url'  => '',
            'sub_id'      => '',
            'last_update' => '',
            'last_status' => 'idle',
            'node_count'  => 0,
        ];
        $metaFile = $this->mihomoPath('profiles/' . $active . '.meta.json');
        if (is_file($metaFile)) {
            $loaded = json_decode((string)@file_get_contents($metaFile), true) ?: [];
            $meta = array_merge($meta, $loaded);
            $meta['name'] = $active;
        }
        // last_status: prefer meta.json (written by sub.sh), fall back to config.xml.
        if (empty($meta['last_status']) && !empty($meta['sub_id'])) {
            $sub = $this->findSubscription($meta['sub_id']);
            if ($sub !== null) {
                $meta['last_status'] = (string)($sub['last_status'] ?? 'idle');
            }
        }
        return $meta;
    }

    /** GET /api/mihomo/profiles/viewYaml/<name> — modal display. */
    public function viewYamlAction($name = '')
    {
        $name = $this->safeName($name);
        if ($name === '') {
            return ['status' => 'failed', 'message' => 'invalid name'];
        }
        $path = $this->mihomoPath('profiles/' . $name . '.yaml');
        if (!is_file($path)) {
            return ['status' => 'failed', 'message' => 'profile not found'];
        }
        return ['status' => 'ok', 'content' => $this->readFileBounded($path)];
    }

    /**
     * POST /api/mihomo/profiles/activate/<name>
     * Flip active_profile + trigger reconfigure.
     */
    public function activateAction($name = '')
    {
        if (!$this->request->isPost()) {
            return ['status' => 'failed', 'message' => 'POST required'];
        }
        $name = $this->safeName($name);
        if ($name === '') {
            return ['status' => 'failed', 'message' => 'invalid name'];
        }
        if (!is_file($this->mihomoPath('profiles/' . $name . '.yaml'))) {
            return ['status' => 'failed', 'message' => 'profile not found'];
        }

        $this->backupBefore('activate-' . $name);

        // Write active_profile back to OPNsense config.xml via the model.
        $mihomo = new \OPNsense\Mihomo\Mihomo();
        $mihomo->state->active_profile = $name;
        $errors = $mihomo->performValidation();
        if (count($errors) > 0) {
            $msgs = [];
            foreach ($errors as $e) { $msgs[] = (string)$e->getMessage(); }
            return ['status' => 'failed', 'message' => implode('; ', $msgs)];
        }
        $mihomo->serializeToConfig();
        Config::getInstance()->save();

        $apply = $this->atomicConfigUpdate();
        return [
            'status'  => $apply['success'] ? 'ok' : 'failed',
            'message' => $apply['message'],
        ];
    }

    /**
     * POST /api/mihomo/profiles/refreshActive
     * Trigger sub.sh for the active profile's underlying subscription.
     * Returns immediately; UI polls profiles/active for last_status changes.
     */
    public function refreshActiveAction()
    {
        if (!$this->request->isPost()) {
            return ['status' => 'failed', 'message' => 'POST required'];
        }
        $active = $this->activeAction();
        $subId = (string)($active['sub_id'] ?? '');
        if ($subId === '') {
            return ['status' => 'failed', 'message' => 'active profile has no subscription'];
        }
        try {
            $this->configdRun('sub-refresh', [$subId]);
        } catch (\Exception $e) {
            return ['status' => 'failed', 'message' => $e->getMessage()];
        }
        return ['status' => 'ok'];
    }

    /** POST /api/mihomo/profiles/delete/<name> — current active is protected. */
    public function deleteAction($name = '')
    {
        if (!$this->request->isPost()) {
            return ['status' => 'failed', 'message' => 'POST required'];
        }
        $name = $this->safeName($name);
        if ($name === '') {
            return ['status' => 'failed', 'message' => 'invalid name'];
        }
        if ($name === $this->getActiveProfileName()) {
            return ['status' => 'failed', 'message' => 'cannot delete the active profile'];
        }
        $yaml = $this->mihomoPath('profiles/' . $name . '.yaml');
        $meta = $this->mihomoPath('profiles/' . $name . '.meta.json');
        if (!is_file($yaml)) {
            return ['status' => 'failed', 'message' => 'profile not found'];
        }
        @unlink($yaml);
        @unlink($meta);
        return ['status' => 'ok'];
    }

    /**
     * POST /api/mihomo/profiles/createEmpty
     * Body: { name: "..." }
     * Manual (non-subscription) profile. Name must not start with `sub-`.
     */
    public function createEmptyAction()
    {
        if (!$this->request->isPost()) {
            return ['status' => 'failed', 'message' => 'POST required'];
        }
        $name = $this->safeName((string)$this->request->getPost('name', null, ''));
        if ($name === '') {
            return ['status' => 'failed', 'message' => 'invalid name'];
        }
        if (strpos($name, 'sub-') === 0) {
            return ['status' => 'failed', 'message' => 'name "sub-*" is reserved for subscriptions'];
        }
        $yaml = $this->mihomoPath('profiles/' . $name . '.yaml');
        if (is_file($yaml)) {
            return ['status' => 'failed', 'message' => 'profile already exists'];
        }
        $skeleton = "# Manual profile: {$name}\nproxies: []\nproxy-groups: []\nrules:\n  - MATCH,DIRECT\n";
        try {
            $this->atomicWrite($yaml, $skeleton);
            $this->atomicWrite(
                $this->mihomoPath('profiles/' . $name . '.meta.json'),
                json_encode([
                    'source_type' => 'manual',
                    'sub_id'      => '',
                    'last_update' => gmdate('c'),
                    'node_count'  => 0,
                    'source_url'  => '',
                ], JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT)
            );
        } catch (\Exception $e) {
            return ['status' => 'failed', 'message' => $e->getMessage()];
        }
        return ['status' => 'ok'];
    }

    /**
     * POST /api/mihomo/profiles/setYaml/<name>
     * Body: { content: "..." }
     * Edit a profile (manual or detached subscription).
     * When called on a subscription profile, the source_type is flipped to
     * manual so future refreshes do not overwrite the user's edits.
     */
    public function setYamlAction($name = '')
    {
        if (!$this->request->isPost()) {
            return ['status' => 'failed', 'message' => 'POST required'];
        }
        $name = $this->safeName($name);
        if ($name === '') {
            return ['status' => 'failed', 'message' => 'invalid name'];
        }
        $content = (string)$this->request->getPost('content', null, '');
        if (strlen($content) > 5242880) {
            return ['status' => 'failed', 'message' => 'profile too large (5 MiB cap)'];
        }
        $yaml = $this->mihomoPath('profiles/' . $name . '.yaml');
        if (!is_file($yaml)) {
            return ['status' => 'failed', 'message' => 'profile not found'];
        }
        try {
            $this->lockedWrite($yaml, $content);
            // Detach from subscription if applicable.
            $metaFile = $this->mihomoPath('profiles/' . $name . '.meta.json');
            $meta = is_file($metaFile)
                ? (json_decode((string)@file_get_contents($metaFile), true) ?: [])
                : [];
            if (($meta['source_type'] ?? '') === 'subscription') {
                $meta['source_type'] = 'manual';
                $meta['last_update'] = gmdate('c');
                $this->atomicWrite($metaFile, json_encode($meta, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT));
            }
        } catch (\Exception $e) {
            return ['status' => 'failed', 'message' => $e->getMessage()];
        }

        // Only trigger reconfigure if this is the active profile.
        if ($name === $this->getActiveProfileName()) {
            $apply = $this->atomicConfigUpdate();
            if (!$apply['success']) {
                return ['status' => 'failed', 'message' => $apply['message']];
            }
        }
        return ['status' => 'ok'];
    }

    // ----- internals ---------------------------------------------------

    private function safeName($name)
    {
        $name = trim((string)$name);
        if ($name === '' || strlen($name) > 64) {
            return '';
        }
        if (!preg_match('/^[a-zA-Z0-9_-]+$/', $name)) {
            return '';
        }
        return $name;
    }

    private function findSubscription($subId)
    {
        $cfg = Config::getInstance()->object();
        if (!isset($cfg->OPNsense->Mihomo->mihomo->subscriptions->subscription)) {
            return null;
        }
        foreach ($cfg->OPNsense->Mihomo->mihomo->subscriptions->subscription as $sub) {
            if ((string)$sub->attributes()->uuid === $subId) {
                return [
                    'uuid'        => $subId,
                    'name'        => (string)$sub->name,
                    'last_status' => (string)$sub->last_status,
                    'last_update' => (string)$sub->last_update,
                ];
            }
        }
        return null;
    }

    private function backupBefore($label)
    {
        $cfg = Config::getInstance()->object();
        $on = (string)($cfg->OPNsense->Mihomo->mihomo->update->auto_backup_on_profile_activate ?? '0');
        if ($on === '1') {
            try { $this->createBackup($label); }
            catch (\Exception $e) { error_log('mihomo activate backup failed: ' . $e->getMessage()); }
        }
    }
}
