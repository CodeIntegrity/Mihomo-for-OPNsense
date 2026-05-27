<?php

/*
 * Copyright (C) 2024  https://pfchina.org/
 * All rights reserved.
 *
 */

function mihomo_services()
{
    global $config;

    // Bind the mihomo gettext domain so translations under
    // /usr/local/share/locale/zh_CN/LC_MESSAGES/mihomo.mo are found.
    bindtextdomain('mihomo', '/usr/local/share/locale');

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
