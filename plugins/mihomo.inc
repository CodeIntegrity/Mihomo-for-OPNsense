<?php

/*
 * Copyright (C) 2024  https://pfchina.org/
 * All rights reserved.
 *
 */

// Register the mihomo gettext domain so translations under
// /usr/local/share/locale/zh_CN/LC_MESSAGES/mihomo.mo are found.
// Must be at file scope — the OPNsense bootstrap loads this file on every
// request, and dgettext('mihomo', ...) needs this path registered beforehand.
bindtextdomain('mihomo', '/usr/local/share/locale');
bind_textdomain_codeset('mihomo', 'UTF-8');

function mihomo_services()
{
    global $config;

    $services = array();

        $services[] = array(
            'description' => gettext('mihomo'),
            'configd' => array(
                'restart' => array('mihomo restart'),
                'start' => array('mihomo start'),
                'stop' => array('mihomo stop'),
            ),
            'name' => 'mihomo',
            'pidfile' => '/var/run/mihomo.pid',
        );
    

    return $services;
}

function mihomo_configure()
{
    return [
        'newwanip' => ['mihomo_restart'],
    ];
}

function mihomo_syslog()
{
    $logfacilities = array();
    $logfacilities['mihomo'] = array(
        'facility' => array('mihomo'),
    );
    return $logfacilities;
}


function mihomo_restart()
{
    exec('/usr/local/sbin/configctl mihomo restart');
}
