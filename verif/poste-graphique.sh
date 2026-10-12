#!/bin/bash
# =============================================================================
# poste-graphique.sh — poste Debian avec bureau, branché dans le LAN 10.68.69.0/24
# EAFC Uccle — Logiciel open source 2026-2027 — Jean-Louis De Belder
#
# Ce poste sert uniquement de NAVIGATEUR pour ouvrir le site de contrôle
# (http://eafc.lab/verif/ sur dupont-pc). Il ne contient rien d'autre.
#
#   bash poste-graphique.sh           (root, UNE fois sur le modèle) prépare le poste :
#                                       - eafc.lab -> 10.68.69.10 dans /etc/hosts
#                                       - page d'accueil de Firefox = le site de contrôle
#                                       - lanceur « Contrôle du labo » dans le menu
#   poste-graphique --test            diagnostic (sans root ; ou bash poste-graphique.sh --test) : adresse reçue en DHCP,
#                                       ping routeur / PC / Internet, eafc.lab, site de contrôle
#
# Les adresses étant identiques dans le LAN de chaque étudiant, UN SEUL modèle de
# poste graphique sert pour toute la classe.
# =============================================================================
set -u
export PATH=/usr/sbin:/sbin:/usr/bin:/bin
IP_ROUTEUR="10.68.69.1"
IP_PC="10.68.69.10"
URL="http://eafc.lab/verif/"

msg()   { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
avert() { printf '\033[1;33m!!\033[0m  %s\n' "$*"; }

# ------------------------------- diagnostic ----------------------------------
if [ "${1:-}" = "--test" ]; then
  n_ko=0
  ok() { printf ' \033[32m[ OK ]\033[0m %s\n' "$*"; }
  ko() { printf ' \033[31m[ KO ]\033[0m %s\n        \033[33m→ %s\033[0m\n' "$1" "$2"; n_ko=$((n_ko+1)); }

  ADDR=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | grep '^10\.68\.69\.' | head -n1)
  if [ -n "$ADDR" ]; then
    last=${ADDR%%/*}; last=${last##*.}
    if [ "$last" -ge 100 ] && [ "$last" -le 200 ]; then ok "Adresse reçue par DHCP : $ADDR (plage .100 à .200)"
    else ok "Adresse dans le LAN : $ADDR (hors de la plage DHCP .100–.200 : adresse fixe ?)"; fi
  else
    ko "Aucune adresse 10.68.69.x" "Carte réseau sur vmbr1 avec le MÊME VLAN Tag que dupont-pc ? dnsmasq tourne sur le routeur ? (systemctl status dnsmasq)"
  fi
  gw=$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')
  if [ "$gw" = "$IP_ROUTEUR" ]; then ok "Passerelle : $gw"; else ko "Passerelle : ${gw:-aucune}" "dhcp-option=3,10.68.69.1 sur le routeur (labo DHCP)"; fi
  ping -c1 -W2 "$IP_ROUTEUR" >/dev/null 2>&1 && ok "Le routeur répond ($IP_ROUTEUR)" || ko "Le routeur ne répond pas" "VLAN Tag différent de celui du routeur ? adresse LAN du routeur ?"
  ping -c1 -W2 "$IP_PC" >/dev/null 2>&1 && ok "dupont-pc répond ($IP_PC)" || ko "dupont-pc ne répond pas" "dupont-pc est-elle démarrée, avec 10.68.69.10 ? iptables autorise-t-il le ping (-p icmp) ?"
  ping -c1 -W2 8.8.8.8 >/dev/null 2>&1 && ok "Internet répond (8.8.8.8)" || ko "Internet ne répond pas" "NAT du routeur : ip_forward et MASQUERADE (labo routage)"
  res=$(getent hosts eafc.lab | awk '{print $1; exit}')
  [ "$res" = "$IP_PC" ] && ok "eafc.lab → $res" || ko "eafc.lab → ${res:-inconnu}" "en root : poste-graphique (ajoute la ligne dans /etc/hosts)"
  code=$(timeout 6 bash -c 'exec 3<>/dev/tcp/10.68.69.10/80 && printf "HEAD /verif/ HTTP/1.0\r\nHost: eafc.lab\r\nConnection: close\r\n\r\n" >&3 && head -n1 <&3' 2>/dev/null | awk '{print $2}')
  if [[ "$code" =~ ^[23] ]]; then ok "Le site de contrôle répond : $URL (HTTP $code)"
  else ko "Le site de contrôle ne répond pas (${code:-aucune réponse})" "bash install-prof.sh sur dupont-pc (étape 4) ; Apache et iptables (port 80) sur dupont-pc"; fi
  echo
  [ "$n_ko" -eq 0 ] && msg "Tout est en ordre : ouvrez $URL dans Firefox." || avert "$n_ko point(s) à corriger."
  exit 0
fi

# ------------------------------ préparation ----------------------------------
[ "$(id -u)" -eq 0 ] || { echo "À lancer en root : su -  puis  bash poste-graphique.sh   (ou --test sans root)" >&2; exit 1; }

msg "eafc.lab → $IP_PC dans /etc/hosts"
sed -i '/[[:space:]]eafc\.lab\([[:space:]]\|$\)/d' /etc/hosts
printf '%s  eafc.lab\n' "$IP_PC" >> /etc/hosts

if ! command -v firefox-esr >/dev/null 2>&1 && ! command -v firefox >/dev/null 2>&1; then
  msg "Installation de Firefox"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq firefox-esr >/dev/null 2>&1 \
    || avert "Firefox n'a pas pu être installé : apt install firefox-esr"
fi

msg "Page d'accueil de Firefox : $URL"
install -d -m 755 /etc/firefox/policies
cat > /etc/firefox/policies/policies.json <<EOF
{
  "policies": {
    "Homepage": { "URL": "$URL", "StartPage": "homepage" }
  }
}
EOF

msg "Lanceur « Contrôle du labo » dans le menu des applications"
cat > /usr/share/applications/controle-labo.desktop <<EOF
[Desktop Entry]
Type=Application
Name=Contrôle du labo
Comment=Ouvrir le site de contrôle des labos
Exec=sh -c "firefox-esr $URL || firefox $URL"
Icon=web-browser
Terminal=false
Categories=Network;WebBrowser;
EOF

install -o root -g root -m 755 "$(readlink -f "$0")" /usr/local/bin/poste-graphique
msg "Diagnostic disponible sur chaque clone : poste-graphique --test"

echo
msg "Poste prêt. Éteignez la VM puis convertissez-la en modèle (ex. template-debian13-gui)."
cat <<EOF

Rappels pour le modèle :
  - réseau en DHCP (NetworkManager), une seule carte ;
  - sur chaque clone : carte sur vmbr1 avec le VLAN Tag de l'étudiant (celui de dupont-pc) ;
  - test sur un clone :  poste-graphique --test
EOF
