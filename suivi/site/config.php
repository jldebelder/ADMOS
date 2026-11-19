<?php
// Serveur de suivi des labos — EAFC Uccle. Configuration (aucun secret ici : le mot de passe
// est dans /var/lib/suivi/acces.php, créé par install-suivi.sh).
return [
    'titre'   => 'Suivi des labos',
    'donnees' => '/var/lib/suivi',            // classe.csv, résultats, clé SSH de relève (hors du site web)
    'labos'   => [
        '01' => 'Base Proxmox', '02' => 'Routage et NAT', '03' => 'DHCP',
        '04' => 'SSH, Apache, iptables, fail2ban', '05' => 'SMTP', '06' => 'FTP',
        '07' => 'NFS', '08' => 'CUPS', '09' => 'OpenVPN', '10' => 'DNS',
    ],
    // Qui peut ENVOYER un résultat (recevoir.php) : les routeurs des étudiants, côté WAN.
    'reseaux_envoi'  => ['172.17.0.0/16', '127.0.0.0/8'],
    'envoi_delai'    => 5,           // secondes minimum entre deux envois d'une même adresse
    'envoi_max'      => 1048576,     // taille maximum d'un envoi (octets)
    // Relève par l'enseignant (releve.php) : compte et adresses chez l'étudiant.
    'ssh_user'       => 'prof',
    'ip_pc'          => '10.68.69.10',   // le PC, joint À TRAVERS le routeur de l'étudiant
    'releve_timeout' => 90,              // secondes maximum par machine
    'historique'     => 40,              // nombre de résultats affichés par étudiant
];
