<?php
// Relève par l'enseignant : interroge le routeur de chaque étudiant (adresse WAN de classe.csv)
// et, à travers lui, son PC (10.68.69.10), avec la clé SSH du serveur de suivi.
// Ligne de commande uniquement (lancée par le tableau de bord, par cron, ou à la main) :
//
//   php releve.php                       toute la classe, tous les labos
//   php releve.php --labo 05             toute la classe, un seul labo
//   php releve.php --etudiant 3          un seul étudiant (son n° dans classe.csv)
//
// Côté étudiant, la clé ne peut lancer que verif-lab, et sur le routeur elle ne peut ouvrir
// qu'un seul tunnel : vers 10.68.69.10:22 (voir install-prof.sh).
if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }
require __DIR__ . '/commun.php';

$opt = getopt('', ['labo:', 'etudiant:']);
$labo = isset($opt['labo']) ? (string)$opt['labo'] : 'tout';
if ($labo !== 'tout') { $labo = sprintf('%02d', (int)$labo); }
if ($labo !== 'tout' && !isset($CFG['labos'][$labo])) { fwrite(STDERR, "Labo inconnu : $labo\n"); exit(2); }

$cle = chemin($CFG, 'ssh/id_ed25519');
$kh  = chemin($CFG, 'ssh/known_hosts');
if (!is_readable($cle)) { fwrite(STDERR, "Clé de relève introuvable : $cle (install-suivi.sh)\n"); exit(1); }

$verrou = fopen(chemin($CFG, 'releve.lock'), 'c');
if (!$verrou || !flock($verrou, LOCK_EX | LOCK_NB)) { echo "Une relève est déjà en cours.\n"; exit(0); }

$classe = classe($CFG);
if (isset($opt['etudiant'])) { $classe = array_intersect_key($classe, [(string)$opt['etudiant'] => 1]); }
$classe = array_filter($classe, function ($e) { return $e['wan'] !== ''; });
if (!$classe) { echo "Aucun étudiant avec une adresse WAN dans classe.csv.\n"; exit(0); }

$commun = ['-T', '-i', $cle, '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes', '-o', 'ConnectTimeout=8',
           '-o', 'StrictHostKeyChecking=accept-new', '-o', 'UserKnownHostsFile=' . $kh, '-o', 'LogLevel=ERROR'];
$demande = ($labo === 'tout') ? 'verif' : 'verif ' . $labo;
$u = $CFG['ssh_user'];

// Une tâche par machine : toutes en parallèle, pour que la relève de la classe dure moins d'une minute.
$taches = [];
foreach ($classe as $e) {
    $taches[] = ['e' => $e['id'], 'm' => 'routeur', 'nom' => 'Routeur', 'hote' => $e['wan'],
                 'cmd' => array_merge(['ssh'], $commun, [$u . '@' . $e['wan'], $demande])];
    $proxy = 'ssh ' . implode(' ', array_map('escapeshellarg', $commun)) . ' -W %h:%p ' . escapeshellarg($u . '@' . $e['wan']);
    $taches[] = ['e' => $e['id'], 'm' => 'pc', 'nom' => 'PC', 'hote' => $CFG['ip_pc'] . ' via ' . $e['wan'],
                 'cmd' => array_merge(['ssh'], $commun, ['-o', 'HostKeyAlias=pc-' . $e['id'], '-o', 'ProxyCommand=' . $proxy,
                                     $u . '@' . $CFG['ip_pc'], $demande])];
}

$env = ['HOME' => chemin($CFG, 'ssh'), 'PATH' => '/usr/bin:/bin'];
foreach ($taches as $i => &$t) {
    $t['out'] = ''; $t['err'] = ''; $t['fin'] = false;
    $t['p'] = proc_open($t['cmd'], [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $t['pipes'], null, $env);
    if (!is_resource($t['p'])) { $t['fin'] = true; $t['err'] = 'ssh introuvable'; continue; }
    fclose($t['pipes'][0]);
    stream_set_blocking($t['pipes'][1], false);
    stream_set_blocking($t['pipes'][2], false);
}
unset($t);

$limite = time() + (int)$CFG['releve_timeout'];
while (true) {
    $lire = [];
    foreach ($taches as $t) { if (!$t['fin']) { $lire[] = $t['pipes'][1]; $lire[] = $t['pipes'][2]; } }
    if (!$lire) { break; }
    $w = null; $x = null;
    if (@stream_select($lire, $w, $x, 1) > 0) {
        foreach ($taches as &$t) {
            if ($t['fin']) { continue; }
            foreach ([1 => 'out', 2 => 'err'] as $k => $champ) {
                if (in_array($t['pipes'][$k], $lire, true)) {
                    $d = fread($t['pipes'][$k], 8192);
                    if ($d !== false && $d !== '') { $t[$champ] .= $d; }
                }
            }
        }
        unset($t);
    }
    foreach ($taches as &$t) {
        if ($t['fin']) { continue; }
        $st = proc_get_status($t['p']);
        if (!$st['running'] || time() > $limite) {
            if ($st['running']) { proc_terminate($t['p']); $t['err'] .= "\nDélai dépassé"; }
            $t['out'] .= (string)stream_get_contents($t['pipes'][1]);
            $t['err'] .= (string)stream_get_contents($t['pipes'][2]);
            fclose($t['pipes'][1]); fclose($t['pipes'][2]); proc_close($t['p']);
            $t['fin'] = true;
        }
    }
    unset($t);
}

function expliquer($err) {
    if (stripos($err, 'Permission denied') !== false) { return "clé refusée : cle_enseignant.pub absente lors de install-prof.sh (le relancer après git pull)."; }
    if (stripos($err, 'administratively prohibited') !== false || stripos($err, 'open failed') !== false) { return "tunnel vers le PC refusé par le routeur (install-prof.sh à relancer sur le routeur, AllowTcpForwarding ?)."; }
    if (stripos($err, 'IDENTIFICATION HAS CHANGED') !== false || stripos($err, 'Host key verification failed') !== false) { return "empreinte SSH changée (machine recréée) : « Oublier les empreintes » dans le tableau de bord."; }
    if (stripos($err, 'timed out') !== false || stripos($err, 'No route') !== false || stripos($err, 'Délai dépassé') !== false) { return "injoignable (machine éteinte ? adresse WAN de classe.csv ?)."; }
    if (stripos($err, 'refused') !== false) { return "port 22 fermé."; }
    return ($err !== '') ? mb_substr(trim($err), 0, 200) : "aucune réponse du script de contrôle.";
}

// Regroupement par étudiant et enregistrement
$par = [];
foreach ($taches as $t) {
    $m = ['id' => $t['m'], 'nom' => $t['nom'], 'hote' => $t['hote'], 'erreur' => null, 'meta' => [], 'checks' => []];
    if (strpos($t['out'], "CHECK\t") !== false) { list($m['meta'], $m['checks']) = parser($t['out']); }
    else { $m['erreur'] = expliquer($t['err']); }
    $par[$t['e']][] = $m;
}
$n_ok = 0;
foreach ($par as $id => $machines) {
    $run = ['labo' => $labo, 'date' => time(), 'machines' => $machines];
    $nom = enregistrer($CFG, (string)$id, 'releve', $run);
    $e = $classe[$id];
    $etat = [];
    foreach ($machines as $m) { $etat[] = $m['nom'] . ' : ' . ($m['erreur'] === null ? count($m['checks']) . ' contrôles' : $m['erreur']); }
    printf("%-28s %s\n", $e['nom'] . ' ' . $e['prenom'], implode(' | ', $etat));
    if ($nom !== false) { $n_ok++; }
}
echo date('d/m/Y H:i:s') . " — relève terminée : $n_ok étudiant(s) enregistré(s).\n";
flock($verrou, LOCK_UN);
