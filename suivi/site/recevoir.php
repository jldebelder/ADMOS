<?php
// Réception d'un résultat envoyé par le site de contrôle d'un étudiant (POST JSON).
// L'étudiant est reconnu à l'adresse source : celle du WAN de son routeur (NAT), lue dans classe.csv.
// Réponse texte : « OK … » ou un message d'erreur court (affiché sur le site de l'étudiant).
require __DIR__ . '/commun.php';
header('Content-Type: text/plain; charset=UTF-8');

function fin($code, $texte) { http_response_code($code); echo $texte . "\n"; exit; }

$ip = isset($_SERVER['REMOTE_ADDR']) ? $_SERVER['REMOTE_ADDR'] : '';
$autorise = false;
foreach ($CFG['reseaux_envoi'] as $cidr) { if (ip_dans_reseau($ip, $cidr)) { $autorise = true; break; } }
if (!$autorise) { fin(403, 'adresse non autorisée'); }
if (($_SERVER['REQUEST_METHOD'] ?? 'GET') !== 'POST') { fin(405, 'POST uniquement'); }

// Limite de fréquence par adresse
$marque = chemin($CFG, 'envois/' . preg_replace('/[^0-9a-f.:]/i', '_', $ip));
if (!is_dir(dirname($marque))) { @mkdir(dirname($marque), 0750, true); }
if (is_file($marque) && time() - filemtime($marque) < (int)$CFG['envoi_delai']) { fin(429, 'trop fréquent'); }
@touch($marque);

$corps = file_get_contents('php://input', false, null, 0, (int)$CFG['envoi_max'] + 1);
if ($corps === false || strlen($corps) > (int)$CFG['envoi_max']) { fin(413, 'envoi trop gros'); }
$d = json_decode($corps, true);
if (!is_array($d)) { fin(400, 'JSON illisible'); }
$run = nettoyer($d);
if ($run === null || !$run['machines']) { fin(400, 'aucune machine dans le résultat'); }
$run['ip'] = $ip;

$classe = classe($CFG);
$id = etudiant_par_ip($classe, $ip);
if ($id === null) {
    $id = 'inconnu-' . $ip;           // visible dans le tableau de bord : compléter classe.csv
}
$nom = enregistrer($CFG, $id, 'site', $run);
if ($nom === false) { fin(500, 'enregistrement impossible (droits de ' . $CFG['donnees'] . ')'); }
echo 'OK ' . (isset($classe[$id]) ? $classe[$id]['prenom'] . ' ' . $classe[$id]['nom'] : $id) . "\n";
