<?php
// Configuration du site de contrôle — EAFC Uccle.
// Chaque cible : un nom affiché, et la liste des adresses à essayer (la première est l'adresse prévue).
return [
    'titre' => 'Contrôle du labo',
    'cibles' => [
        ['id' => 'routeur', 'nom' => 'Routeur', 'hotes' => ['10.68.69.1']],
        ['id' => 'pc',      'nom' => 'PC',      'hotes' => ['10.68.69.10', '127.0.0.1']],
    ],
    'ssh_user'    => 'prof',
    'ssh_key'     => '/var/lib/verif/id_ed25519',   // créée par install-prof.sh, lisible par www-data seulement
    'known_hosts' => '/var/lib/verif/known_hosts',
    'etat'        => '/var/lib/verif',              // dossier où le site écrit le dernier résultat
    'delai_min'   => 8,                              // secondes minimum entre deux vérifications
    'timeout'     => 40,                             // secondes maximum par machine
    // Le site n'est consultable que depuis le LAN du labo (et la machine elle-même).
    'reseaux_autorises' => ['10.68.69.0/24', '127.0.0.0/8'],
];
