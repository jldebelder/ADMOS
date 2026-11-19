<?php
// Tableau de bord de l'enseignant : la classe × les labos, l'historique de chaque étudiant,
// la relève de toute la classe et l'export CSV (à coller dans Evaluation_Labos_ADMOS).
require __DIR__ . '/commun.php';

// ---- Accès : mot de passe de l'enseignant (/var/lib/suivi/acces.php) -------------------
session_set_cookie_params(['httponly' => true, 'samesite' => 'Strict']);
session_start();
$acces = is_file(chemin($CFG, 'acces.php')) ? (include chemin($CFG, 'acces.php')) : [];
$hash = isset($acces['mot_de_passe']) ? $acces['mot_de_passe'] : '';
if (empty($_SESSION['jeton'])) { $_SESSION['jeton'] = bin2hex(random_bytes(16)); }
$methode = $_SERVER['REQUEST_METHOD'] ?? 'GET';
$erreur_login = '';

if ($methode === 'POST' && isset($_POST['mot_de_passe'])) {
    sleep(1);
    if ($hash !== '' && password_verify((string)$_POST['mot_de_passe'], $hash)) {
        session_regenerate_id(true);
        $_SESSION['prof'] = true;
        header('Location: ./', true, 303);
        exit;
    }
    $erreur_login = ($hash === '') ? "Aucun mot de passe défini : relancer install-suivi.sh." : "Mot de passe incorrect.";
}
if (empty($_SESSION['prof'])) {
    ?><!DOCTYPE html><html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
    <title><?= h($CFG['titre']) ?></title><link rel="stylesheet" href="style.css"></head><body><main class="etroit">
    <p class="kicker">ADMOS — 2026-2027</p><h1><?= h($CFG['titre']) ?></h1>
    <?php if ($erreur_login): ?><p class="message"><?= h($erreur_login) ?></p><?php endif; ?>
    <form method="post" class="login"><label>Mot de passe de l'enseignant <input type="password" name="mot_de_passe" autofocus></label>
    <button class="principal">Entrer</button></form></main></body></html><?php
    exit;
}

// ---- Actions -----------------------------------------------------------------------------
$msg = '';
if ($methode === 'POST') {
    if (!hash_equals($_SESSION['jeton'], (string)($_POST['jeton'] ?? ''))) { http_response_code(403); exit('Jeton invalide.'); }
    $a = (string)($_POST['action'] ?? '');
    if ($a === 'releve') {
        $l = (string)($_POST['labo'] ?? 'tout');
        $l = ($l === 'tout' || isset($CFG['labos'][$l])) ? $l : 'tout';
        $args = '--labo ' . escapeshellarg($l);
        if (!empty($_POST['etudiant']) && preg_match('/^[0-9]+$/', (string)$_POST['etudiant'])) { $args .= ' --etudiant ' . escapeshellarg($_POST['etudiant']); }
        exec('nohup /usr/bin/php ' . escapeshellarg(__DIR__ . '/releve.php') . ' ' . $args . ' > ' . escapeshellarg(chemin($CFG, 'releve.log')) . ' 2>&1 &');
        $msg = 'releve';
    } elseif ($a === 'oublier') {
        @unlink(chemin($CFG, 'ssh/known_hosts'));
        $msg = 'oublier';
    } elseif ($a === 'sortir') {
        session_destroy();
        header('Location: ./', true, 303);
        exit;
    }
    $retour = './?m=' . urlencode($msg) . (isset($_POST['etudiant']) ? '&etudiant=' . urlencode((string)$_POST['etudiant']) : '');
    header('Location: ' . $retour, true, 303);
    exit;
}
$messages = ['releve' => 'Relève lancée : actualisez la page dans une minute (journal en bas de page).',
             'oublier' => 'Empreintes SSH oubliées : elles seront réapprises à la prochaine relève.'];
$msg = $messages[$_GET['m'] ?? ''] ?? '';

$classe = classe($CFG);
$res = resume($CFG);
$labos = $CFG['labos'];

// ---- Export CSV (séparateur ; et BOM, pour Excel) ----------------------------------------
if (isset($_GET['export'])) {
    header('Content-Type: text/csv; charset=UTF-8');
    header('Content-Disposition: attachment; filename="suivi-labos-' . date('Ymd-Hi') . '.csv"');
    $o = fopen('php://output', 'w');
    fwrite($o, "\xEF\xBB\xBF");
    $tete = ['ID', 'Nom', 'Prénom', 'WAN'];
    foreach ($labos as $n => $t) { $tete[] = "L$n relevé %"; $tete[] = "L$n site dernier %"; $tete[] = "L$n site meilleur %"; }
    $tete[] = 'Envois'; $tete[] = 'Dernier envoi'; $tete[] = 'Dernière relève';
    fputcsv($o, $tete, ';');
    foreach ($classe as $id => $e) {
        $r = $res[$id] ?? [];
        $l = [$id, $e['nom'], $e['prenom'], $e['wan']];
        foreach ($labos as $n => $t) {
            $x = $r['labos'][$n] ?? [];
            $l[] = $x['releve']['score'] ?? ''; $l[] = $x['site']['score'] ?? ''; $l[] = $x['meilleur_site']['score'] ?? '';
        }
        $l[] = $r['envois'] ?? 0;
        $l[] = isset($r['dernier_site']) ? date('d/m/Y H:i', $r['dernier_site']) : '';
        $l[] = isset($r['dernier_releve']) ? date('d/m/Y H:i', $r['dernier_releve']) : '';
        fputcsv($o, $l, ';');
    }
    exit;
}

function date_courte($t) { return $t ? date('d/m H:i', (int)$t) : '—'; }
function libelle_statut($s) { $t = ['OK' => 'OK', 'KO' => 'KO', 'WARN' => 'À AMÉLIORER', 'INFO' => 'INFO']; return $t[$s] ?? $s; }
function form_post($jeton, $champs, $bouton, $classe = '') {
    $o = '<form method="post" action="./"><input type="hidden" name="jeton" value="' . h($jeton) . '">';
    foreach ($champs as $k => $v) { $o .= '<input type="hidden" name="' . h($k) . '" value="' . h($v) . '">'; }
    return $o . '<button type="submit" class="' . h($classe) . '">' . h($bouton) . '</button></form>';
}

$vue_etudiant = isset($_GET['etudiant']) ? (string)$_GET['etudiant'] : null;
$vue_run = isset($_GET['run']) ? (string)$_GET['run'] : null;
$inconnus = array_filter(array_keys($res), function ($k) { return strncmp($k, 'inconnu-', 8) === 0; });
?><!DOCTYPE html>
<html lang="fr">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title><?= h($CFG['titre']) ?> — EAFC Uccle</title>
<link rel="stylesheet" href="style.css">
</head>
<body>
<main>
<header>
  <p class="kicker">ADMOS — LOGICIEL OPEN SOURCE — 2026-2027</p>
  <h1><a href="./"><?= h($CFG['titre']) ?></a></h1>
  <p class="intro"><b>Site</b> : ce que l'étudiant a envoyé en cliquant sur « Lancer la vérification » (sa progression).
     <b>Relevé</b> : ce que vous avez relevé vous-même sur ses machines (la référence pour la note).</p>
</header>
<?php if ($msg): ?><p class="message"><?= h($msg) ?></p><?php endif; ?>

<?php if ($vue_etudiant === null): /* =============== TABLEAU DE LA CLASSE =============== */ ?>
<div class="actions">
  <form method="post" action="./">
    <input type="hidden" name="jeton" value="<?= h($_SESSION['jeton']) ?>"><input type="hidden" name="action" value="releve">
    <select name="labo"><option value="tout">Tous les labos</option>
      <?php foreach ($labos as $n => $t): ?><option value="<?= h($n) ?>">Labo <?= h($n) ?> — <?= h($t) ?></option><?php endforeach; ?>
    </select>
    <button type="submit" class="principal">Relever toute la classe</button>
  </form>
  <a class="lien" href="?export=csv">Exporter en CSV (Excel)</a>
  <?= form_post($_SESSION['jeton'], ['action' => 'oublier'], 'Oublier les empreintes SSH', 'discret') ?>
  <?= form_post($_SESSION['jeton'], ['action' => 'sortir'], 'Se déconnecter', 'discret') ?>
</div>

<?php if (!$classe): ?>
<p class="erreur">classe.csv est vide ou absent : copiez-le dans <code><?= h(chemin($CFG, 'classe.csv')) ?></code> (format <code>id;nom;prenom;wan</code>).</p>
<?php endif; ?>

<div class="defile">
<table class="classe">
  <thead><tr><th class="g">Étudiant</th>
    <?php foreach ($labos as $n => $t): ?><th title="<?= h($t) ?>">L<?= h($n) ?><br><span><?= h(mb_strimwidth($t, 0, 12, '…')) ?></span></th><?php endforeach; ?>
    <th>Envois</th><th>Dernier envoi</th><th>Dernière relève</th></tr></thead>
  <tbody>
  <?php foreach ($classe as $id => $e): $r = $res[$id] ?? []; ?>
    <tr>
      <td class="g"><a href="?etudiant=<?= h(urlencode($id)) ?>"><?= h($e['nom']) ?> <?= h($e['prenom']) ?></a>
        <span class="petit"><?= h($e['wan'] ?: 'WAN inconnue') ?></span>
        <?php if (!empty($r['erreur_releve'])): ?><span class="alerte" title="<?= h(implode(' / ', $r['erreur_releve'])) ?>">relève impossible</span><?php endif; ?></td>
      <?php foreach ($labos as $n => $t): $x = $r['labos'][$n] ?? []; $rel = $x['releve']['score'] ?? null; $site = $x['site']['score'] ?? null; ?>
        <td class="note <?= h(classe_score($rel !== null ? $rel : $site)) ?>"
            title="Relevé : <?= $rel !== null ? h($rel . ' % le ' . date_courte($x['releve']['date'])) : '—' ?> · Site : <?= $site !== null ? h($site . ' % le ' . date_courte($x['site']['date'])) : '—' ?> · Meilleur site : <?= h($x['meilleur_site']['score'] ?? '—') ?>">
          <?php if ($rel !== null): ?><b><?= (int)$rel ?></b><?php endif; ?>
          <?php if ($site !== null && $rel !== null): ?><span class="site">site <?= (int)$site ?></span>
          <?php elseif ($site !== null): ?><b class="seul"><?= (int)$site ?></b><span class="site">site</span><?php endif; ?>
          <?php if ($rel === null && $site === null): ?>·<?php endif; ?>
        </td>
      <?php endforeach; ?>
      <td><?= (int)($r['envois'] ?? 0) ?></td>
      <td><?= h(date_courte($r['dernier_site'] ?? null)) ?></td>
      <td><?= h(date_courte($r['dernier_releve'] ?? null)) ?></td>
    </tr>
  <?php endforeach; ?>
  </tbody>
</table>
</div>
<p class="legende">Gros chiffre = score relevé par vous (ou, à défaut, marqué « site », le dernier envoi de l'étudiant) ; petit « site NN » = dernier envoi de l'étudiant. Vert ≥ 90 %, jaune ≥ 60 %, rouge en dessous.
Survolez une case pour les dates.</p>

<?php if ($inconnus): ?>
<section class="machine"><h2>Envois non reconnus</h2>
<p class="petit">Adresse WAN absente de classe.csv : ajoutez-la à la bonne ligne (la colonne <code>wan</code>), les prochains envois seront rattachés à l'étudiant.</p>
<ul class="meta"><?php foreach ($inconnus as $k): $r = $res[$k]; ?>
  <li><a href="?etudiant=<?= h(urlencode($k)) ?>"><?= h(substr($k, 8)) ?></a> — machines : <?= h(implode(', ', $r['hostnames'] ?? [])) ?> — <?= (int)$r['envois'] ?> envoi(s), dernier le <?= h(date_courte($r['dernier_site'] ?? null)) ?></li>
<?php endforeach; ?></ul></section>
<?php endif; ?>

<?php $log = chemin($CFG, 'releve.log'); if (is_file($log)): ?>
<section class="machine"><h2>Dernière relève</h2><pre class="log"><?= h(file_get_contents($log)) ?></pre></section>
<?php endif; ?>

<?php elseif ($vue_run === null): /* =============== FICHE D'UN ÉTUDIANT =============== */
    $e = $classe[$vue_etudiant] ?? ['id' => $vue_etudiant, 'nom' => $vue_etudiant, 'prenom' => '', 'wan' => ''];
    $r = $res[$vue_etudiant] ?? [];
?>
<p><a class="lien" href="./">← la classe</a></p>
<section class="machine">
  <h2><?= h($e['nom'] . ' ' . $e['prenom']) ?> <span class="hote">(<?= h($e['wan'] ?: 'WAN inconnue') ?> — <?= h(implode(', ', $r['hostnames'] ?? [])) ?>)</span></h2>
  <?php if (!empty($r['erreur_releve'])): ?><p class="erreur">Dernière relève : <?= h(implode(' / ', array_map(function ($k, $v) { return "$k : $v"; }, array_keys($r['erreur_releve']), $r['erreur_releve']))) ?></p><?php endif; ?>
  <?php if (isset($classe[$vue_etudiant]) && $e['wan'] !== ''): ?>
  <div class="actions">
    <form method="post" action="./"><input type="hidden" name="jeton" value="<?= h($_SESSION['jeton']) ?>">
      <input type="hidden" name="action" value="releve"><input type="hidden" name="etudiant" value="<?= h($vue_etudiant) ?>">
      <select name="labo"><option value="tout">Tous les labos</option>
        <?php foreach ($labos as $n => $t): ?><option value="<?= h($n) ?>">Labo <?= h($n) ?> — <?= h($t) ?></option><?php endforeach; ?></select>
      <button class="principal">Relever cet étudiant</button></form>
  </div>
  <?php endif; ?>
  <table class="fiche">
    <thead><tr><th class="g">Labo</th><th>Relevé</th><th>Site (dernier)</th><th>Site (meilleur)</th></tr></thead>
    <tbody>
    <?php foreach ($labos as $n => $t): $x = $r['labos'][$n] ?? []; ?>
      <tr><td class="g">Labo <?= h($n) ?> — <?= h($t) ?></td>
      <?php foreach (['releve', 'site', 'meilleur_site'] as $k): $v = $x[$k] ?? null; ?>
        <td class="note <?= h(classe_score($v['score'] ?? null)) ?>"><?php if ($v): ?>
          <a href="?etudiant=<?= h(urlencode($vue_etudiant)) ?>&amp;run=<?= h(urlencode($v['fichier'])) ?>"><b><?= (int)$v['score'] ?> %</b></a>
          <span class="petit"><?= (int)$v['KO'] ?> KO · <?= h(date_courte($v['date'])) ?></span><?php else: ?>·<?php endif; ?></td>
      <?php endforeach; ?></tr>
    <?php endforeach; ?>
    </tbody>
  </table>
</section>
<section class="machine"><h2>Historique</h2>
  <ul class="checks">
  <?php foreach (historique($CFG, $vue_etudiant, (int)$CFG['historique']) as $f):
      $run = lire_run($CFG, $vue_etudiant, $f); if (!$run) { continue; }
      $tous = []; foreach ($run['machines'] as $m) { $tous = array_merge($tous, $m['checks']); }
      $b = bilan(array_filter($tous, function ($c) { return $c['labo'] !== '00'; })); ?>
    <li><span class="badge src-<?= h($run['source']) ?>"><?= $run['source'] === 'site' ? 'SITE' : 'RELEVÉ' ?></span>
      <a href="?etudiant=<?= h(urlencode($vue_etudiant)) ?>&amp;run=<?= h(urlencode($f)) ?>"><?= h(date('d/m/Y H:i', (int)$run['recu'])) ?></a>
      — <?= $run['labo'] === 'tout' ? 'tous les labos' : 'labo ' . h($run['labo']) ?>
      — <span class="score petit <?= h(classe_score($b['score'])) ?>"><?= $b['score'] === null ? '—' : (int)$b['score'] . ' %' ?></span>
      <span class="det"><?= (int)$b['KO'] ?> KO · <?= (int)$b['WARN'] ?> à améliorer</span>
      <?php foreach ($run['machines'] as $m): if ($m['erreur'] !== null): ?><span class="det"> — <?= h($m['nom']) ?> : <?= h($m['erreur']) ?></span><?php endif; endforeach; ?></li>
  <?php endforeach; ?>
  </ul>
</section>

<?php else: /* =============== DÉTAIL D'UN RÉSULTAT =============== */
    $run = lire_run($CFG, $vue_etudiant, $vue_run);
    $e = $classe[$vue_etudiant] ?? ['nom' => $vue_etudiant, 'prenom' => ''];
?>
<p><a class="lien" href="?etudiant=<?= h(urlencode($vue_etudiant)) ?>">← <?= h($e['nom'] . ' ' . $e['prenom']) ?></a></p>
<?php if (!$run): ?><p class="erreur">Résultat introuvable.</p><?php else: ?>
<p class="date"><?= $run['source'] === 'site' ? 'Envoyé par le site de l\'étudiant' : 'Relevé par l\'enseignant' ?> le <?= h(date('d/m/Y H:i:s', (int)$run['recu'])) ?>
  — <?= $run['labo'] === 'tout' ? 'tous les labos' : 'labo ' . h($run['labo']) ?><?= isset($run['ip']) ? ' — depuis ' . h($run['ip']) : '' ?></p>
<?php foreach ($run['machines'] as $m): ?>
<section class="machine">
  <h2><?= h($m['nom']) ?> <span class="hote">(<?= h($m['meta']['hostname'] ?? '?') ?> — <?= h($m['hote']) ?>)</span></h2>
  <?php if ($m['erreur'] !== null): ?><p class="erreur">Contrôle impossible : <?= h($m['erreur']) ?></p><?php else:
      $g = []; foreach ($m['checks'] as $c) { $g[$c['section']][] = $c; } ?>
    <?php foreach ($g as $sec => $liste): ?>
      <h3><?= $liste[0]['labo'] !== '00' ? 'Labo ' . h($liste[0]['labo']) . ' · ' : '' ?><?= h($sec) ?></h3>
      <ul class="checks"><?php foreach ($liste as $c): ?>
        <li class="st-<?= h(strtolower($c['statut'])) ?>"><span class="badge"><?= h(libelle_statut($c['statut'])) ?></span>
          <span class="lib"><?= h($c['libelle']) ?></span><?php if ($c['detail'] !== ''): ?><span class="det"> — <?= h($c['detail']) ?></span><?php endif; ?></li>
      <?php endforeach; ?></ul>
    <?php endforeach; ?>
  <?php endif; ?>
</section>
<?php endforeach; ?>
<?php endif; ?>
<?php endif; ?>

<footer>Données : <code><?= h($CFG['donnees']) ?></code> · relève en ligne de commande : <code>sudo -u www-data php <?= h(__DIR__) ?>/releve.php [--labo 05] [--etudiant 3]</code></footer>
</main>
</body>
</html>
