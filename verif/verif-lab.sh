#!/bin/bash
# =============================================================================
# verif-lab — contrôle EN LECTURE SEULE d'un laboratoire (routeur ou PC)
# EAFC Uccle — Logiciel open source 2026-2027 — Jean-Louis De Belder
#
# Ce script ne modifie rien : il lit la configuration et l'état de la machine,
# puis affiche un rapport.
#
#   verif-lab --texte     rapport lisible dans la console (à lancer en root)
#   verif-lab             rapport au format TSV, lu par le site (via SSH, compte prof)
#   verif-lab --role pc|routeur   force le rôle (sinon : détecté par l'adresse IP)
# =============================================================================
set -u
umask 077
export PATH=/usr/sbin:/sbin:/usr/bin:/bin
export LC_ALL=C.UTF-8 LANG=C.UTF-8

VERSION="1.0"
MODE="tsv"
ROLE=""
IP_ROUTEUR="10.68.69.1"
IP_PC="10.68.69.10"
DOCROOT_ATTENDU="/var/www/eafc.lab/html"

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --texte) MODE="texte" ;;
    --role)  ROLE="${2:-}"; shift ;;
    -h|--aide|--help) usage; exit 0 ;;
    *) echo "Option inconnue : $1" >&2; exit 2 ;;
  esac
  shift
done

if [ "$(id -u)" -ne 0 ]; then
  echo "verif-lab doit être lancé en root (su - ), ou par le compte prof via le site." >&2
  exit 1
fi

# ------------------------------- sortie --------------------------------------
declare -A COUNT=([OK]=0 [KO]=0 [WARN]=0 [INFO]=0)
SEC=""

if [ "$MODE" = "texte" ] && [ -t 1 ]; then
  G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[36m'; D=$'\e[2m'; N=$'\e[0m'; W=$'\e[1m'
else
  G=""; R=""; Y=""; B=""; D=""; N=""; W=""
fi

clean() { local s="$1"; s=${s//$'\t'/ }; s=${s//$'\r'/ }; s=${s//$'\n'/ }; printf '%s' "${s:0:400}"; }

meta() {
  if [ "$MODE" = "tsv" ]; then printf 'META\t%s\t%s\n' "$1" "$(clean "$2")"
  else printf '  %s%-14s%s %s\n' "$D" "$1" "$N" "$2"; fi
}

section() {
  SEC="$1"
  [ "$MODE" = "texte" ] && printf '\n%s== %s ==%s\n' "$W" "$SEC" "$N"
  return 0
}

emit() { # id statut libellé détail conseil
  local id="$1" st="$2" lab="$3" det="${4:-}" hint="${5:-}"
  COUNT[$st]=$(( ${COUNT[$st]} + 1 ))
  if [ "$MODE" = "tsv" ]; then
    printf 'CHECK\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(clean "$SEC")" "$id" "$st" "$(clean "$lab")" "$(clean "$det")" "$(clean "$hint")"
    return 0
  fi
  local tag col
  case "$st" in
    OK)   tag=" OK ";  col="$G" ;;
    KO)   tag=" KO ";  col="$R" ;;
    WARN) tag="WARN";  col="$Y" ;;
    *)    tag="INFO";  col="$B" ;;
  esac
  printf ' %s[%s]%s %s' "$col" "$tag" "$N" "$lab"
  [ -n "$det" ] && printf ' %s— %s%s' "$D" "$det" "$N"
  printf '\n'
  if [ -n "$hint" ] && { [ "$st" = "KO" ] || [ "$st" = "WARN" ]; }; then
    printf '        %s→ %s%s\n' "$Y" "$hint" "$N"
  fi
  return 0
}
ok()   { emit "$1" OK   "$2" "${3:-}" ""; }
ko()   { emit "$1" KO   "$2" "${3:-}" "${4:-}"; }
warn() { emit "$1" WARN "$2" "${3:-}" "${4:-}"; }
info() { emit "$1" INFO "$2" "${3:-}" ""; }

# ------------------------------- outils --------------------------------------
svc_active()  { systemctl is-active --quiet "$1" 2>/dev/null; }
svc_enabled() { [ "$(systemctl is-enabled "$1" 2>/dev/null)" = "enabled" ]; }
have()        { command -v "$1" >/dev/null 2>&1; }
ip_int()      { local a b c d; IFS=. read -r a b c d <<<"$1"; echo $(( (a<<24)|(b<<16)|(c<<8)|d )); }
valid_ip()    { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

ADDRS=$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $2" "$4}')   # "ens19 10.68.69.1/24"
iface_of_ip() { awk -v ip="$1" '{split($2,a,"/"); if (a[1]==ip) {print $1; exit}}' <<<"$ADDRS"; }
cidr_of_ip()  { awk -v ip="$1" '{split($2,a,"/"); if (a[1]==ip) {print $2; exit}}' <<<"$ADDRS"; }

ping_ok() { ping -c1 -W2 "$1" >/dev/null 2>&1; }

# ------------------------------- rôle ----------------------------------------
if [ -z "$ROLE" ]; then
  if   [ -n "$(iface_of_ip "$IP_ROUTEUR")" ]; then ROLE="routeur"
  elif [ -n "$(iface_of_ip "$IP_PC")" ];      then ROLE="pc"
  else
    case "$(hostname)" in *routeur*|*router*) ROLE="routeur" ;; *) ROLE="pc" ;; esac
  fi
fi
case "$ROLE" in routeur|pc) ;; *) echo "Rôle inconnu : $ROLE (routeur ou pc)" >&2; exit 2 ;; esac

# ------------------------------ Système --------------------------------------
chk_systeme() {
  section "Système"
  local h; h=$(hostname)
  if [[ "$h" =~ ^[a-z][a-z0-9]*-(routeur|pc)$ ]]; then
    ok sys.nom "Nom de machine conforme (prénom-rôle)" "$h"
  else
    warn sys.nom "Nom de machine conforme (prénom-rôle)" "nom actuel : $h" "Convention : dupont-routeur ou dupont-pc. hostnamectl set-hostname dupont-pc"
  fi
  local osname="" osver=""
  if [ -r /etc/os-release ]; then
    osname=$(. /etc/os-release; echo "${PRETTY_NAME:-inconnu}")
    osver=$(. /etc/os-release; echo "${VERSION_ID:-}")
  fi
  if [ "$osver" = "13" ]; then ok sys.debian "Debian 13 (trixie)" "$osname"
  else warn sys.debian "Debian 13 (trixie)" "système : ${osname:-inconnu}" "Les labos sont écrits pour Debian 13 : cloner le modèle template-debian13."; fi

  meta etudiant "${h%%-*}"
  meta hostname "$h"
  meta role "$ROLE"
  meta os "$osname"
  meta noyau "$(uname -r)"
  meta cpu "$(nproc 2>/dev/null) vCPU"
  meta ram "$(free -m 2>/dev/null | awk '/^Mem:/ {print $2" Mo (libre : "$7" Mo)"}')"
  meta disque "$(df -h / 2>/dev/null | awk 'NR==2 {print $3" utilisés sur "$2" ("$5")"}')"
  meta demarrage "$(uptime -s 2>/dev/null) ($(uptime -p 2>/dev/null))"
  meta adresses "$(ip -br -4 addr 2>/dev/null | awk '$1!="lo" {printf "%s %s  ", $1, $3}')"
}

# ------------------------- Routeur : routage et NAT --------------------------
chk_routage() {
  section "Routage et NAT"
  LAN_IF=$(iface_of_ip "$IP_ROUTEUR")
  WAN_IF=$(awk '$2 ~ /^172\.17\./ {print $1; exit}' <<<"$ADDRS")
  local wan_cidr; wan_cidr=$(awk '$2 ~ /^172\.17\./ {print $2; exit}' <<<"$ADDRS")
  local lan_cidr; lan_cidr=$(cidr_of_ip "$IP_ROUTEUR")

  if [ -z "$LAN_IF" ]; then
    ko r.lan "Carte LAN : 10.68.69.1/24" "adresse absente" "Labo routage, étape 2 : /etc/network/interfaces, puis systemctl restart networking"
  elif [ "${lan_cidr#*/}" = "24" ]; then
    ok r.lan "Carte LAN : 10.68.69.1/24" "interface $LAN_IF"
  else
    warn r.lan "Carte LAN : 10.68.69.1/24" "masque trouvé : /${lan_cidr#*/}" "Écrire address 10.68.69.1/24 dans /etc/network/interfaces"
  fi

  if [ -z "$WAN_IF" ]; then
    ko r.wan "Carte WAN : 172.17.X.Y/16" "aucune adresse 172.17.x.x" "Prendre l'adresse WAN du fichier xls (vmbr0, sans VLAN) dans /etc/network/interfaces"
  elif [ "${wan_cidr#*/}" = "16" ]; then
    ok r.wan "Carte WAN : 172.17.X.Y/16" "$wan_cidr sur $WAN_IF"
  else
    warn r.wan "Carte WAN : 172.17.X.Y/16" "$wan_cidr sur $WAN_IF" "Le masque du WAN est /16 : address 172.17.X.Y/16"
  fi
  if [ -n "$LAN_IF" ] && [ "$LAN_IF" = "$WAN_IF" ]; then
    ko r.cartes "Deux cartes distinctes (WAN et LAN)" "même interface : $LAN_IF" "Le routeur doit avoir deux cartes : net0 sur vmbr0 (WAN), net1 sur vmbr1 (LAN)."
  fi

  local defs n; defs=$(ip -4 route show default 2>/dev/null); n=$(grep -c . <<<"$defs")
  if [ "$n" -eq 0 ]; then
    ko r.gw "Route par défaut vers le WAN" "aucune route par défaut" "gateway uniquement sur la carte WAN (/etc/network/interfaces)"
  elif [ "$n" -gt 1 ]; then
    ko r.gw "Route par défaut vers le WAN" "$n routes par défaut" "Une seule ligne gateway, sur la carte WAN. Aucune passerelle sur la carte LAN."
  elif [ -n "$WAN_IF" ] && grep -q "dev $WAN_IF" <<<"$defs"; then
    ok r.gw "Route par défaut vers le WAN" "$(head -n1 <<<"$defs")"
  else
    ko r.gw "Route par défaut vers le WAN" "$(head -n1 <<<"$defs")" "La passerelle appartient à la carte WAN (vmbr0), pas à la carte LAN."
  fi

  if [ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" = "1" ]; then
    ok r.fwd "Routage IPv4 actif (ip_forward = 1)"
  else
    ko r.fwd "Routage IPv4 actif (ip_forward = 1)" "valeur actuelle : $(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" "sysctl -w net.ipv4.ip_forward=1 (labo routage, étape 3)"
  fi
  if grep -qsE '^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=[[:space:]]*1' /etc/sysctl.d/*.conf; then
    ok r.fwdperm "ip_forward permanent (/etc/sysctl.d/)"
  elif grep -qsE '^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=[[:space:]]*1' /etc/sysctl.conf; then
    ko r.fwdperm "ip_forward permanent (/etc/sysctl.d/)" "réglage dans /etc/sysctl.conf seulement" "Debian 13 ne lit plus /etc/sysctl.conf : echo \"net.ipv4.ip_forward=1\" > /etc/sysctl.d/99-routage.conf"
  else
    ko r.fwdperm "ip_forward permanent (/etc/sysctl.d/)" "aucun fichier ne le fixe" "echo \"net.ipv4.ip_forward=1\" > /etc/sysctl.d/99-routage.conf && sysctl --system"
  fi

  local nat; nat=$(iptables -t nat -S POSTROUTING 2>/dev/null)
  if [ -n "$WAN_IF" ] && grep -qE -- "-o ${WAN_IF} .*-j MASQUERADE" <<<"$nat"; then
    ok r.nat "NAT actif : MASQUERADE sur la carte WAN" "$WAN_IF"
  elif have nft && nft list ruleset 2>/dev/null | grep -q masquerade; then
    ok r.nat "NAT actif : masquerade (nftables)"
  elif grep -q MASQUERADE <<<"$nat"; then
    ko r.nat "NAT actif : MASQUERADE sur la carte WAN" "règle présente, mais pas sur ${WAN_IF:-la carte WAN}" "-o doit désigner la carte WAN : iptables -t nat -A POSTROUTING -o ${WAN_IF:-ens18} -j MASQUERADE"
  else
    ko r.nat "NAT actif : MASQUERADE sur la carte WAN" "aucune règle" "iptables -t nat -A POSTROUTING -o ${WAN_IF:-ens18} -j MASQUERADE (labo routage, étape 7)"
  fi
  if [ -n "$WAN_IF" ] && grep -qsE -- "-o ${WAN_IF} .*-j MASQUERADE" /etc/iptables/rules.v4; then
    if svc_enabled netfilter-persistent; then ok r.natperm "NAT sauvegardé (/etc/iptables/rules.v4)"
    else warn r.natperm "NAT sauvegardé (/etc/iptables/rules.v4)" "service netfilter-persistent non activé" "systemctl enable netfilter-persistent"; fi
  elif grep -qs masquerade /etc/nftables.conf && svc_enabled nftables; then
    ok r.natperm "NAT sauvegardé (/etc/nftables.conf)"
  else
    ko r.natperm "NAT sauvegardé (/etc/iptables/rules.v4)" "règle non sauvegardée : perdue au redémarrage" "apt install iptables-persistent puis netfilter-persistent save (étape 8)"
  fi

  if ping_ok 8.8.8.8; then ok r.inet "Le routeur joint Internet (ping 8.8.8.8)"
  else ko r.inet "Le routeur joint Internet (ping 8.8.8.8)" "pas de réponse" "ping de la passerelle WAN d'abord ; vérifier vmbr0 sans VLAN, adresse et gateway"; fi
  if timeout 5 getent hosts debian.org >/dev/null 2>&1; then ok r.dns "Résolution DNS (debian.org)"
  else ko r.dns "Résolution DNS (debian.org)" "échec" "echo \"nameserver <DNS>\" > /etc/resolv.conf (DNS donné par l'enseignant)"; fi
}

# --------------------------- Routeur : DHCP ----------------------------------
chk_dhcp() {
  section "DHCP (dnsmasq)"
  if ! have dnsmasq && ! dpkg -s dnsmasq >/dev/null 2>&1; then
    ko d.pkg "dnsmasq installé" "paquet absent" "apt install dnsmasq (labo DHCP, étape 1)"
    return 0
  fi
  ok d.pkg "dnsmasq installé"
  if svc_active dnsmasq; then ok d.actif "Service dnsmasq actif"
  else ko d.actif "Service dnsmasq actif" "$(systemctl is-active dnsmasq 2>&1)" "journalctl -u dnsmasq -n 20 ; corriger /etc/dnsmasq.conf puis systemctl restart dnsmasq"; fi
  if svc_enabled dnsmasq; then ok d.enabled "dnsmasq démarre au boot"
  else ko d.enabled "dnsmasq démarre au boot" "" "systemctl enable --now dnsmasq"; fi

  local cfg; cfg=$(cat /etc/dnsmasq.conf /etc/dnsmasq.d/*.conf 2>/dev/null | sed 's/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$')
  local ifc; ifc=$(grep -E '^interface=' <<<"$cfg" | head -n1 | cut -d= -f2)
  if [ -n "$ifc" ] && [ "$ifc" = "${LAN_IF:-ens19}" ] && grep -qE '^bind-(interfaces|dynamic)' <<<"$cfg"; then
    ok d.if "Limité à la carte LAN (interface= et bind-interfaces)" "interface=$ifc"
  elif [ -z "$ifc" ]; then
    ko d.if "Limité à la carte LAN (interface= et bind-interfaces)" "aucune ligne interface=" "Ajouter interface=${LAN_IF:-ens19} et bind-interfaces : sinon dnsmasq écoute aussi côté WAN."
  elif [ "$ifc" != "${LAN_IF:-ens19}" ]; then
    ko d.if "Limité à la carte LAN (interface= et bind-interfaces)" "interface=$ifc" "La carte LAN est ${LAN_IF:-ens19}, pas $ifc."
  else
    warn d.if "Limité à la carte LAN (interface= et bind-interfaces)" "bind-interfaces absent" "Ajouter bind-interfaces dans /etc/dnsmasq.conf"
  fi

  local rng a b; rng=$(grep -E '^dhcp-range=' <<<"$cfg" | head -n1 | cut -d= -f2)
  if [ -z "$rng" ]; then
    ko d.range "Plage DHCP 10.68.69.100 – 10.68.69.200" "aucune ligne dhcp-range" "dhcp-range=10.68.69.100,10.68.69.200,255.255.255.0,10m (étape 2)"
  else
    IFS=, read -r a b _ <<<"$rng"
    if ! valid_ip "$a" || ! valid_ip "$b"; then
      ko d.range "Plage DHCP 10.68.69.100 – 10.68.69.200" "syntaxe illisible : $rng" "Quatre valeurs : début,fin,masque,durée"
    elif [ "$a" = "10.68.69.100" ] && [ "$b" = "10.68.69.200" ]; then
      ok d.range "Plage DHCP 10.68.69.100 – 10.68.69.200" "$rng"
    elif [ "$(ip_int "$a")" -le "$(ip_int "$IP_ROUTEUR")" ] && [ "$(ip_int "$b")" -ge "$(ip_int "$IP_ROUTEUR")" ]; then
      ko d.range "Plage DHCP 10.68.69.100 – 10.68.69.200" "la plage contient 10.68.69.1 (le routeur) : $rng" "Commencer la plage plus loin : .100 – .200"
    elif [ "$(ip_int "$a")" -le "$(ip_int "$IP_PC")" ] && [ "$(ip_int "$b")" -ge "$(ip_int "$IP_PC")" ]; then
      warn d.range "Plage DHCP 10.68.69.100 – 10.68.69.200" "la plage contient 10.68.69.10, réservé au PC : $rng" "Plan du cours : .100 à .200 ; .2 à .99 restent libres pour les adresses réservées."
    else
      warn d.range "Plage DHCP 10.68.69.100 – 10.68.69.200" "plage différente du plan : $rng" "Plan du cours : 10.68.69.100,10.68.69.200"
    fi
    local lease; lease=$(cut -d, -f4 <<<"$rng")
    info d.bail "Durée du bail" "${lease:-non précisée} (le cours prévoit 10m pour le labo)"
  fi

  if grep -qE '^dhcp-option=(3|option:router),10\.68\.69\.1(,|$)' <<<"$cfg"; then ok d.gw "Option 3 : passerelle 10.68.69.1"
  else ko d.gw "Option 3 : passerelle 10.68.69.1" "absente ou incorrecte" "dhcp-option=3,10.68.69.1 (jamais l'adresse du WAN)"; fi
  local dns; dns=$(grep -E '^dhcp-option=(6|option:dns-server),' <<<"$cfg" | head -n1 | cut -d, -f2-)
  if [ -n "$dns" ]; then ok d.dns "Option 6 : serveur DNS" "$dns"
  else ko d.dns "Option 6 : serveur DNS" "absente" "dhcp-option=6,<DNS donné par l'enseignant>"; fi
  if grep -q '^dhcp-authoritative' <<<"$cfg"; then ok d.auth "dhcp-authoritative"
  else warn d.auth "dhcp-authoritative" "absente" "Ajouter dhcp-authoritative : dnsmasq est le seul serveur du réseau."; fi

  local ls; ls=$(ss -H -lunp 'sport = :67' 2>/dev/null)
  if [ -z "$ls" ]; then
    ko d.listen "dnsmasq écoute sur udp/67" "rien n'écoute" "systemctl status dnsmasq ; journalctl -u dnsmasq"
  elif [ -n "${WAN_IF:-}" ] && grep -qE "(172\.17\.|%${WAN_IF}:)" <<<"$ls"; then
    ko d.listen "dnsmasq écoute seulement côté LAN (udp/67)" "écoute aussi côté WAN" "interface=${LAN_IF:-ens19} et bind-interfaces, puis systemctl restart dnsmasq"
  elif grep -qE "(${IP_ROUTEUR//./\\.}:67|%${LAN_IF:-ens19}:67)" <<<"$ls"; then
    ok d.listen "dnsmasq écoute seulement côté LAN (udp/67)"
  else
    warn d.listen "dnsmasq écoute seulement côté LAN (udp/67)" "écoute sur toutes les interfaces ?" "Vérifier interface= et bind-interfaces"
  fi

  if grep -qE "^dhcp-host=.*10\.68\.69\.10(,|$)" <<<"$cfg"; then ok d.resa "Réservation dhcp-host pour 10.68.69.10"
  else ko d.resa "Réservation dhcp-host pour 10.68.69.10" "absente" "dhcp-host=<MAC du PC>,10.68.69.10,dupont-pc (labo DHCP, étape 7)"; fi
  local lf=/var/lib/misc/dnsmasq.leases
  if awk '$3=="10.68.69.10"{f=1} END{exit !f}' "$lf" 2>/dev/null; then
    ok d.lease "Un bail est enregistré pour 10.68.69.10"
  else
    warn d.lease "Un bail est enregistré pour 10.68.69.10" "aucun bail dans $lf" "Sur le PC : iface ens18 inet dhcp, puis systemctl restart networking (le bail dure 10 min)."
  fi
  # Poste client (ex. dupont-gui) : un bail dans la plage .100–.200 prouve que le DHCP sert un vrai client.
  local cli; cli=$(awk '{n=split($3,a,"."); if (n==4 && a[1]"."a[2]"."a[3]=="10.68.69" && a[4]>=100 && a[4]<=200) {printf "%s ", $3}}' "$lf" 2>/dev/null)
  if [ -n "${cli// /}" ]; then info d.client "Un poste client a obtenu une adresse de la plage" "$cli(poste graphique ?)"
  else info d.client "Un poste client a obtenu une adresse de la plage" "aucun bail dans .100–.200 (démarrez dupont-gui pour le vérifier)"; fi
}

# ----------------------------- PC : réseau -----------------------------------
chk_pc_reseau() {
  section "Réseau du PC"
  local pc_if cidr; pc_if=$(iface_of_ip "$IP_PC"); cidr=$(cidr_of_ip "$IP_PC")
  if [ -z "$pc_if" ]; then
    ko p.ip "Adresse 10.68.69.10/24" "adresses actuelles : $(awk '{printf "%s ", $2}' <<<"$ADDRS")" "Réservation DHCP (dhcp-host) ou adresse statique : le support utilise 10.68.69.10 partout."
  elif [ "${cidr#*/}" = "24" ]; then ok p.ip "Adresse 10.68.69.10/24" "interface $pc_if"
  else warn p.ip "Adresse 10.68.69.10/24" "masque trouvé : /${cidr#*/}" "Le LAN est un /24."; fi

  local gw; gw=$(ip -4 route show default 2>/dev/null | head -n1)
  if grep -q "via ${IP_ROUTEUR//./\\.}\b" <<<"$gw"; then ok p.gw "Passerelle par défaut : 10.68.69.1" "$gw"
  else ko p.gw "Passerelle par défaut : 10.68.69.1" "${gw:-aucune route par défaut}" "La passerelle est l'adresse LAN du routeur, jamais le firewall du labo."; fi

  local ns; ns=$(awk '$1=="nameserver"{printf "%s ", $2}' /etc/resolv.conf 2>/dev/null)
  if [ -n "$ns" ]; then ok p.dns "Serveur DNS configuré" "$ns"
  else ko p.dns "Serveur DNS configuré" "aucun nameserver dans /etc/resolv.conf" "Mode DHCP (option 6) ou echo \"nameserver <DNS>\" > /etc/resolv.conf"; fi

  if ping_ok "$IP_ROUTEUR"; then ok p.routeur "Le PC joint le routeur (ping 10.68.69.1)"
  else ko p.routeur "Le PC joint le routeur (ping 10.68.69.1)" "pas de réponse" "Même VLAN Tag sur net1 du routeur et net0 du PC ; vérifier les adresses."; fi
  if ping_ok 8.8.8.8; then ok p.inet "Le PC joint Internet (ping 8.8.8.8)"
  else ko p.inet "Le PC joint Internet (ping 8.8.8.8)" "pas de réponse" "Contrôler sur le routeur : ip_forward, règle MASQUERADE (labo routage)."; fi
  if timeout 5 getent hosts debian.org >/dev/null 2>&1; then ok p.nom "Résolution DNS (debian.org)"
  else ko p.nom "Résolution DNS (debian.org)" "échec" "Vérifier /etc/resolv.conf et l'option DHCP 6."; fi

  if grep -rqsE '^[[:space:]]*iface[[:space:]]+[^[:space:]]+[[:space:]]+inet[[:space:]]+dhcp' /etc/network/interfaces /etc/network/interfaces.d/; then
    ok p.dhcp "Carte du PC en DHCP (iface … inet dhcp)"
  else
    warn p.dhcp "Carte du PC en DHCP (iface … inet dhcp)" "adresse statique" "Labo DHCP, étape 5 : iface ens18 inet dhcp. La statique reste acceptable en secours."
  fi
}

# ------------------------------- PC : SSH ------------------------------------
chk_ssh() {
  section "SSH"
  local unit=ssh; svc_active ssh || { svc_active sshd && unit=sshd; }
  if svc_active "$unit"; then ok s.actif "Service SSH actif"
  else ko s.actif "Service SSH actif" "arrêté" "systemctl status ssh ; sshd -t pour vérifier la syntaxe"; fi
  if svc_enabled ssh || svc_enabled sshd || svc_enabled ssh.socket; then ok s.enabled "SSH démarre au boot"
  else warn s.enabled "SSH démarre au boot" "" "systemctl enable ssh"; fi

  local cfg; cfg=$(sshd -T 2>/dev/null)
  if [ -z "$cfg" ]; then
    warn s.cfg "Configuration SSH lisible (sshd -T)" "sshd -T n'a rien renvoyé" "Corriger /etc/ssh/sshd_config : sshd -t affiche l'erreur."
  else
    local v
    v=$(awk '$1=="permitrootlogin"{print $2}' <<<"$cfg")
    if [ "$v" = "no" ]; then ok s.root "PermitRootLogin no"
    else ko s.root "PermitRootLogin no" "valeur actuelle : $v" "Mettre PermitRootLogin no dans /etc/ssh/sshd_config, puis sshd -t et systemctl restart ssh"; fi
    v=$(awk '$1=="passwordauthentication"{print $2}' <<<"$cfg")
    if [ "$v" = "no" ]; then ok s.pwd "PasswordAuthentication no"
    else ko s.pwd "PasswordAuthentication no" "valeur actuelle : $v" "Après avoir testé la clé dans une seconde session : PasswordAuthentication no"; fi
    v=$(awk '$1=="maxauthtries"{print $2}' <<<"$cfg")
    if [ -n "$v" ] && [ "$v" -le 3 ] 2>/dev/null; then ok s.tries "MaxAuthTries 3" "valeur : $v"
    else ko s.tries "MaxAuthTries 3" "valeur actuelle : ${v:-?}" "MaxAuthTries 3 (le défaut est 6)"; fi
    v=$(awk '$1=="pubkeyauthentication"{print $2}' <<<"$cfg")
    if [ "$v" = "yes" ]; then ok s.pubkey "PubkeyAuthentication yes (clés acceptées)"
    else ko s.pubkey "PubkeyAuthentication yes (clés acceptées)" "valeur actuelle : $v" "PubkeyAuthentication no coupe l'authentification par clé : remettre yes (ou retirer la ligne)."; fi
  fi

  # Test réel : sshd propose-t-il encore le mot de passe ?
  if have ssh && svc_active "$unit"; then
    local out methods
    out=$(timeout 10 ssh -o BatchMode=yes -o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no \
          -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=5 \
          verif-test@127.0.0.1 true 2>&1 </dev/null)
    methods=$(grep -o 'Permission denied ([^)]*)' <<<"$out" | head -n1)
    if [ -z "$methods" ]; then
      info s.live "Test réel de sshd (mot de passe refusé ?)" "test non concluant"
    elif grep -qE 'password|keyboard-interactive' <<<"$methods"; then
      if [ "$(awk '$1=="passwordauthentication"{print $2}' <<<"$cfg")" = "no" ]; then
        warn s.live "sshd applique la configuration en cours" "le fichier dit non, mais sshd accepte encore le mot de passe" "Le service n'a pas été relancé : systemctl restart ssh"
      else
        ko s.live "Le mot de passe est refusé par sshd (test réel)" "$methods" "PasswordAuthentication no, puis systemctl restart ssh"
      fi
    else
      ok s.live "Le mot de passe est refusé par sshd (test réel)" "$methods"
    fi
  fi

  local users=0 ed=0 badperm=0 u uid home ak ssh_dir p1 p2
  while IFS=: read -r u _ uid _ _ home _; do
    { [ "$uid" -ge 1000 ] 2>/dev/null && [ "$u" != "nobody" ] && [ "$u" != "prof" ]; } || continue
    ak="$home/.ssh/authorized_keys"; ssh_dir="$home/.ssh"
    [ -s "$ak" ] || continue
    users=$((users+1))
    grep -q '^ssh-ed25519 \|^sk-ssh-ed25519' "$ak" && ed=$((ed+1))
    p1=$(stat -c %a "$ssh_dir"); p2=$(stat -c %a "$ak")
    if [ "$p1" != "700" ] || { [ "$p2" != "600" ] && [ "$p2" != "400" ]; }; then badperm=$((badperm+1)); fi
  done < /etc/passwd
  if [ "$users" -eq 0 ]; then
    ko s.cle "Clé publique déployée (authorized_keys)" "aucun utilisateur n'a de clé autorisée" "ssh-keygen -t ed25519 puis ssh-copy-id <utilisateur>@10.68.69.10"
  elif [ "$badperm" -gt 0 ]; then
    warn s.cle "Clé publique déployée, droits 700 / 600" "droits trop ouverts pour $badperm utilisateur(s)" "chmod 700 ~/.ssh ; chmod 600 ~/.ssh/authorized_keys"
  elif [ "$ed" -eq 0 ]; then
    warn s.cle "Clé publique déployée (ed25519)" "clé présente, mais pas de type ed25519" "ssh-keygen -t ed25519 est la recommandation actuelle."
  else
    ok s.cle "Clé publique ed25519 déployée, droits 700 / 600" "$users utilisateur(s)"
  fi
}

# --------------------------- PC : Apache2 et PHP -----------------------------
http_status() { # $1 = en-tête Host ; renvoie le code HTTP du port 80 local
  timeout 6 bash -c 'exec 3<>/dev/tcp/127.0.0.1/80 && printf "HEAD / HTTP/1.0\r\nHost: %s\r\nConnection: close\r\n\r\n" "$0" >&3 && head -n1 <&3' "$1" 2>/dev/null | awk '{print $2}'
}

chk_apache() {
  section "Apache2 et PHP"
  if ! dpkg -s apache2 >/dev/null 2>&1; then
    ko a.pkg "Apache2 installé" "paquet absent" "apt install apache2"
    return 0
  fi
  if svc_active apache2; then ok a.actif "Service apache2 actif"
  else ko a.actif "Service apache2 actif" "$(systemctl is-active apache2 2>&1)" "apache2ctl configtest ; journalctl -u apache2 -n 20"; fi
  if svc_enabled apache2; then ok a.enabled "apache2 démarre au boot"
  else warn a.enabled "apache2 démarre au boot" "" "systemctl enable apache2"; fi

  local ct; ct=$(apache2ctl configtest 2>&1)
  if grep -q 'Syntax OK' <<<"$ct"; then ok a.syntax "Configuration valide (apache2ctl configtest)"
  else ko a.syntax "Configuration valide (apache2ctl configtest)" "$(grep -v '^$' <<<"$ct" | head -n1)" "Corriger le fichier indiqué, puis apache2ctl configtest"; fi

  if apache2ctl -S 2>&1 | grep -q 'eafc\.lab'; then ok a.vhost "Virtual Host eafc.lab actif"
  else ko a.vhost "Virtual Host eafc.lab actif" "aucun site eafc.lab dans apache2ctl -S" "a2ensite eafc.lab.conf && systemctl reload apache2"; fi
  if [ -e /etc/apache2/sites-enabled/000-default.conf ]; then
    warn a.default "Site par défaut 000-default désactivé" "encore actif" "a2dissite 000-default.conf && systemctl reload apache2"
  else ok a.default "Site par défaut 000-default désactivé"; fi

  local dr; dr=$(grep -rhiE '^[[:space:]]*DocumentRoot' /etc/apache2/sites-enabled/ 2>/dev/null | awk '{print $2}' | tr -d '"' | grep -Fx "$DOCROOT_ATTENDU" | head -n1)
  if [ -n "$dr" ] && [ -d "$dr" ]; then ok a.docroot "DocumentRoot $DOCROOT_ATTENDU existe"
  elif [ -z "$dr" ]; then ko a.docroot "DocumentRoot $DOCROOT_ATTENDU" "non déclaré dans les sites activés" "DocumentRoot $DOCROOT_ATTENDU dans /etc/apache2/sites-available/eafc.lab.conf"
  else ko a.docroot "DocumentRoot $DOCROOT_ATTENDU existe" "dossier introuvable" "mkdir -p $DOCROOT_ATTENDU"; fi
  if [ -d "$DOCROOT_ATTENDU" ]; then
    if runuser -u www-data -- test -r "$DOCROOT_ATTENDU" -a -x "$DOCROOT_ATTENDU" 2>/dev/null; then
      ok a.droits "www-data peut lire le DocumentRoot"
    else
      ko a.droits "www-data peut lire le DocumentRoot" "accès refusé" "chmod -R 755 $DOCROOT_ATTENDU"
    fi
  fi

  local code; code=$(http_status eafc.lab)
  if [[ "$code" =~ ^[23] ]]; then ok a.http "eafc.lab répond sur le port 80" "HTTP $code"
  else ko a.http "eafc.lab répond sur le port 80" "${code:+HTTP $code}${code:-aucune réponse}" "systemctl status apache2 ; ss -tlnp | grep :80 ; DocumentRoot et droits"; fi
  if ss -H -ltn 'sport = :443' 2>/dev/null | grep -q .; then info a.https "HTTPS (port 443) en écoute" "bonus du cours : certificat auto-signé"
  else info a.https "HTTPS (port 443)" "non activé (bonus du cours : certificat auto-signé)"; fi

  if have php; then
    if apache2ctl -M 2>/dev/null | grep -qE 'php[0-9a-z_]*_module'; then
      ok a.php "PHP relié à Apache (mod_php)" "$(php -r 'echo PHP_VERSION;' 2>/dev/null)"
    elif apache2ctl -M 2>/dev/null | grep -q proxy_fcgi_module && systemctl list-units --type=service --state=active 2>/dev/null | grep -q 'php.*fpm'; then
      ok a.php "PHP relié à Apache (php-fpm)" "$(php -r 'echo PHP_VERSION;' 2>/dev/null)"
    else
      ko a.php "PHP relié à Apache" "PHP installé mais module Apache absent" "apt install libapache2-mod-php ; apache2ctl -M | grep php"
    fi
  else
    ko a.php "PHP installé et relié à Apache" "php absent" "apt install php libapache2-mod-php"
  fi

  local left=""
  if [ -d "$DOCROOT_ATTENDU" ]; then
    left=$(find "$DOCROOT_ATTENDU" -maxdepth 3 -type f \( -name 'info.php' -o -name 'phpinfo.php' -o -name 'test.php' -o -name 'i.php' \) -not -path '*/verif/*' 2>/dev/null | head -n3)
    left="$left"$'\n'$(grep -rlE 'phpinfo[[:space:]]*\(' --include='*.php' "$DOCROOT_ATTENDU" 2>/dev/null | grep -v '/verif/' | head -n3)
    left=$(grep -v '^$' <<<"$left" | sort -u | tr '\n' ' ')
  fi
  if [ -z "${left// /}" ]; then ok a.info "Aucun script de test PHP oublié (phpinfo)"
  else ko a.info "Aucun script de test PHP oublié (phpinfo)" "à supprimer : $left" "rm $DOCROOT_ATTENDU/info.php : phpinfo() révèle la version et les chemins à un attaquant."; fi
}

# ------------------------------ PC : iptables --------------------------------
chk_iptables() {
  section "iptables"
  local rules policy
  rules=$(iptables -S INPUT 2>/dev/null)
  policy=$(awk '$1=="-P" {print $3}' <<<"$rules")
  mapfile -t RULES < <(grep '^-A INPUT' <<<"$rules")
  local nr=${#RULES[@]}

  if [ "$nr" -eq 0 ] && [ "$policy" != "DROP" ] && have nft && nft list ruleset 2>/dev/null | grep -q 'hook input'; then
    chk_nft_input
    return 0
  fi
  if [ "$nr" -eq 0 ] && [ "$policy" != "DROP" ]; then
    ko f.regles "Politique de filtrage INPUT" "aucune règle : tout est ouvert" "Labo Apache, étape 4 : ESTABLISHED,RELATED, puis ports 22/80/443, puis DROP en dernier."
    return 0
  fi

  idx_of() { local i; for i in "${!RULES[@]}"; do if grep -qE -- "$1" <<<"${RULES[$i]}"; then echo "$i"; return 0; fi; done; return 1; }
  local pos_est pos_drop pos_all
  pos_est=$(idx_of 'ctstate (RELATED,ESTABLISHED|ESTABLISHED,RELATED) -j ACCEPT$|--state (RELATED,ESTABLISHED|ESTABLISHED,RELATED) -j ACCEPT$') || pos_est=""
  if [ -n "$pos_est" ]; then ok f.est "ESTABLISHED,RELATED accepté (retour des connexions)"
  else ko f.est "ESTABLISHED,RELATED accepté (retour des connexions)" "règle absente" "iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT"; fi

  local port miss="" last_acc=-1 pp
  for port in 22 80 443; do
    pp=$(idx_of "-p tcp .*(--dport ${port}( |\$)|--dports ([0-9:,]*,)?${port}(,[0-9:,]*)? ).*-j ACCEPT\$") || pp=""
    if [ -z "$pp" ]; then miss="$miss $port"; else [ "$pp" -gt "$last_acc" ] && last_acc=$pp; fi
  done
  if [ -z "$miss" ]; then ok f.ports "SSH (22), HTTP (80) et HTTPS (443) autorisés"
  else ko f.ports "SSH (22), HTTP (80) et HTTPS (443) autorisés" "port(s) non autorisé(s) :$miss" "iptables -A INPUT -p tcp --dport 22 -j ACCEPT (puis 80, puis 443)"; fi

  if idx_of '^-A INPUT -p icmp .*-j ACCEPT$' >/dev/null; then ok f.icmp "ICMP (ping) autorisé"
  else warn f.icmp "ICMP (ping) autorisé" "absent" "iptables -A INPUT -p icmp -j ACCEPT (le routeur ne pourra plus pinguer le PC)"; fi

  pos_all=$(idx_of '^-A INPUT -j ACCEPT$') || pos_all=""
  pos_drop=$(idx_of '^-A INPUT -j (DROP|REJECT)') || pos_drop=""
  if [ -n "$pos_all" ]; then
    ko f.drop "DROP en dernier, après les règles ACCEPT" "une règle ACCEPT sans condition ouvre tout (règle $((pos_all+1)))" "iptables -L INPUT --line-numbers puis iptables -D INPUT <n°>"
  elif [ -n "$pos_drop" ]; then
    if [ "$pos_drop" -eq $((nr-1)) ] && { [ -z "$pos_est" ] || [ "$pos_drop" -gt "$pos_est" ]; } && [ "$pos_drop" -gt "$last_acc" ]; then
      ok f.drop "DROP en dernier, après les règles ACCEPT" "règle $((pos_drop+1)) sur $nr"
    else
      ko f.drop "DROP en dernier, après les règles ACCEPT" "le DROP n'est pas la dernière règle" "L'ordre compte : la première règle qui correspond l'emporte. Supprimer puis ré-ajouter le DROP en fin de chaîne."
    fi
  elif [ "$policy" = "DROP" ]; then
    ok f.drop "Politique par défaut INPUT : DROP"
  else
    ko f.drop "DROP en dernier, après les règles ACCEPT" "politique $policy et aucune règle DROP finale" "iptables -A INPUT -j DROP, à écrire EN DERNIER"
  fi

  chk_iptables_perm "$policy"
}

chk_nft_input() {
  local rs; rs=$(nft list ruleset 2>/dev/null)
  if grep -q 'ct state .*established' <<<"$rs"; then ok f.est "ESTABLISHED,RELATED accepté (nftables)"
  else ko f.est "ESTABLISHED,RELATED accepté (nftables)" "règle absente" "ct state established,related accept"; fi
  local port miss=""
  for port in 22 80 443; do grep -qE "dport (\{[^}]*\b${port}\b[^}]*\}|${port})" <<<"$rs" || miss="$miss $port"; done
  if [ -z "$miss" ]; then ok f.ports "SSH (22), HTTP (80) et HTTPS (443) autorisés (nftables)"
  else ko f.ports "SSH (22), HTTP (80) et HTTPS (443) autorisés (nftables)" "port(s) manquant(s) :$miss" "tcp dport { 22, 80, 443 } accept"; fi
  if grep -qE 'hook input.*policy drop' <<<"$rs"; then ok f.drop "Politique par défaut INPUT : drop (nftables)"
  else ko f.drop "Politique par défaut INPUT : drop (nftables)" "policy drop absente" "type filter hook input priority 0; policy drop;"; fi
  if grep -q 'policy drop' /etc/nftables.conf 2>/dev/null && svc_enabled nftables; then ok f.perm "Règles permanentes (/etc/nftables.conf + service)"
  else ko f.perm "Règles permanentes (/etc/nftables.conf + service)" "fichier ou service absent" "systemctl enable --now nftables"; fi
}

chk_iptables_perm() {
  local policy="$1"
  if [ -f /etc/iptables/rules.v4 ]; then
    if grep -qE -- '--dport 22|--dports [0-9,]*22' /etc/iptables/rules.v4 && { grep -qE -- '^-A INPUT -j (DROP|REJECT)' /etc/iptables/rules.v4 || grep -q '^:INPUT DROP' /etc/iptables/rules.v4; }; then
      if svc_enabled netfilter-persistent; then ok f.perm "Règles sauvegardées (/etc/iptables/rules.v4)"
      else warn f.perm "Règles sauvegardées (/etc/iptables/rules.v4)" "service netfilter-persistent non activé" "systemctl enable netfilter-persistent"; fi
    else
      ko f.perm "Règles sauvegardées (/etc/iptables/rules.v4)" "le fichier ne contient pas la politique actuelle" "netfilter-persistent save (après avoir écrit toutes les règles)"
    fi
  else
    ko f.perm "Règles sauvegardées (/etc/iptables/rules.v4)" "fichier absent : tout disparaît au redémarrage" "apt install iptables-persistent puis netfilter-persistent save"
  fi
}

# ----------------------------- PC : fail2ban ---------------------------------
chk_fail2ban() {
  section "fail2ban"
  if ! dpkg -s fail2ban >/dev/null 2>&1; then
    ko j.pkg "fail2ban installé" "paquet absent" "apt install fail2ban"
    return 0
  fi
  if svc_active fail2ban; then ok j.actif "Service fail2ban actif"
  else ko j.actif "Service fail2ban actif" "$(systemctl is-active fail2ban 2>&1)" "journalctl -u fail2ban -n 20 ; fail2ban-client -t pour tester la configuration"; fi
  if svc_enabled fail2ban; then ok j.enabled "fail2ban démarre au boot"
  else ko j.enabled "fail2ban démarre au boot" "" "systemctl enable --now fail2ban"; fi

  if [ -f /etc/fail2ban/jail.local ]; then ok j.local "Configuration dans jail.local"
  else ko j.local "Configuration dans jail.local" "fichier absent" "Créer /etc/fail2ban/jail.local avec [sshd] enabled = true ; ne jamais modifier jail.conf."; fi
  if dpkg -V fail2ban 2>/dev/null | grep -q ' /etc/fail2ban/jail.conf$'; then
    warn j.conf "jail.conf non modifié" "jail.conf a été modifié" "Remettre jail.conf d'origine (apt install --reinstall -o Dpkg::Options::=--force-confask fail2ban) et utiliser jail.local."
  else ok j.conf "jail.conf non modifié"; fi

  if ! svc_active fail2ban; then return 0; fi
  if fail2ban-client status 2>/dev/null | grep -qE 'Jail list:.*\bsshd\b'; then
    ok j.jail "Jail sshd active"
    local mr bt ft
    mr=$(fail2ban-client get sshd maxretry 2>/dev/null); bt=$(fail2ban-client get sshd bantime 2>/dev/null); ft=$(fail2ban-client get sshd findtime 2>/dev/null)
    if [ -n "$mr" ] && [ "$mr" -ge 1 ] 2>/dev/null && [ "$mr" -le 10 ]; then ok j.maxretry "maxretry raisonnable" "$mr échecs tolérés"
    else warn j.maxretry "maxretry raisonnable" "valeur : ${mr:-?}" "maxretry = 5 (défaut Debian) ; 0 bannirait dès la première faute de frappe."; fi
    if [ -n "$bt" ] && [ "$bt" -ge 3600 ] 2>/dev/null; then ok j.bantime "bantime d'au moins 1 h" "${bt}s"
    elif [ "$bt" = "-1" ]; then warn j.bantime "bantime d'au moins 1 h" "bannissement permanent (-1)" "bantime = 1h ou 1d ; jamais -1 sans supervision."
    else warn j.bantime "bantime d'au moins 1 h" "valeur : ${bt:-?}s" "bantime = 1h (valeur du cours) : 10m est trop court."; fi
    info j.findtime "findtime" "${ft:-?}s (fenêtre de comptage des échecs)"
    if fail2ban-client get sshd ignoreip 2>/dev/null | grep -qE '10\.68\.69\.0/24|10\.68\.69\.0/16'; then
      ko j.ignore "ignoreip n'exempte pas le LAN" "tout le réseau 10.68.69.0/24 est exempté" "ignoreip = 127.0.0.1/8 seulement : sinon plus aucune protection pendant le labo."
    else ok j.ignore "ignoreip n'exempte pas le LAN"; fi
  else
    ko j.jail "Jail sshd active" "la jail sshd n'est pas chargée" "jail.local : [sshd] enabled = true, puis systemctl restart fail2ban"
  fi

  if iptables -S f2b-sshd >/dev/null 2>&1 || { have nft && nft list tables 2>/dev/null | grep -q f2b; }; then
    ok j.chain "Chaîne de blocage créée dans le pare-feu" "f2b-sshd"
  else
    warn j.chain "Chaîne de blocage créée dans le pare-feu" "aucune chaîne f2b trouvée" "fail2ban-client status sshd ; journalctl -u fail2ban"
  fi
  if fail2ban-client status 2>/dev/null | grep -qE 'Jail list:.*apache'; then info j.apache "Jail Apache2 (bonus)" "active"
  else info j.apache "Jail Apache2 (bonus)" "non activée : [apache-auth] enabled = true"; fi
}

# ------------------------------- lancement -----------------------------------
meta version "$VERSION"
meta date "$(date '+%Y-%m-%d %H:%M:%S')"
chk_systeme
if [ "$ROLE" = "routeur" ]; then
  chk_routage
  chk_dhcp
else
  chk_pc_reseau
  chk_ssh
  chk_apache
  chk_iptables
  chk_fail2ban
fi

if [ "$MODE" = "tsv" ]; then
  printf 'META\tfin\t%s\n' "$(date +%s)"
else
  total=$(( COUNT[OK] + COUNT[KO] + COUNT[WARN] ))
  printf '\n%sBilan : %s OK, %s KO, %s à améliorer, sur %s contrôles (hors infos).%s\n' "$W" "${COUNT[OK]}" "${COUNT[KO]}" "${COUNT[WARN]}" "$total" "$N"
fi
exit 0
