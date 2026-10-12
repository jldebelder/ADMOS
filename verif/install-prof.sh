#!/bin/bash
# =============================================================================
# install-prof.sh — installe le contrôle de labo sur UNE machine
# EAFC Uccle — Logiciel open source 2026-2027 — Jean-Louis De Belder
#
# À lancer en root, d'abord sur dupont-pc, ensuite sur dupont-routeur :
#
#     bash install-prof.sh
#
# Ce que fait le script :
#   - installe /usr/local/sbin/verif-lab (contrôle en lecture seule) ;
#   - crée le compte « prof » : pas de mot de passe, connexion par clé SSH
#     uniquement, et cette clé ne peut lancer QUE verif-lab (restrict + command=) ;
#   - sur dupont-pc : génère la clé du site, installe le site dans
#     /var/www/eafc.lab/html/verif/ et teste la connexion ;
#   - sur dupont-routeur : récupère la clé publique du PC (http://10.68.69.10/verif/cle.pub).
#
# Options :
#   --role pc|routeur       forcer le rôle (sinon : détecté par l'adresse IP)
#   --cle "ssh-ed25519 …"   (routeur) clé publique du site, si le PC n'est pas joignable en HTTP
#   --cle-fichier FICHIER   (routeur) idem, depuis un fichier
# =============================================================================
set -eu
export PATH=/usr/sbin:/sbin:/usr/bin:/bin

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
IP_ROUTEUR="10.68.69.1"
IP_PC="10.68.69.10"
DOCROOT="/var/www/eafc.lab/html"
ETAT="/var/lib/verif"
CMD_FORCEE='sudo -n /usr/local/sbin/verif-lab'
ROLE=""; CLE=""; CLE_FICHIER=""

msg() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
avert() { printf '\033[1;33m!!\033[0m  %s\n' "$*"; }
err() { printf '\033[1;31mERREUR\033[0m %s\n' "$*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --role) ROLE="${2:-}"; shift ;;
    --cle) CLE="${2:-}"; shift ;;
    --cle-fichier) CLE_FICHIER="${2:-}"; shift ;;
    -h|--aide|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) err "Option inconnue : $1"; exit 2 ;;
  esac
  shift
done

[ "$(id -u)" -eq 0 ] || { err "À lancer en root : su -  puis  bash install-prof.sh"; exit 1; }
[ -f "$DIR/verif-lab.sh" ] || { err "verif-lab.sh introuvable à côté de install-prof.sh ($DIR)."; exit 1; }

# ------------------------------- rôle ----------------------------------------
if [ -z "$ROLE" ]; then
  if   ip -4 -o addr show 2>/dev/null | grep -q " ${IP_ROUTEUR//./\\.}/"; then ROLE="routeur"
  elif ip -4 -o addr show 2>/dev/null | grep -q " ${IP_PC//./\\.}/";      then ROLE="pc"
  else
    err "Cette machine n'a ni 10.68.69.1 (routeur) ni 10.68.69.10 (PC)."
    err "Vérifiez l'adresse IP, ou précisez : bash install-prof.sh --role pc   (ou routeur)"
    exit 1
  fi
fi
case "$ROLE" in routeur|pc) ;; *) err "Rôle inconnu : $ROLE"; exit 2 ;; esac
msg "Machine détectée : $ROLE"

# ----------------------------- paquets ---------------------------------------
APT_OK=0
paquet() { # commande  paquet
  command -v "$1" >/dev/null 2>&1 && return 0
  if [ "$APT_OK" -eq 0 ]; then apt-get update -qq >/dev/null 2>&1 || true; APT_OK=1; fi
  msg "Installation du paquet $2…"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$2" >/dev/null 2>&1 \
    || { err "Impossible d'installer $2 : vérifiez l'accès Internet (ping 8.8.8.8, apt update)."; exit 1; }
}
paquet sudo sudo
paquet visudo sudo
if [ "$ROLE" = "pc" ]; then
  paquet ssh-keygen openssh-client
  paquet ssh openssh-client
fi
if [ "$ROLE" = "routeur" ] && [ -z "$CLE" ] && [ -z "$CLE_FICHIER" ]; then
  paquet curl curl
fi

# ------------------------- script de contrôle --------------------------------
msg "Installation de /usr/local/sbin/verif-lab"
install -o root -g root -m 755 "$DIR/verif-lab.sh" /usr/local/sbin/verif-lab

# ------------------------------ compte prof ----------------------------------
if id prof >/dev/null 2>&1; then
  msg "Le compte prof existe déjà : mise à jour."
else
  msg "Création du compte prof (sans mot de passe)"
  useradd -m -s /bin/bash -c "Compte de vérification (enseignant)" prof
fi
usermod -p '*' prof                       # aucun mot de passe : connexion par clé uniquement
HOME_PROF=$(getent passwd prof | cut -d: -f6)

msg "Droits sudo limités à verif-lab, sans argument"
SUDOERS=/etc/sudoers.d/prof-verif
TMP=$(mktemp)
cat > "$TMP" <<'EOF'
# Le compte prof ne peut lancer que le script de contrôle, sans argument.
prof ALL=(root) NOPASSWD: /usr/local/sbin/verif-lab ""
EOF
if visudo -cf "$TMP" >/dev/null 2>&1; then
  install -o root -g root -m 440 "$TMP" "$SUDOERS"; rm -f "$TMP"
else
  rm -f "$TMP"; err "Fichier sudoers invalide : abandon (rien n'a été activé)."; exit 1
fi

# ------------------------- clés autorisées pour prof -------------------------
KEYS=()
cle_valide() { [[ "$1" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+)\ [A-Za-z0-9+/=]+(\ [^\"]*)?$ ]]; }

if [ "$ROLE" = "pc" ]; then
  msg "Clé SSH du site (propre à votre machine, jamais publiée)"
  install -d -m 750 -o www-data -g www-data "$ETAT"
  if [ ! -f "$ETAT/id_ed25519" ]; then
    ssh-keygen -q -t ed25519 -N '' -C "verif-site@$(hostname)" -f "$ETAT/id_ed25519"
  fi
  chown www-data:www-data "$ETAT/id_ed25519" "$ETAT/id_ed25519.pub"
  chmod 600 "$ETAT/id_ed25519"; chmod 644 "$ETAT/id_ed25519.pub"
  KEYS+=("$(cut -d' ' -f1-3 "$ETAT/id_ed25519.pub")")
else
  if [ -n "$CLE_FICHIER" ]; then CLE=$(head -n1 "$CLE_FICHIER"); fi
  if [ -z "$CLE" ]; then
    msg "Récupération de la clé publique du site sur dupont-pc"
    CLE=$(curl -fsS --max-time 8 -H 'Host: eafc.lab' "http://${IP_PC}/verif/cle.pub" 2>/dev/null | head -n1 || true)
  fi
  if ! cle_valide "$CLE"; then
    err "Clé publique du site introuvable. Faites d'abord  bash install-prof.sh  sur dupont-pc,"
    err "puis vérifiez  curl -I -H 'Host: eafc.lab' http://10.68.69.10/verif/cle.pub  (200 attendu)."
    err "Sinon : sur dupont-pc  cat /var/lib/verif/id_ed25519.pub  puis ici  bash install-prof.sh --cle \"<la ligne>\""
    exit 1
  fi
  KEYS+=("$CLE")
fi

# Clé facultative de l'enseignant (fichier cle_enseignant.pub du dépôt)
if [ -f "$DIR/cle_enseignant.pub" ]; then
  while IFS= read -r l || [ -n "$l" ]; do
    if cle_valide "$l"; then KEYS+=("$l"); msg "Clé enseignant ajoutée."; fi
  done < "$DIR/cle_enseignant.pub"
fi

install -d -m 700 -o prof -g prof "$HOME_PROF/.ssh"
AK="$HOME_PROF/.ssh/authorized_keys"
: > "$AK"
for k in "${KEYS[@]}"; do
  printf 'restrict,command="%s" %s\n' "$CMD_FORCEE" "$k" >> "$AK"
done
chown prof:prof "$AK"; chmod 600 "$AK"
msg "${#KEYS[@]} clé(s) autorisée(s) pour prof (restrict + commande imposée)"

# ------------------------------ site (PC) ------------------------------------
if [ "$ROLE" = "pc" ]; then
  if [ ! -d "$DOCROOT" ]; then
    avert "$DOCROOT n'existe pas encore (labo Apache, étape 3) : je le crée."
    mkdir -p "$DOCROOT"
  fi
  msg "Installation du site dans $DOCROOT/verif/"
  rm -rf "$DOCROOT/verif"
  mkdir -p "$DOCROOT/verif"
  cp -r "$DIR/site/." "$DOCROOT/verif/"
  cp "$ETAT/id_ed25519.pub" "$DOCROOT/verif/cle.pub"
  chown -R root:root "$DOCROOT/verif"
  find "$DOCROOT/verif" -type d -exec chmod 755 {} +
  find "$DOCROOT/verif" -type f -exec chmod 644 {} +

  command -v php >/dev/null 2>&1 || avert "PHP n'est pas installé : apt install php libapache2-mod-php (labo Apache, étape 3)."
  dpkg -s apache2 >/dev/null 2>&1 || avert "Apache2 n'est pas installé : le site ne sera pas servi (labo Apache)."

  msg "Test de la connexion du site vers prof"
  CIBLE="127.0.0.1"
  if ip -4 -o addr show 2>/dev/null | grep -q " ${IP_PC//./\\.}/"; then CIBLE="$IP_PC"; fi
  if runuser -u www-data -- env HOME="$ETAT" ssh -T -i "$ETAT/id_ed25519" \
       -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
       -o UserKnownHostsFile="$ETAT/known_hosts" -o LogLevel=ERROR "prof@$CIBLE" verif 2>/dev/null | grep -q '^CHECK'; then
    msg "Test réussi : le site peut contrôler cette machine."
  else
    avert "Le test SSH a échoué (sshd actif ? port 22 autorisé ? AllowUsers dans sshd_config ?)."
    avert "Le contrôle reste utilisable en console : verif-lab --texte"
  fi
fi

# ------------------------------- fin -----------------------------------------
echo
msg "Terminé."
if [ "$ROLE" = "pc" ]; then
  cat <<EOF

Prochaines étapes :
  1. Sur dupont-routeur : cloner ADMOS, puis   cd ADMOS/verif && bash install-prof.sh
  2. Sur le poste graphique dupont-gui (dans le LAN 10.68.69.0/24), ouvrir  http://eafc.lab/verif/
     et cliquer sur « Lancer la vérification »
  3. Sans poste graphique :  verif-lab --texte   (rapport dans la console)
EOF
else
  cat <<EOF

Ouvrez le site http://eafc.lab/verif/ depuis dupont-gui (ou lancez  verif-lab --texte  ici).
EOF
fi
