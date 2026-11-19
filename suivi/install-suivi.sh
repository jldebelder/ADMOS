#!/bin/bash
# =============================================================================
# install-suivi.sh — serveur de suivi des labos (VM de l'enseignant sur vmbr0)
# EAFC Uccle — Logiciel open source 2026-2027 — Jean-Louis De Belder
#
# À lancer en root, sur une VM Debian 13 de l'enseignant, dans le réseau 172.17.0.0/16
# (vmbr0, sans VLAN), joignable par les routeurs des étudiants :
#
#     bash install-suivi.sh [--classe classe.csv] [--cron 17:45]
#
# Ce que fait le script :
#   - installe Apache2 + PHP et publie le tableau de bord sur http://<cette VM>/suivi/ ;
#   - crée /var/lib/suivi (résultats, classe.csv, clé SSH de relève) ;
#   - demande le mot de passe du tableau de bord (la première fois, ou avec --mot-de-passe) ;
#   - génère la clé SSH de relève et l'affiche : à coller dans verif/cle_enseignant.pub.
#
# Options :
#   --classe FICHIER     copie la liste de la classe (id;nom;prenom;wan;classe) dans /var/lib/suivi/classe.csv
#   --cron HH:MM         relève complète de la classe du lundi au vendredi à cette heure,
#                        + relance toutes les heures (8h-19h) pour les étudiants sans réponse
#   --mot-de-passe       changer le mot de passe du tableau de bord
# =============================================================================
set -eu
export PATH=/usr/sbin:/sbin:/usr/bin:/bin

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WEB=/var/www/suivi
DATA=/var/lib/suivi
CLASSE=""; CRON=""; MDP=0

msg()   { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
avert() { printf '\033[1;33m!!\033[0m  %s\n' "$*"; }
err()   { printf '\033[1;31mERREUR\033[0m %s\n' "$*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --classe) CLASSE="${2:-}"; shift ;;
    --cron) CRON="${2:-}"; shift ;;
    --mot-de-passe) MDP=1 ;;
    -h|--aide|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) err "Option inconnue : $1"; exit 2 ;;
  esac
  shift
done
[ "$(id -u)" -eq 0 ] || { err "À lancer en root : su -  puis  bash install-suivi.sh"; exit 1; }
[ -f "$DIR/site/index.php" ] || { err "Dossier site/ introuvable à côté du script ($DIR)."; exit 1; }
if [ -n "$CRON" ] && ! [[ "$CRON" =~ ^([01]?[0-9]|2[0-3]):[0-5][0-9]$ ]]; then err "--cron attend HH:MM (ex. 17:45)"; exit 2; fi

msg "Paquets : Apache2, PHP, client SSH, cron"
apt-get update -qq >/dev/null 2>&1 || true
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq apache2 php libapache2-mod-php php-cli php-mbstring openssh-client cron >/dev/null \
  || { err "Installation des paquets impossible : vérifier l'accès Internet."; exit 1; }

msg "Site : $WEB"
rm -rf "$WEB"; mkdir -p "$WEB"
cp -r "$DIR/site/." "$WEB/"
chown -R root:root "$WEB"
find "$WEB" -type d -exec chmod 755 {} +
find "$WEB" -type f -exec chmod 644 {} +
cat > /etc/apache2/conf-available/suivi.conf <<EOF
# Serveur de suivi des labos (ADMOS)
Alias /suivi $WEB
<Directory $WEB>
    Options -Indexes
    AllowOverride None
    Require all granted
    <FilesMatch "^(commun|config|releve)\.php$">
        Require all denied
    </FilesMatch>
</Directory>
EOF
a2enconf -q suivi >/dev/null
systemctl reload apache2 2>/dev/null || systemctl restart apache2

msg "Données : $DATA"
install -d -m 750 -o www-data -g www-data "$DATA" "$DATA/resultats" "$DATA/envois"
install -d -m 700 -o www-data -g www-data "$DATA/ssh"
if [ -n "$CLASSE" ]; then
  [ -f "$CLASSE" ] || { err "Fichier introuvable : $CLASSE"; exit 1; }
  install -m 640 -o root -g www-data "$CLASSE" "$DATA/classe.csv"
  msg "Classe copiée : $(grep -cE '^[0-9]+;' "$DATA/classe.csv") étudiant(s)"
elif [ ! -f "$DATA/classe.csv" ]; then
  install -m 640 -o root -g www-data "$DIR/classe.exemple.csv" "$DATA/classe.csv"
  avert "classe.csv d'exemple installé : remplacez-le (bash install-suivi.sh --classe <fichier>)."
fi

if [ ! -f "$DATA/acces.php" ] || [ "$MDP" -eq 1 ]; then
  msg "Mot de passe du tableau de bord"
  while true; do
    read -r -s -p "  Mot de passe : " p1; echo
    read -r -s -p "  Encore une fois : " p2; echo
    [ -n "$p1" ] && [ "$p1" = "$p2" ] && break
    avert "Vide ou différent : recommencez."
  done
  H=$(P="$p1" php -r 'echo password_hash(getenv("P"), PASSWORD_DEFAULT);')
  printf "<?php\nreturn ['mot_de_passe' => '%s'];\n" "$H" > "$DATA/acces.php"
  chown root:www-data "$DATA/acces.php"; chmod 640 "$DATA/acces.php"
  unset p1 p2
fi

if [ ! -f "$DATA/ssh/id_ed25519" ]; then
  msg "Clé SSH de relève (propre à ce serveur)"
  runuser -u www-data -- ssh-keygen -q -t ed25519 -N '' -C "suivi-admos@$(hostname)" -f "$DATA/ssh/id_ed25519"
fi

if [ -n "$CRON" ]; then
  {
    echo "${CRON#*:} ${CRON%%:*} * * 1-5 www-data /usr/bin/php $WEB/releve.php --labo tout > $DATA/releve.log 2>&1"
    # Relance : une machine qui n'a jamais répondu est réinterrogée chaque heure. L'heure est
    # choisie APRÈS celle de maj-labos.sh sur les nœuds Proxmox (install-maj-node.sh, 10 par
    # défaut) : la machine étudiante est d'abord mise à jour, puis elle répond à la relève.
    echo "35 8-19 * * 1-5 www-data /usr/bin/php $WEB/releve.php --labo tout --non-releves > $DATA/relance.log 2>&1"
  } > /etc/cron.d/suivi-releve
  chmod 644 /etc/cron.d/suivi-releve
  systemctl enable --now cron >/dev/null 2>&1 || service cron start >/dev/null 2>&1 || true
  if ! systemctl is-active --quiet cron 2>/dev/null; then
    avert "Le service cron n'a pas démarré : la relève automatique ne sera pas lancée."
  fi
  msg "Relève complète : du lundi au vendredi à $CRON (heure du serveur : $(date '+%Z'))"
  msg "Relance automatique : toutes les heures de 8h à 19h les jours de cours, seulement les étudiants qui n'ont jamais répondu"
fi

IP=$(ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')
echo
msg "Terminé. Tableau de bord : http://${IP:-<adresse de cette VM>}/suivi/"
cat <<EOF

À faire UNE fois, puis à chaque nouvelle clé :

  1. Coller cette ligne dans ADMOS/verif/cle_enseignant.pub (dépôt GitHub) :

     $(cat "$DATA/ssh/id_ed25519.pub")

  2. Dans ADMOS/verif/site/config.php, vérifier l'adresse d'envoi :
         'suivi_url' => 'http://${IP:-<adresse de cette VM>}/suivi/recevoir.php',
     puis publier le dépôt (git commit + git push).

  3. Chaque étudiant fait sur dupont-pc PUIS sur dupont-routeur :
         cd ADMOS && git pull && cd verif && bash install-prof.sh

  4. Relève : bouton « Relever toute la classe », ou
         sudo -u www-data php $WEB/releve.php [--labo 05] [--etudiant 3]
EOF
