<?php
// Fonctions communes du serveur de suivi : classe, stockage des résultats, résumé, lecture du rapport TSV.
// Aucune sortie HTML ici.

date_default_timezone_set('Europe/Brussels');
$CFG = require __DIR__ . '/config.php';

function h($s) { return htmlspecialchars((string)$s, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8'); }

function chemin($cfg, $rel) { return rtrim($cfg['donnees'], '/') . '/' . $rel; }

function ip_dans_reseau($ip, $cidr) {
    $parts = explode('/', $cidr, 2);
    $bits = isset($parts[1]) ? (int)$parts[1] : 32;
    $ipl = ip2long($ip);
    $netl = ip2long($parts[0]);
    if ($ipl === false || $netl === false) { return false; }
    $mask = ($bits === 0) ? 0 : ((-1 << (32 - $bits)) & 0xFFFFFFFF);
    return ($ipl & $mask) === ($netl & $mask);
}

// ---- La classe : classe.csv (id;nom;prenom;wan;classe) ---------------------------
function classe($cfg) {
    $f = chemin($cfg, 'classe.csv');
    $out = [];
    if (!is_file($f)) { return $out; }
    foreach (file($f, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $l) {
        $l = trim(preg_replace('/^\xEF\xBB\xBF/', '', $l));
        if ($l === '' || $l[0] === '#') { continue; }
        $c = array_map('trim', str_getcsv($l, ';'));
        if (count($c) < 3 || !preg_match('/^[0-9]+$/', $c[0])) { continue; }   // ignore l'en-tête
        $wan = isset($c[3]) ? preg_replace('#/.*$#', '', $c[3]) : '';
        $out[$c[0]] = ['id' => $c[0], 'nom' => $c[1], 'prenom' => $c[2],
                       'wan' => filter_var($wan, FILTER_VALIDATE_IP) ? $wan : '',
                       'classe' => isset($c[4]) ? $c[4] : ''];
    }
    uasort($out, function ($a, $b) { return strcasecmp($a['nom'] . $a['prenom'], $b['nom'] . $b['prenom']); });
    return $out;
}

// Classes présentes dans classe.csv, avec leur effectif (filtre du tableau de bord).
function classes($classe) {
    $out = [];
    foreach ($classe as $e) {
        $c = trim($e['classe']);
        if ($c !== '') { $out[$c] = ($out[$c] ?? 0) + 1; }
    }
    uksort($out, 'strcasecmp');
    return $out;
}

// Réécrit la ligne d'un étudiant dans classe.csv en conservant commentaires et en-tête.
// Le fichier est remplacé atomiquement : une erreur d'écriture ne perd pas la liste.
function modifier_classe($cfg, $id, $champs) {
    $f = chemin($cfg, 'classe.csv');
    if (!is_file($f)) { return false; }
    $brut = (string)file_get_contents($f);
    if ($brut === '') { return false; }
    $bom = (strncmp($brut, "\xEF\xBB\xBF", 3) === 0) ? "\xEF\xBB\xBF" : '';
    $lignes = preg_split('/\r\n|\n|\r/', $brut);
    if (!is_array($lignes)) { return false; }
    if ($bom !== '' && isset($lignes[0])) { $lignes[0] = substr($lignes[0], 3); }
    while ($lignes && end($lignes) === '') { array_pop($lignes); }
    $id = (string)$id;
    $trouve = false;
    foreach ($lignes as $i => $l) {
        $t = trim(preg_replace('/^\xEF\xBB\xBF/', '', $l));
        if ($t === '' || $t[0] === '#') { continue; }
        $c = array_map('trim', str_getcsv($t, ';'));
        if (count($c) < 3 || !preg_match('/^[0-9]+$/', $c[0]) || $c[0] !== $id) { continue; }
        $lignes[$i] = ligne_csv([$id, $champs['nom'], $champs['prenom'], $champs['wan'], $champs['classe']]);
        $trouve = true;
        break;
    }
    if (!$trouve) { return false; }
    $tmp = @tempnam(dirname($f), '.classe-');
    if ($tmp === false) { return false; }
    if (@file_put_contents($tmp, $bom . implode("\n", $lignes) . "\n") === false) { @unlink($tmp); return false; }
    @chmod($tmp, 0640);
    if (!@rename($tmp, $f)) { @unlink($tmp); return false; }
    return true;
}

function ligne_csv($champs) {
    $f = fopen('php://temp', 'r+');
    fputcsv($f, $champs, ';', '"', '');
    rewind($f);
    return rtrim((string)stream_get_contents($f), "\r\n");
}

function etudiant_par_ip($classe, $ip) {
    foreach ($classe as $e) { if ($e['wan'] !== '' && $e['wan'] === $ip) { return $e['id']; } }
    return null;
}

// ---- Lecture du rapport TSV de verif-lab -----------------------------------------
function parser($out) {
    $meta = [];
    $checks = [];
    foreach (preg_split('/\r?\n/', $out) as $ligne) {
        if ($ligne === '') { continue; }
        $f = explode("\t", $ligne);
        if ($f[0] === 'META' && count($f) >= 3) {
            $meta[$f[1]] = $f[2];
        } elseif ($f[0] === 'CHECK' && count($f) >= 7) {
            $checks[] = ['section' => $f[1], 'id' => $f[2], 'statut' => $f[3], 'libelle' => $f[4],
                         'detail' => $f[5], 'conseil' => $f[6],
                         'labo' => (isset($f[7]) && preg_match('/^\d\d$/', $f[7])) ? $f[7] : '00'];
        }
    }
    return [$meta, $checks];
}

// Nettoie un résultat reçu (envoi du site de l'étudiant) : on ne garde que les champs attendus.
function nettoyer($d) {
    $t = function ($s, $n = 400) { return mb_substr(is_scalar($s) ? (string)$s : '', 0, $n); };
    $res = ['labo' => (isset($d['labo']) && preg_match('/^(tout|\d\d)$/', (string)$d['labo'])) ? $d['labo'] : 'tout',
            'date' => isset($d['date']) ? (int)$d['date'] : 0, 'machines' => []];
    if (!isset($d['machines']) || !is_array($d['machines'])) { return null; }
    foreach (array_slice($d['machines'], 0, 4) as $m) {
        if (!is_array($m)) { continue; }
        $mm = ['id' => $t(isset($m['id']) ? $m['id'] : '', 20), 'nom' => $t(isset($m['nom']) ? $m['nom'] : '', 40),
               'hote' => $t(isset($m['hote']) ? $m['hote'] : '', 40), 'erreur' => isset($m['erreur']) ? $t($m['erreur']) : null,
               'meta' => [], 'checks' => []];
        if (isset($m['meta']) && is_array($m['meta'])) {
            foreach (array_slice($m['meta'], 0, 30, true) as $k => $v) { $mm['meta'][$t($k, 30)] = $t($v); }
        }
        if (isset($m['checks']) && is_array($m['checks'])) {
            foreach (array_slice($m['checks'], 0, 400) as $c) {
                if (!is_array($c) || !isset($c['statut']) || !in_array($c['statut'], ['OK', 'KO', 'WARN', 'INFO'], true)) { continue; }
                $mm['checks'][] = ['section' => $t(isset($c['section']) ? $c['section'] : '', 80), 'id' => $t(isset($c['id']) ? $c['id'] : '', 60),
                    'statut' => $c['statut'], 'libelle' => $t(isset($c['libelle']) ? $c['libelle'] : ''), 'detail' => $t(isset($c['detail']) ? $c['detail'] : ''),
                    'conseil' => $t(isset($c['conseil']) ? $c['conseil'] : ''),
                    'labo' => (isset($c['labo']) && preg_match('/^\d\d$/', (string)$c['labo'])) ? $c['labo'] : '00'];
            }
        }
        $res['machines'][] = $mm;
    }
    return $res;
}

// ---- Scores ----------------------------------------------------------------------
function bilan($checks) {
    $b = ['OK' => 0, 'KO' => 0, 'WARN' => 0, 'INFO' => 0];
    foreach ($checks as $c) { if (isset($b[$c['statut']])) { $b[$c['statut']]++; } }
    $b['total'] = $b['OK'] + $b['KO'] + $b['WARN'];
    $b['score'] = ($b['total'] > 0) ? (int)round(100 * $b['OK'] / $b['total']) : null;
    return $b;
}

function checks_par_labo($run) {
    $g = [];
    foreach ($run['machines'] as $m) {
        foreach ($m['checks'] as $c) { if ($c['labo'] !== '00') { $g[$c['labo']][] = $c; } }
    }
    ksort($g);
    return $g;
}

function classe_score($s) {
    if ($s === null) { return 'vide'; }
    return ($s >= 90) ? 'bon' : (($s >= 60) ? 'moyen' : 'faible');
}

// ---- Stockage : un fichier JSON par résultat + un résumé (resume.json) ------------
// Le résumé est mis à jour sous verrou : plusieurs envois peuvent arriver en même temps.
function enregistrer($cfg, $id, $source, $run) {
    $dir = chemin($cfg, 'resultats/' . preg_replace('/[^a-z0-9_.-]/i', '_', $id));
    if (!is_dir($dir) && !@mkdir($dir, 0750, true)) { return false; }
    $recu = time();
    $run['recu'] = $recu;
    $run['source'] = $source;
    $nom = date('Ymd-His', $recu) . '-' . $source . '-' . $run['labo'] . '-' . substr(bin2hex(random_bytes(3)), 0, 6) . '.json';
    $json = json_encode($run, JSON_UNESCAPED_UNICODE | JSON_INVALID_UTF8_SUBSTITUTE);
    if ($json === false || @file_put_contents($dir . '/' . $nom, $json) === false) { return false; }

    $verrou = fopen(chemin($cfg, 'resume.lock'), 'c');
    if ($verrou) { flock($verrou, LOCK_EX); }
    $r = resume($cfg);
    if (!isset($r[$id])) { $r[$id] = ['labos' => [], 'envois' => 0, 'releves' => 0]; }
    $e = &$r[$id];
    $e[$source === 'site' ? 'envois' : 'releves']++;
    $e['dernier_' . $source] = $recu;
    foreach ($run['machines'] as $m) {
        if (!empty($m['meta']['hostname'])) { $e['hostnames'][$m['id']] = $m['meta']['hostname']; }
        if ($m['erreur'] !== null && $source === 'releve') { $e['erreur_releve'][$m['id']] = $m['erreur']; }
        elseif ($source === 'releve') { unset($e['erreur_releve'][$m['id']]); }
    }
    foreach (checks_par_labo($run) as $labo => $liste) {
        $b = bilan($liste);
        if ($b['score'] === null) { continue; }
        $rec = ['date' => $recu, 'score' => $b['score'], 'OK' => $b['OK'], 'KO' => $b['KO'], 'WARN' => $b['WARN'], 'fichier' => $nom];
        $e['labos'][$labo][$source] = $rec;
        $best = isset($e['labos'][$labo]['meilleur_' . $source]) ? $e['labos'][$labo]['meilleur_' . $source]['score'] : -1;
        if ($b['score'] >= $best) { $e['labos'][$labo]['meilleur_' . $source] = $rec; }
    }
    unset($e);
    $ok = @file_put_contents(chemin($cfg, 'resume.json.tmp'), json_encode($r, JSON_UNESCAPED_UNICODE | JSON_PRETTY_PRINT)) !== false
          && @rename(chemin($cfg, 'resume.json.tmp'), chemin($cfg, 'resume.json'));
    if ($verrou) { flock($verrou, LOCK_UN); fclose($verrou); }
    return $ok ? $nom : false;
}

function resume($cfg) {
    $f = chemin($cfg, 'resume.json');
    $j = is_file($f) ? json_decode((string)file_get_contents($f), true) : null;
    return is_array($j) ? $j : [];
}

// Étudiant déjà atteint par une relève : au moins une machine a déjà répondu
// et la dernière tentative ne signale aucune erreur (sinon on réessaie).
function deja_relie($resume, $id) {
    $x = isset($resume[$id]) ? $resume[$id] : [];
    $repondu = false;
    foreach (isset($x['labos']) ? $x['labos'] : [] as $l) {
        if (isset($l['releve'])) { $repondu = true; break; }
    }
    return $repondu && empty($x['erreur_releve']);
}

function historique($cfg, $id, $max) {
    $dir = chemin($cfg, 'resultats/' . preg_replace('/[^a-z0-9_.-]/i', '_', $id));
    $f = is_dir($dir) ? glob($dir . '/*.json') : [];
    rsort($f);
    return array_slice(array_map('basename', $f), 0, $max);
}

function lire_run($cfg, $id, $fichier) {
    if (!preg_match('/^[0-9]{8}-[0-9]{6}-(site|releve)-(tout|\d\d)-[0-9a-f]{6}\.json$/', $fichier)) { return null; }
    $f = chemin($cfg, 'resultats/' . preg_replace('/[^a-z0-9_.-]/i', '_', $id) . '/' . $fichier);
    $j = is_file($f) ? json_decode((string)file_get_contents($f), true) : null;
    return is_array($j) ? $j : null;
}
