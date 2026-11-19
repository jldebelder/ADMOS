<?php
// Configuration du site de contrôle — EAFC Uccle.
// Chaque cible : un nom affiché, et la liste des adresses à essayer (la première est l'adresse prévue).
return [
    'titre' => 'Contrôle du labo',
    'cibles' => [
        ['id' => 'routeur', 'nom' => 'Routeur', 'hotes' => ['10.68.69.1']],
        ['id' => 'pc',      'nom' => 'PC',      'hotes' => ['10.68.69.10', '127.0.0.1']],
    ],
    // Les labos que l'étudiant peut choisir, et les machines concernées par chacun.
    'labos' => [
        '01' => ['titre' => 'Base Proxmox',                     'machines' => ['routeur', 'pc']],
        '02' => ['titre' => 'Routage et NAT',                   'machines' => ['routeur', 'pc']],
        '03' => ['titre' => 'DHCP',                             'machines' => ['routeur', 'pc']],
        '04' => ['titre' => 'SSH, Apache, iptables, fail2ban',  'machines' => ['pc']],
        '05' => ['titre' => 'SMTP et la fonction mail',         'machines' => ['pc']],
        '06' => ['titre' => 'FTP',                              'machines' => ['pc', 'routeur']],
        '07' => ['titre' => 'NFS serveur et client',            'machines' => ['pc', 'routeur']],
        '08' => ['titre' => 'CUPS',                             'machines' => ['pc', 'routeur']],
        '09' => ['titre' => 'OpenVPN',                          'machines' => ['pc', 'routeur']],
        '10' => ['titre' => 'DNS',                              'machines' => ['pc', 'routeur']],
    ],
    'ssh_user'    => 'prof',
    'ssh_key'     => '/var/lib/verif/id_ed25519',   // créée par install-prof.sh, lisible par www-data seulement
    'known_hosts' => '/var/lib/verif/known_hosts',
    'etat'        => '/var/lib/verif',              // dossier où le site écrit le dernier résultat
    'delai_min'   => 8,                              // secondes minimum entre deux vérifications
    'timeout'     => 60,                             // secondes maximum par machine
    // Le site n'est consultable que depuis le LAN du labo (et la machine elle-même).
    'reseaux_autorises' => ['10.68.69.0/24', '127.0.0.0/8'],

    // Suivi par l'enseignant : chaque vérification est envoyée à ce serveur (vide = pas d'envoi).
    // Le serveur reconnaît l'étudiant à l'adresse WAN de son routeur (NAT), pas à ce qu'envoie le PC.
    'suivi_url'     => 'http://172.17.0.250/suivi/recevoir.php',
    'suivi_timeout' => 4,
];
