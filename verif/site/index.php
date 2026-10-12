<?php
// Site de contrôle du labo — EAFC Uccle, Logiciel open source 2026-2027.
// Le site se connecte en SSH (compte prof, clé restreinte) à chaque machine et affiche le
// rapport du script verif-lab. Il ne modifie rien sur les machines contrôlées.

date_default_timezone_set('Europe/Brussels');
$cfg = require __DIR__ . '/config.php';

function h($s) { return htmlspecialchars((string)$s, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8'); }

function ip_dans_reseau($ip, $cidr) {
    $parts = explode('/', $cidr, 2);
    $net = $parts[0];
    $bits = isset($parts[1]) ? (int)$parts[1] : 32;
    $ipl = ip2long($ip);
    $netl = ip2long($net);
    if ($ipl === false || $netl === false) { return false; }
    $mask = ($bits === 0) ? 0 : ((-1 << (32 - $bits)) & 0xFFFFFFFF);
    return ($ipl & $mask) === ($netl & $mask);
}

// ---- Accès réservé au LAN du labo -------------------------------------------
$remote = isset($_SERVER['REMOTE_ADDR']) ? $_SERVER['REMOTE_ADDR'] : '';
$autorise = ($remote === '::1');
foreach ($cfg['reseaux_autorises'] as $cidr) {
    if (ip_dans_reseau($remote, $cidr)) { $autorise = true; break; }
}
if (!$autorise) {
    http_response_code(403);
    header('Content-Type: text/plain; charset=UTF-8');
    echo "Accès refusé : ce site n'est consultable que depuis le réseau du labo.\n";
    exit;
}

$etat = $cfg['etat'];
$fichier = $etat . '/dernier.json';

// ---- Résultat enregistré -----------------------------------------------------
function charger($f) {
    if (!is_file($f)) { return null; }
    $j = json_decode((string)file_get_contents($f), true);
    return is_array($j) ? $j : null;
}

function sauver($f, $d) {
    $json = json_encode($d, JSON_UNESCAPED_UNICODE | JSON_INVALID_UTF8_SUBSTITUTE | JSON_PRETTY_PRINT);
    if ($json === false) { return false; }
    $tmp = $f . '.tmp';
    if (@file_put_contents($tmp, $json) === false) { return false; }
    return @rename($tmp, $f);
}

// ---- Connexion SSH et lecture du rapport ---------------------------------------
function ssh_lancer($cfg, $hote) {
    $cmd = [
        'ssh', '-T', '-i', $cfg['ssh_key'],
        '-o', 'BatchMode=yes', '-o', 'IdentitiesOnly=yes', '-o', 'ConnectTimeout=5',
        '-o', 'StrictHostKeyChecking=accept-new',
        '-o', 'UserKnownHostsFile=' . $cfg['known_hosts'],
        '-o', 'LogLevel=ERROR',
        $cfg['ssh_user'] . '@' . $hote, 'verif',
    ];
    $desc = [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']];
    $env = ['HOME' => $cfg['etat'], 'PATH' => '/usr/bin:/bin'];
    $p = @proc_open($cmd, $desc, $pipes, null, $env);
    if (!is_resource($p)) {
        return ['ok' => false, 'out' => '', 'err' => "Impossible de lancer ssh (paquet openssh-client installé ?)"];
    }
    fclose($pipes[0]);
    stream_set_blocking($pipes[1], false);
    stream_set_blocking($pipes[2], false);
    $out = '';
    $err = '';
    $fin = time() + (int)$cfg['timeout'];
    while (true) {
        $lire = [$pipes[1], $pipes[2]];
        $w = null;
        $e = null;
        if (@stream_select($lire, $w, $e, 1) > 0) {
            foreach ($lire as $s) {
                $d = fread($s, 8192);
                if ($d !== false && $d !== '') {
                    if ($s === $pipes[1]) { $out .= $d; } else { $err .= $d; }
                }
            }
        }
        $st = proc_get_status($p);
        if (!$st['running']) {
            $out .= (string)stream_get_contents($pipes[1]);
            $err .= (string)stream_get_contents($pipes[2]);
            break;
        }
        if (time() > $fin) {
            proc_terminate($p);
            $err .= "\nDélai dépassé";
            break;
        }
    }
    fclose($pipes[1]);
    fclose($pipes[2]);
    proc_close($p);
    return ['ok' => (strpos($out, "CHECK\t") !== false), 'out' => $out, 'err' => trim($err)];
}

function parser($out) {
    $meta = [];
    $checks = [];
    foreach (preg_split('/\r?\n/', $out) as $ligne) {
        if ($ligne === '') { continue; }
        $f = explode("\t", $ligne);
        if ($f[0] === 'META' && count($f) >= 3) {
            $meta[$f[1]] = $f[2];
        } elseif ($f[0] === 'CHECK' && count($f) >= 7) {
            $checks[] = [
                'section' => $f[1], 'id' => $f[2], 'statut' => $f[3],
                'libelle' => $f[4], 'detail' => $f[5], 'conseil' => $f[6],
            ];
        }
    }
    return [$meta, $checks];
}

function expliquer($err) {
    if (stripos($err, 'Permission denied') !== false) {
        return "connexion refusée : le compte prof n'existe pas ou sa clé n'est pas autorisée (relancer install-prof.sh sur cette machine).";
    }
    if (stripos($err, 'HOST IDENTIFICATION HAS CHANGED') !== false || stripos($err, 'Host key verification failed') !== false) {
        return "l'empreinte SSH a changé (machine recréée ?) : utiliser « Oublier les empreintes SSH ».";
    }
    if (stripos($err, 'timed out') !== false || stripos($err, 'No route') !== false || stripos($err, 'Délai dépassé') !== false) {
        return "machine injoignable : vérifier l'adresse IP, le VLAN et le routage.";
    }
    if (stripos($err, 'refused') !== false) {
        return "port 22 fermé : le service SSH tourne-t-il, et le pare-feu autorise-t-il le port 22 ?";
    }
    return ($err !== '') ? $err : "aucune réponse du script de contrôle.";
}

function lancer($cfg) {
    $res = ['date' => time(), 'machines' => []];
    foreach ($cfg['cibles'] as $c) {
        $m = ['id' => $c['id'], 'nom' => $c['nom'], 'hote' => null, 'erreur' => null, 'meta' => [], 'checks' => []];
        $notes = [];
        foreach ($c['hotes'] as $i => $hote) {
            $r = ssh_lancer($cfg, $hote);
            if ($r['ok']) {
                list($meta, $checks) = parser($r['out']);
                $m['hote'] = $hote;
                $m['meta'] = $meta;
                $m['checks'] = $checks;
                if ($i > 0) {
                    array_unshift($m['checks'], [
                        'section' => 'Réseau du PC', 'id' => 'site.joignable', 'statut' => 'KO',
                        'libelle' => 'La machine répond sur ' . $c['hotes'][0],
                        'detail' => 'contrôle fait via ' . $hote,
                        'conseil' => 'Adresse prévue : ' . $c['hotes'][0] . '. Vérifier la réservation DHCP ou l\'adresse statique.',
                    ]);
                }
                break;
            }
            $notes[] = $hote . ' : ' . expliquer($r['err']);
        }
        if ($m['hote'] === null) { $m['erreur'] = implode(' / ', $notes); }
        $res['machines'][] = $m;
    }
    return $res;
}

// ---- Bilans et rapports --------------------------------------------------------
function bilan($checks) {
    $b = ['OK' => 0, 'KO' => 0, 'WARN' => 0, 'INFO' => 0];
    foreach ($checks as $c) {
        if (isset($b[$c['statut']])) { $b[$c['statut']]++; }
    }
    $tot = $b['OK'] + $b['KO'] + $b['WARN'];
    $b['total'] = $tot;
    $b['score'] = ($tot > 0) ? (int)round(100 * $b['OK'] / $tot) : 0;
    return $b;
}

function grouper($checks) {
    $g = [];
    foreach ($checks as $c) { $g[$c['section']][] = $c; }
    return $g;
}

function classe_score($s) { return ($s >= 90) ? 'bon' : (($s >= 60) ? 'moyen' : 'faible'); }

function libelle_statut($s) {
    $t = ['OK' => 'OK', 'KO' => 'KO', 'WARN' => 'À AMÉLIORER', 'INFO' => 'INFO'];
    return isset($t[$s]) ? $t[$s] : $s;
}

function rapport_texte($d) {
    $o = "RAPPORT DE CONTRÔLE DU LABO — EAFC Uccle\n";
    $o .= 'Date : ' . date('d/m/Y H:i:s', (int)$d['date']) . "\n";
    foreach ($d['machines'] as $m) {
        $nom = isset($m['meta']['hostname']) ? $m['meta']['hostname'] : $m['nom'];
        $o .= "\n==================== " . $m['nom'] . ' (' . $nom . ") ====================\n";
        if ($m['erreur'] !== null) { $o .= 'Contrôle impossible : ' . $m['erreur'] . "\n"; continue; }
        $b = bilan($m['checks']);
        $o .= 'Score : ' . $b['score'] . ' % (' . $b['OK'] . ' OK, ' . $b['KO'] . ' KO, ' . $b['WARN'] . " à améliorer)\n";
        foreach (['os', 'cpu', 'ram', 'disque', 'demarrage', 'adresses'] as $k) {
            if (isset($m['meta'][$k])) { $o .= '  ' . str_pad($k, 10) . ' ' . $m['meta'][$k] . "\n"; }
        }
        foreach (grouper($m['checks']) as $sec => $liste) {
            $o .= "\n-- " . $sec . " --\n";
            foreach ($liste as $c) {
                $o .= sprintf("[%-11s] %s", libelle_statut($c['statut']), $c['libelle']);
                if ($c['detail'] !== '') { $o .= ' — ' . $c['detail']; }
                $o .= "\n";
                if ($c['conseil'] !== '' && ($c['statut'] === 'KO' || $c['statut'] === 'WARN')) {
                    $o .= '              → ' . $c['conseil'] . "\n";
                }
            }
        }
    }
    return $o;
}

// ---- Actions ---------------------------------------------------------------------
$messages = [
    'trop_vite' => "Patientez quelques secondes entre deux vérifications.",
    'ecriture'  => "Impossible d'écrire le résultat dans " . $etat . " : vérifier les droits de www-data.",
    'reset'     => "Empreintes SSH oubliées : elles seront réapprises à la prochaine vérification.",
    'fait'      => "",
];
$code = isset($_GET['m']) ? (string)$_GET['m'] : '';
$data = null;
$format = isset($_GET['format']) ? (string)$_GET['format'] : '';
$methode = isset($_SERVER['REQUEST_METHOD']) ? $_SERVER['REQUEST_METHOD'] : 'GET';

if ($methode === 'POST') {
    $origine = isset($_SERVER['HTTP_ORIGIN']) ? $_SERVER['HTTP_ORIGIN'] : '';
    if ($origine !== '') {
        $hoteOrigine = (string)parse_url($origine, PHP_URL_HOST);
        $hoteSite = explode(':', isset($_SERVER['HTTP_HOST']) ? $_SERVER['HTTP_HOST'] : '')[0];
        if ($hoteOrigine !== $hoteSite) {
            http_response_code(403);
            echo 'Origine refusée.';
            exit;
        }
    }
    $action = isset($_POST['action']) ? (string)$_POST['action'] : '';
    if ($action === 'run') {
        $age = is_file($fichier) ? (time() - (int)filemtime($fichier)) : PHP_INT_MAX;
        if ($age < (int)$cfg['delai_min']) {
            $code = 'trop_vite';
        } else {
            $data = lancer($cfg);
            $code = sauver($fichier, $data) ? 'fait' : 'ecriture';
        }
    } elseif ($action === 'reset') {
        if (is_file($cfg['known_hosts'])) { @unlink($cfg['known_hosts']); }
        $code = 'reset';
    }
    if ($format !== 'txt') {
        header('Location: ./?m=' . urlencode($code), true, 303);
        exit;
    }
}

if ($data === null) { $data = charger($fichier); }
$msg = isset($messages[$code]) ? $messages[$code] : '';

if ($format === 'txt' || isset($_GET['rapport'])) {
    header('Content-Type: text/plain; charset=UTF-8');
    if (isset($_GET['rapport'])) { header('Content-Disposition: attachment; filename="rapport-labo.txt"'); }
    if ($msg !== '') { echo $msg . "\n\n"; }
    echo $data ? rapport_texte($data) : "Aucun résultat : lancez une vérification (POST action=run).\n";
    exit;
}

// ---- Page HTML -----------------------------------------------------------------------
$toutes = [];
if ($data) {
    foreach ($data['machines'] as $m) { $toutes = array_merge($toutes, $m['checks']); }
}
$bg = bilan($toutes);
?><!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title><?= h($cfg['titre']) ?> — EAFC Uccle</title>
<link rel="stylesheet" href="style.css">
</head>
<body>
<main>
<header>
  <p class="kicker">LOGICIEL OPEN SOURCE — 2026-2027</p>
  <h1><?= h($cfg['titre']) ?></h1>
  <p class="intro">Le site se connecte en SSH avec le compte <code>prof</code> (clé restreinte, lecture seule) au routeur et au PC, puis compare leur configuration avec ce que demandent les labos.</p>
</header>

<?php if ($msg !== ''): ?>
<p class="message"><?= h($msg) ?></p>
<?php endif; ?>

<div class="actions">
  <form method="post" action="./">
    <input type="hidden" name="action" value="run">
    <button type="submit" class="principal">Lancer la vérification</button>
  </form>
  <?php if ($data): ?>
  <a class="lien" href="?rapport=1">Télécharger le rapport (.txt)</a>
  <?php endif; ?>
  <form method="post" action="./">
    <input type="hidden" name="action" value="reset">
    <button type="submit" class="discret">Oublier les empreintes SSH</button>
  </form>
</div>

<?php if (!$data): ?>
<p class="vide">Aucune vérification enregistrée. Cliquez sur « Lancer la vérification ».</p>
<?php else: ?>
<p class="date">Dernière vérification : <?= h(date('d/m/Y H:i:s', (int)$data['date'])) ?></p>

<section class="global">
  <div class="score <?= h(classe_score($bg['score'])) ?>"><?= (int)$bg['score'] ?> %</div>
  <div>
    <p class="titre-global">Score global</p>
    <p><?= (int)$bg['OK'] ?> OK · <?= (int)$bg['KO'] ?> KO · <?= (int)$bg['WARN'] ?> à améliorer — sur <?= (int)$bg['total'] ?> contrôles</p>
  </div>
</section>

<?php foreach ($data['machines'] as $m): ?>
<?php $nom = isset($m['meta']['hostname']) ? $m['meta']['hostname'] : $m['nom']; ?>
<section class="machine">
  <h2><?= h($m['nom']) ?> <span class="hote">(<?= h($nom) ?><?= $m['hote'] ? ' — ' . h($m['hote']) : '' ?>)</span></h2>
  <?php if ($m['erreur'] !== null): ?>
    <p class="erreur">Contrôle impossible : <?= h($m['erreur']) ?></p>
  <?php else: ?>
    <?php $b = bilan($m['checks']); ?>
    <p class="bilan"><span class="score petit <?= h(classe_score($b['score'])) ?>"><?= (int)$b['score'] ?> %</span>
      <?= (int)$b['OK'] ?> OK · <?= (int)$b['KO'] ?> KO · <?= (int)$b['WARN'] ?> à améliorer</p>
    <ul class="meta">
      <?php foreach (['os' => 'Système', 'cpu' => 'CPU', 'ram' => 'Mémoire', 'disque' => 'Disque', 'demarrage' => 'Démarrée', 'adresses' => 'Adresses'] as $k => $lib): ?>
        <?php if (!empty($m['meta'][$k])): ?><li><b><?= h($lib) ?></b> <?= h($m['meta'][$k]) ?></li><?php endif; ?>
      <?php endforeach; ?>
    </ul>
    <?php foreach (grouper($m['checks']) as $sec => $liste): ?>
      <h3><?= h($sec) ?></h3>
      <ul class="checks">
      <?php foreach ($liste as $c): ?>
        <li class="st-<?= h(strtolower($c['statut'])) ?>">
          <span class="badge"><?= h(libelle_statut($c['statut'])) ?></span>
          <span class="lib"><?= h($c['libelle']) ?></span>
          <?php if ($c['detail'] !== ''): ?><span class="det">— <?= h($c['detail']) ?></span><?php endif; ?>
          <?php if ($c['conseil'] !== '' && ($c['statut'] === 'KO' || $c['statut'] === 'WARN')): ?>
            <span class="conseil">→ <?= h($c['conseil']) ?></span>
          <?php endif; ?>
        </li>
      <?php endforeach; ?>
      </ul>
    <?php endforeach; ?>
  <?php endif; ?>
</section>
<?php endforeach; ?>
<?php endif; ?>

<footer>Outil en lecture seule : le compte prof ne peut lancer que le script <code>verif-lab</code>. Même rapport en console : <code>verif-lab --texte</code>.</footer>
</main>
</body>
</html>
