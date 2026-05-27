<?php

/**
 * Mihomo for OPNsense — Model.
 *
 * Persists Mihomo Settings (Group A-F) and Subscription list to OPNsense
 * config.xml. Rendering of base.yaml from this model is performed by
 * `scripts/mihomo/reconfigure.py` (configd action `reconfigure`).
 */

namespace OPNsense\Mihomo;

use OPNsense\Base\BaseModel;

class Mihomo extends BaseModel
{
    protected $internalDomain = 'mihomo';
}
