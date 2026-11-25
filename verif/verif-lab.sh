#!/bin/bash
# =============================================================================
# verif-lab — contrôle EN LECTURE SEULE d'un laboratoire (routeur ou PC)
# EAFC Uccle — Logiciel open source 2026-2027 — Jean-Louis De Belder
#
# Ce script ne modifie rien : il lit la configuration et l'état de la machine,
# puis affiche un rapport.
#
#   verif-lab --texte              rapport lisible dans la console (à lancer en root)
#   verif-lab --texte --labo 05    un seul labo (01 à 10), ou une liste : --labo 05,06
#   verif-lab                      rapport au format TSV, lu par le site (via SSH, compte prof)
#   verif-lab --role pc|routeur    force le rôle (sinon : détecté par l'adresse IP)
#   verif-lab --liste              liste des labos contrôlés
#
# Labos : 01 base Proxmox · 02 routage et NAT · 03 DHCP · 04 SSH, Apache, iptables, fail2ban
#         05 SMTP · 06 FTP · 07 NFS · 08 CUPS · 09 OpenVPN · 10 DNS
# =============================================================================
set -u
umask 077
export PATH=/usr/sbin:/sbin:/usr/bin:/bin
export LC_ALL=C.UTF-8 LANG=C.UTF-8

VERSION="2.1"
MODE="tsv"
ROLE=""
LABOS_DEMANDES="tout"
TOUS_LABOS="01 02 03 04 05 06 07 08 09 10"
RELAIS_SMTP="relay.edpnet.be"      # labo 05 : relais sur le port 25, sans authentification
PORT_SMTP="25"
MAIL_PROF="jean-louis.debelder@eafc-uccle.be"
IP_ROUTEUR="10.68.69.1"
IP_PC="10.68.69.10"
DOCROOT_ATTENDU="/var/www/eafc.lab/html"

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; }

titre_labo() {
  case "$1" in
    00) echo "Système" ;; 01) echo "Base Proxmox" ;; 02) echo "Routage et NAT" ;; 03) echo "DHCP" ;;
    04) echo "SSH, Apache, iptables, fail2ban" ;; 05) echo "SMTP et la fonction mail" ;; 06) echo "FTP" ;;
    07) echo "NFS serveur et client" ;; 08) echo "CUPS" ;; 09) echo "OpenVPN" ;; 10) echo "DNS" ;; *) echo "?" ;;
  esac
}

while [ $# -gt 0 ]; do
  case "$1" in
    --texte) MODE="texte" ;;
    --role)  ROLE="${2:-}"; shift ;;
    --labo|--labos) LABOS_DEMANDES="${2:-}"; shift ;;
    --liste) for l in $TOUS_LABOS; do printf '%s  %s\n' "$l" "$(titre_labo "$l")"; done; exit 0 ;;
    -h|--aide|--help) usage; exit 0 ;;
    *) echo "Option inconnue : $1" >&2; exit 2 ;;
  esac
  shift
done

# --labo : « tout », ou une liste 01..10 séparée par des virgules (5 = 05)
LABOS=""
if [ "$LABOS_DEMANDES" = "tout" ] || [ -z "$LABOS_DEMANDES" ]; then
  LABOS="$TOUS_LABOS"
else
  for l in ${LABOS_DEMANDES//,/ }; do
    [[ "$l" =~ ^[0-9]{1,2}$ ]] || { echo "Labo inconnu : $l (01 à 10, ou tout)" >&2; exit 2; }
    l=$(printf '%02d' "$((10#$l))")
    case " $TOUS_LABOS " in *" $l "*) ;; *) echo "Labo inconnu : $l (01 à 10, ou tout)" >&2; exit 2 ;; esac
    case " $LABOS " in *" $l "*) ;; *) LABOS="${LABOS:+$LABOS }$l" ;; esac
  done
fi
labo_demande() { case " $LABOS " in *" $1 "*) return 0 ;; esac; return 1; }

if [ "$(id -u)" -ne 0 ]; then
  echo "verif-lab doit être lancé en root (su - ), ou par le compte prof via le site." >&2
  exit 1
fi

# ------------------------------- sortie --------------------------------------
declare -A COUNT=([OK]=0 [KO]=0 [WARN]=0 [INFO]=0)
SEC=""
LABO="00"

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

section() { # titre [n° de labo]
  SEC="$1"; LABO="${2:-00}"
  if [ "$MODE" = "texte" ]; then
    if [ "$LABO" = "00" ]; then printf '\n%s== %s ==%s\n' "$W" "$SEC" "$N"
    else printf '\n%s== Labo %s — %s ==%s\n' "$W" "$LABO" "$SEC" "$N"; fi
  fi
  return 0
}

emit() { # id statut libellé détail conseil
  local id="$1" st="$2" lab="$3" det="${4:-}" hint="${5:-}"
  COUNT[$st]=$(( ${COUNT[$st]} + 1 ))
  if [ "$MODE" = "tsv" ]; then
    printf 'CHECK\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(clean "$SEC")" "$id" "$st" "$(clean "$lab")" "$(clean "$det")" "$(clean "$hint")" "$LABO"
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
tcp_ouvert() { timeout 4 bash -c 'exec 3<>/dev/tcp/$0/$1' "$1" "$2" 2>/dev/null; }   # hôte port
ecoute() { ss -H -ln"${1:0:1}" "sport = :$2" 2>/dev/null | awk '{print $4}' | tr '\n' ' '; }  # tcp|udp port → adresses
pkg_ok() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }
journal() { # identifiant syslog → lignes du journal (persistant ou non), et fichier classique s'il existe
  journalctl -q --no-pager -o short-iso -t "$1" 2>/dev/null | tail -n 3000
}

LAN_IF=$(iface_of_ip "$IP_ROUTEUR")
WAN_IF=$(awk '$2 ~ /^172\.17\./ {print $1; exit}' <<<"$ADDRS")

# ------------------------------ pare-feu (commun) ------------------------------
# Le PC filtre-t-il l'entrée ? (politique DROP, ou règle DROP/REJECT sans condition, ou nftables policy drop)
fw_actif() {
  local r; r=$(iptables -S INPUT 2>/dev/null)
  grep -q '^-P INPUT DROP' <<<"$r" && return 0
  grep -qE '^-A INPUT -j (DROP|REJECT)' <<<"$r" && return 0
  have nft && nft list ruleset 2>/dev/null | grep -qE 'hook input.*policy drop' && return 0
  return 1
}
port_couvert() { # spec (22 | 50000:50100 | 21,80,443) port
  local item a b; local -a items; IFS=, read -ra items <<<"$1"
  for item in "${items[@]}"; do
    if [[ "$item" == *:* ]]; then
      a=${item%%:*}; b=${item##*:}; a=${a:-0}; b=${b:-65535}
      [ "$2" -ge "$a" ] && [ "$2" -le "$b" ] && return 0
    elif [ "$item" = "$2" ]; then return 0; fi
  done
  return 1
}
# Règle ACCEPT qui autorise proto/port AVANT le DROP final ; lit iptables -S, ou un fichier (rules.v4).
fw_regle() { # proto port [fichier]
  local proto="$1" port="$2" src="${3:-}" line
  while IFS= read -r line; do
    [[ "$line" == "-A INPUT "* ]] || continue
    [[ "$line" =~ ^-A\ INPUT\ -j\ (DROP|REJECT) ]] && return 1
    [ "$line" = "-A INPUT -j ACCEPT" ] && { echo "$line"; return 0; }
    [[ "$line" =~ -j\ ACCEPT$ ]] || continue
    [[ "$line" =~ -p\ $proto ]] || continue
    if [[ "$line" =~ --dports?\ ([0-9:,]+) ]] && port_couvert "${BASH_REMATCH[1]}" "$port"; then echo "$line"; return 0; fi
  done < <(if [ -n "$src" ]; then cat "$src" 2>/dev/null; else iptables -S INPUT 2>/dev/null; fi)
  return 1
}
# Contrôle « le pare-feu laisse passer ces ports, et c'est sauvegardé ».
chk_parefeu() { # id libellé conseil proto:port…
  local id="$1" lab="$2" hint="$3"; shift 3
  if ! fw_actif; then
    info "$id" "$lab" "pare-feu INPUT ouvert (aucun DROP) : rien à autoriser"
    return 0
  fi
  local pp miss="" nosave="" ipt
  ipt=$(iptables -S INPUT 2>/dev/null | grep -c '^-A INPUT')
  for pp in "$@"; do
    if [ "$ipt" -eq 0 ] && have nft; then
      nft list ruleset 2>/dev/null | grep -qE "${pp%%:*} dport .*\b${pp##*:}\b" || miss="$miss ${pp}"
      continue
    fi
    fw_regle "${pp%%:*}" "${pp##*:}" >/dev/null || miss="$miss ${pp}"
    fw_regle "${pp%%:*}" "${pp##*:}" /etc/iptables/rules.v4 >/dev/null || nosave="$nosave ${pp}"
  done
  if [ -n "$miss" ]; then ko "$id" "$lab" "bloqué par le DROP :$miss" "$hint"
  elif [ -n "$nosave" ]; then ko "$id" "$lab" "règle active mais non sauvegardée :$nosave" "netfilter-persistent save (sinon perdu au redémarrage)"
  else ok "$id" "$lab"; fi
}

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
  section "Routage et NAT" 02
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
  section "DHCP (dnsmasq)" 03
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
  section "Réseau du PC" 02
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

}

# ----------------------------- PC : client DHCP ------------------------------
chk_pc_dhcp() {
  section "Client DHCP (PC)" 03
  if grep -RqsE '^[[:space:]]*iface[[:space:]]+[^[:space:]]+[[:space:]]+inet[[:space:]]+dhcp' /etc/network/interfaces /etc/network/interfaces.d/; then
    ok p.dhcp "Carte du PC en DHCP (iface … inet dhcp)"
  else
    warn p.dhcp "Carte du PC en DHCP (iface … inet dhcp)" "adresse statique" "Labo DHCP, étape 3 : iface ens18 inet dhcp. La statique reste acceptable en secours."
  fi
  local lf; lf=$(grep -lsE 'fixed-address 10\.68\.69\.10;' /var/lib/dhcp/dhclient*.leases 2>/dev/null | head -n1)
  if [ -n "$lf" ]; then ok p.bail "Bail DHCP reçu pour 10.68.69.10 (réservation)" "$lf"
  elif ls /var/lib/dhcp/dhclient*.leases >/dev/null 2>&1; then
    warn p.bail "Bail DHCP reçu pour 10.68.69.10 (réservation)" "bail reçu, mais pas pour 10.68.69.10" "dhcp-host=<MAC du PC>,10.68.69.10 sur le routeur, puis ifdown ens18 && ifup ens18"
  else
    info p.bail "Bail DHCP du PC" "aucun fichier de bail dhclient (adresse statique ?)"
  fi
}

# ------------------------------- PC : SSH ------------------------------------
chk_ssh() {
  section "SSH" 04
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
  section "Apache2 et PHP" 04
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

  # -R (et non -r) : les fichiers de sites-enabled sont des liens symboliques créés par a2ensite,
  # que grep -r ne suit pas (faux KO « non déclaré » signalé par les étudiants, labo 04).
  # Guillemets et barre oblique finale éventuels retirés avant comparaison.
  local dr; dr=$(grep -RhiE '^[[:space:]]*DocumentRoot' /etc/apache2/sites-enabled/ 2>/dev/null | awk '{print $2}' | tr -d "\"'" | sed 's:/*$::' | grep -Fx "$DOCROOT_ATTENDU" | head -n1)
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
  section "iptables" 04
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
  section "fail2ban" 04
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

# ------------------------- Labo 01 : base Proxmox ----------------------------
chk_base() {
  section "Base Proxmox (VM Debian)" 01
  if pkg_ok qemu-guest-agent; then
    if svc_active qemu-guest-agent; then ok b.agent "Agent invité QEMU actif" "Proxmox voit l'adresse IP (onglet Summary)"
    elif [ ! -e /dev/virtio-ports/org.qemu.guest_agent.0 ]; then
      ko b.agent "Agent invité QEMU actif" "installé, mais le canal virtio est absent" "Proxmox > Options > QEMU Guest Agent : cocher, puis ARRÊTER et redémarrer la VM (un reboot ne suffit pas)."
    else ko b.agent "Agent invité QEMU actif" "$(systemctl is-active qemu-guest-agent 2>&1)" "systemctl enable --now qemu-guest-agent"; fi
  else
    ko b.agent "Agent invité QEMU installé" "paquet absent" "apt install qemu-guest-agent && systemctl enable --now qemu-guest-agent"
  fi

  local n; n=$(apt-get -s -o Debug::NoLocking=1 upgrade 2>/dev/null | grep -c '^Inst ')
  if [ "$n" -eq 0 ]; then ok b.maj "Système à jour (apt upgrade)"
  else warn b.maj "Système à jour (apt upgrade)" "$n paquet(s) en attente" "apt update && apt upgrade -y"; fi
  local age; age=$(( ( $(date +%s) - $(stat -c %Y /var/lib/apt/lists 2>/dev/null || echo 0) ) / 86400 ))
  info b.update "Dernier apt update" "il y a $age jour(s)"

  if pkg_ok openssh-server; then ok b.ssh "Serveur SSH installé (openssh-server)"
  else ko b.ssh "Serveur SSH installé (openssh-server)" "absent" "apt install openssh-server"; fi
  local gui="" p
  for p in task-desktop xserver-xorg-core gnome-shell xfce4-session plasma-desktop; do pkg_ok "$p" && gui="$gui $p"; done
  if [ -z "$gui" ]; then ok b.gui "Pas d'interface graphique (serveur)"
  else warn b.gui "Pas d'interface graphique (serveur)" "installé :$gui" "Une VM serveur n'a pas de bureau : seul le poste dupont-gui en a un."; fi
}

# ------------------------- Labo 05 : SMTP (PC) -------------------------------
chk_smtp() {
  section "SMTP : Postfix et mail" 05
  if ! pkg_ok postfix; then
    ko m.pkg "Postfix installé" "paquet absent" "apt install postfix (profil « Système satellite »)"
    return 0
  fi
  ok m.pkg "Postfix installé"
  if svc_active postfix; then ok m.actif "Service postfix actif"
  else ko m.actif "Service postfix actif" "$(systemctl is-active postfix 2>&1)" "postfix check ; journalctl -u postfix@- -n 20"; fi
  if svc_enabled postfix || svc_enabled postfix@-; then ok m.enabled "postfix démarre au boot"
  else ko m.enabled "postfix démarre au boot" "" "systemctl enable postfix"; fi

  pcf() { postconf -h "$1" 2>/dev/null; }
  local relay; relay=$(pcf relayhost | tr -d ' ')
  local r_host r_port
  r_host=$(sed -E 's/^\[([^]]+)\].*/\1/; s/:[0-9]+$//' <<<"$relay"); r_port=$(grep -oE ':[0-9]+$' <<<"$relay" | tr -d :)
  if [ -z "$relay" ]; then
    ko m.relay "relayhost = [$RELAIS_SMTP]:$PORT_SMTP" "relayhost vide : Postfix livre lui-même (refusé par les serveurs)" "postconf -e 'relayhost = [$RELAIS_SMTP]:$PORT_SMTP' && systemctl reload postfix"
  elif [ "$r_host" != "$RELAIS_SMTP" ]; then
    ko m.relay "relayhost = [$RELAIS_SMTP]:$PORT_SMTP" "relayhost = $relay" "Le relais du cours est $RELAIS_SMTP : postconf -e 'relayhost = [$RELAIS_SMTP]:$PORT_SMTP'"
  elif [ -n "$r_port" ] && [ "$r_port" != "$PORT_SMTP" ]; then
    warn m.relay "relayhost = [$RELAIS_SMTP]:$PORT_SMTP" "port $r_port" "Le labo utilise le port $PORT_SMTP (sans authentification) : relayhost = [$RELAIS_SMTP]:$PORT_SMTP"
  elif [[ "$relay" != \[* ]]; then
    warn m.relay "relayhost = [$RELAIS_SMTP]:$PORT_SMTP" "sans crochets : Postfix cherche d'abord un MX" "Écrire le nom entre crochets : [$RELAIS_SMTP]:$PORT_SMTP"
  else ok m.relay "relayhost = [$RELAIS_SMTP]:$PORT_SMTP" "$relay"; fi

  local ii; ii=$(pcf inet_interfaces)
  case "$ii" in
    loopback-only|localhost|127.0.0.1|"127.0.0.1, [::1]"|"127.0.0.1 [::1]") ok m.inet "inet_interfaces = loopback-only" "$ii" ;;
    *) ko m.inet "inet_interfaces = loopback-only" "valeur : ${ii:-all}" "Un satellite n'accepte rien du réseau : postconf -e 'inet_interfaces = loopback-only' && systemctl restart postfix" ;;
  esac
  local md; md=$(pcf mydestination)
  if [ -z "$md" ]; then ok m.mydest "mydestination vide (tout part au relais)"
  else warn m.mydest "mydestination vide (tout part au relais)" "mydestination = $md" "Profil satellite : mydestination = (vide)"; fi
  local mh; mh=$(pcf myhostname)
  if [[ "$mh" == *.* ]]; then ok m.myhost "myhostname renseigné (nom complet)" "$mh"
  else warn m.myhost "myhostname renseigné (nom complet)" "myhostname = $mh" "postconf -e 'myhostname = $(hostname).eafc.lab' : un nom sans domaine peut être refusé"; fi

  # Port 25 : pas d'authentification. Si l'étudiant a gardé SASL, on vérifie au moins que le secret est protégé.
  if [ "$(pcf smtp_sasl_auth_enable)" = "yes" ]; then
    info m.sasl "Authentification SASL" "activée : inutile pour le relais sur le port $PORT_SMTP"
  fi
  local f; for f in /etc/postfix/sasl_passwd /etc/postfix/sasl_passwd.db /etc/postfix/sasl_passwd.lmdb; do
    [ -e "$f" ] || continue
    if [ "$(stat -c %a "$f")" = "600" ] || [ "$(stat -c %a "$f")" = "400" ]; then ok m.saslperm "$(basename "$f") protégé (600)"
    else ko m.saslperm "$(basename "$f") protégé (600)" "droits $(stat -c %a "$f")" "chmod 600 $f : il contient un mot de passe"; fi
  done

  local l25; l25=$(ecoute tcp 25)
  if [ -z "$l25" ]; then warn m.ecoute "Postfix n'écoute que sur la boucle locale (port 25)" "rien n'écoute sur le port 25" "systemctl status postfix"
  elif grep -qvE '^(127\.0\.0\.1|\[::1\]):25$' <<<"$(tr ' ' '\n' <<<"$l25" | grep .)"; then
    ko m.ecoute "Postfix n'écoute que sur la boucle locale (port 25)" "écoute : $l25" "inet_interfaces = loopback-only, puis systemctl restart postfix"
  else ok m.ecoute "Postfix n'écoute que sur la boucle locale (port 25)" "$l25"; fi

  if ! timeout 5 getent hosts "$RELAIS_SMTP" >/dev/null 2>&1; then
    ko m.joint "Le relais $RELAIS_SMTP répond sur le port $PORT_SMTP" "nom introuvable (DNS)" "getent hosts $RELAIS_SMTP ; vérifier /etc/resolv.conf"
  else
    local ban; ban=$(timeout 8 bash -c 'exec 3<>/dev/tcp/$0/$1 || exit 1; read -r -t 6 l <&3; printf "QUIT\r\n" >&3; echo "$l"' "$RELAIS_SMTP" "$PORT_SMTP" 2>/dev/null | tr -d '\r')
    if [[ "$ban" == 220* ]]; then ok m.joint "Le relais $RELAIS_SMTP répond sur le port $PORT_SMTP" "${ban:0:60}"
    else ko m.joint "Le relais $RELAIS_SMTP répond sur le port $PORT_SMTP" "${ban:-pas de bannière 220}" "Le port $PORT_SMTP sortant est-il autorisé ? Sur le routeur : NAT et iptables (FORWARD)."; fi
  fi

  if have mail || have mailx || have s-nail; then ok m.mailx "Commande mail installée (bsd-mailx ou mailutils)"
  else ko m.mailx "Commande mail installée (bsd-mailx ou mailutils)" "absente" "apt install bsd-mailx"; fi

  local q; q=$(postqueue -p 2>/dev/null)
  if grep -q 'Mail queue is empty' <<<"$q" || [ -z "$q" ]; then ok m.file "File d'attente vide (aucun message bloqué)"
  else
    local nq raison; nq=$(grep -cE '^[0-9A-F]{6,}' <<<"$q"); raison=$(grep -m1 -oE '\(.{0,120}\)' <<<"$q")
    warn m.file "File d'attente vide (aucun message bloqué)" "$nq message(s) en attente ${raison}" "postqueue -p pour la raison ; après correction : postqueue -f"
  fi

  local log; log=$( { journal postfix/smtp; cat /var/log/mail.log 2>/dev/null | tail -n 3000; } )
  local sent; sent=$(grep 'status=sent' <<<"$log" | grep -F "relay=$RELAIS_SMTP")
  if [ -n "$sent" ]; then ok m.sent "Envoi réussi par le relais (status=sent)" "$(grep -c . <<<"$sent") envoi(s)"
  elif grep -qE 'status=(deferred|bounced)' <<<"$log"; then
    ko m.sent "Envoi réussi par le relais (status=sent)" "$(grep -E 'status=(deferred|bounced)' <<<"$log" | tail -n1 | grep -oE 'status=.*' | cut -c1-160)" "Lire la raison ci-contre ; tester : echo test | mail -s test $MAIL_PROF"
  else
    ko m.sent "Envoi réussi par le relais (status=sent)" "aucun envoi dans le journal" "echo \"Test\" | mail -s \"Test $(hostname)\" $MAIL_PROF  puis  journalctl -t postfix/smtp"
  fi
  if grep -F "to=<$MAIL_PROF>" <<<"$sent" | grep -q .; then ok m.prof "Message envoyé à $MAIL_PROF"
  else warn m.prof "Message envoyé à $MAIL_PROF" "aucun status=sent vers cette adresse" "mail -s \"Documentation $(hostname)\" $MAIL_PROF < documentation.txt"; fi
  if journalctl -q --no-pager -b -t postfix/smtp 2>/dev/null | grep 'status=sent' | grep -qF "relay=$RELAIS_SMTP"; then
    ok m.boot "Envoi réussi depuis le dernier démarrage"
  else warn m.boot "Envoi réussi depuis le dernier démarrage" "aucun envoi depuis $(uptime -s 2>/dev/null)" "Test de permanence : après un reboot, renvoyer un message."; fi

  local doc; doc=$(find /root /home -maxdepth 3 -type f -iname 'documentation*.txt' 2>/dev/null | head -n1)
  if [ -n "$doc" ]; then ok m.doc "documentation.txt rédigée" "$doc ($(wc -l <"$doc") lignes)"
  else warn m.doc "documentation.txt rédigée" "introuvable dans /root et /home" "Rédiger documentation.txt (étape 5) puis l'envoyer avec mail."; fi
}

# --------------------------- Labo 06 : FTP (PC) ------------------------------
chk_ftp() {
  section "FTP : vsftpd" 06
  if ! pkg_ok vsftpd; then ko t.pkg "vsftpd installé" "paquet absent" "apt install vsftpd"; return 0; fi
  ok t.pkg "vsftpd installé"
  if svc_active vsftpd; then ok t.actif "Service vsftpd actif"
  else ko t.actif "Service vsftpd actif" "$(systemctl is-active vsftpd 2>&1)" "journalctl -u vsftpd -n 20 (souvent : 500 OOPS dans vsftpd.conf)"; fi
  if svc_enabled vsftpd; then ok t.enabled "vsftpd démarre au boot"
  else ko t.enabled "vsftpd démarre au boot" "" "systemctl enable vsftpd"; fi

  local conf=/etc/vsftpd.conf
  vs() { # clé [défaut] → valeur (minuscules pour YES/NO)
    local x; x=$(sed 's/#.*//' "$conf" 2>/dev/null | awk -F= -v k="$1" '{gsub(/^[ \t]+|[ \t]+$/,"",$1); if (tolower($1)==k) {sub(/^[^=]*=/,""); gsub(/^[ \t]+|[ \t]+$/,""); val=$0}} END{print val}')
    [ -z "$x" ] && x="${2:-}"; echo "$x"
  }
  oui() { [ "$(vs "$1" "${2:-}" | tr a-z A-Z)" = "YES" ]; }
  if oui anonymous_enable NO; then ko t.anon "Accès anonyme interdit (anonymous_enable=NO)" "anonymous_enable=YES" "anonymous_enable=NO"
  else ok t.anon "Accès anonyme interdit (anonymous_enable=NO)"; fi
  if oui local_enable YES && oui write_enable NO; then ok t.local "Comptes locaux autorisés en écriture (local_enable, write_enable)"
  else ko t.local "Comptes locaux autorisés en écriture (local_enable, write_enable)" "local_enable=$(vs local_enable YES) write_enable=$(vs write_enable NO)" "local_enable=YES et write_enable=YES"; fi
  if oui chroot_local_user NO; then ok t.chroot "chroot_local_user=YES (enfermé dans sa racine)"
  else ko t.chroot "chroot_local_user=YES (enfermé dans sa racine)" "absent" "chroot_local_user=YES : sinon l'utilisateur voit tout le disque."; fi
  local root; root=$(vs local_root)
  if [ -n "$root" ]; then ok t.root "local_root défini" "$root"
  else ko t.root "local_root défini" "absent" "local_root=/home/\$USER/ftp_directory et user_sub_token=\$USER"; fi
  if oui userlist_enable NO && [ "$(vs userlist_deny YES | tr a-z A-Z)" = "NO" ]; then ok t.ulist "Liste blanche (userlist_enable=YES, userlist_deny=NO)"
  elif oui userlist_enable NO; then warn t.ulist "Liste blanche (userlist_enable=YES, userlist_deny=NO)" "userlist_deny=YES : la liste sert de liste NOIRE" "userlist_deny=NO pour n'autoriser QUE les comptes listés"
  else ko t.ulist "Liste blanche (userlist_enable=YES, userlist_deny=NO)" "userlist_enable absent" "userlist_enable=YES, userlist_deny=NO, userlist_file=/etc/vsftpd.userlist"; fi
  if oui allow_writeable_chroot NO; then warn t.wchroot "Pas de allow_writeable_chroot" "allow_writeable_chroot=YES affaiblit le chroot" "Racine non writable + sous-dossier ftp_data writable : l'option devient inutile."; fi

  local pmin pmax; pmin=$(vs pasv_min_port); pmax=$(vs pasv_max_port)
  if [ "$(vs pasv_enable YES | tr a-z A-Z)" = "YES" ] && [ "$pmin" = "50000" ] && [ "$pmax" = "50100" ]; then ok t.pasv "Mode passif, plage 50000-50100"
  else ko t.pasv "Mode passif, plage 50000-50100" "pasv_enable=$(vs pasv_enable YES) min=${pmin:-?} max=${pmax:-?}" "pasv_enable=YES, pasv_min_port=50000, pasv_max_port=50100"; fi
  if oui ssl_enable NO; then
    ok t.ssl "FTPS activé (ssl_enable=YES)"
    if [ "$(vs force_local_logins_ssl YES | tr a-z A-Z)" = "YES" ] && [ "$(vs force_local_data_ssl YES | tr a-z A-Z)" = "YES" ]; then ok t.force "Chiffrement obligatoire (force_local_logins_ssl, force_local_data_ssl)"
    else ko t.force "Chiffrement obligatoire (force_local_logins_ssl, force_local_data_ssl)" "un des deux à NO" "force_local_logins_ssl=YES et force_local_data_ssl=YES : sinon le mot de passe peut passer en clair"; fi
    local cert; cert=$(vs rsa_cert_file /usr/share/ssl-cert/ssl-cert-snakeoil.pem)
    if [ -r "$cert" ]; then info t.cert "Certificat FTPS" "$cert"
    else ko t.cert "Certificat FTPS lisible" "$cert introuvable" "openssl req -x509 -nodes -days 365 -newkey rsa:2048 -keyout /etc/ssl/private/vsftpd.key -out /etc/ssl/certs/vsftpd.crt"; fi
  else ko t.ssl "FTPS activé (ssl_enable=YES)" "ssl_enable=NO" "ssl_enable=YES, rsa_cert_file=…, rsa_private_key_file=… (étape 6)"; fi

  # Compte FTP dédié : shell /bin/ftponly
  local u home
  u=$(getent passwd | awk -F: '$7=="/bin/ftponly" {print $1; exit}')
  if [ -z "$u" ]; then
    ko t.compte "Compte FTP dédié (shell /bin/ftponly)" "aucun compte avec ce shell" "useradd -m -s /bin/ftponly <compte> ; voir étape 3"
  else
    ok t.compte "Compte FTP dédié (shell /bin/ftponly)" "$u"
    if [ -x /bin/ftponly ] && grep -qx '/bin/ftponly' /etc/shells; then ok t.shell "/bin/ftponly exécutable et déclaré dans /etc/shells"
    else ko t.shell "/bin/ftponly exécutable et déclaré dans /etc/shells" "script ou ligne /etc/shells manquant" "chmod +x /bin/ftponly && echo /bin/ftponly >> /etc/shells (sinon PAM refuse la connexion FTP)"; fi
    local ul; ul=$(vs userlist_file /etc/vsftpd.user_list)
    if grep -qx "$u" "$ul" 2>/dev/null; then ok t.inlist "$u est dans la liste blanche" "$ul"
    else ko t.inlist "$u est dans la liste blanche" "absent de $ul" "echo $u >> $ul"; fi
    if [ -n "$root" ]; then
      local tok r; tok=$(vs user_sub_token); r="$root"; [ -n "$tok" ] && r="${r//$tok/$u}"
      if [ ! -d "$r" ]; then ko t.racine "Racine chrootée $r" "dossier introuvable" "mkdir -p $r/ftp_data"
      else
        if runuser -u "$u" -- test -w "$r" 2>/dev/null && ! oui allow_writeable_chroot NO; then
          ko t.racine "Racine chrootée non writable" "$u peut écrire dans $r" "chown root:root $r ; chmod 755 $r (sinon : 500 OOPS writable root inside chroot)"
        else ok t.racine "Racine chrootée non writable" "$r"; fi
        if [ -d "$r/ftp_data" ] && runuser -u "$u" -- test -w "$r/ftp_data" 2>/dev/null; then ok t.data "ftp_data writable par $u"
        else ko t.data "ftp_data writable par $u" "absent ou non writable" "mkdir $r/ftp_data && chown $u: $r/ftp_data"; fi
      fi
    fi
  fi

  if [ -n "$(ecoute tcp 21)" ]; then
    local rep; rep=$(timeout 8 bash -c 'exec 3<>/dev/tcp/127.0.0.1/21 || exit 1; read -r -t 4 a <&3; printf "AUTH TLS\r\n" >&3; read -r -t 4 b <&3; echo "$a|$b"' 2>/dev/null | tr -d '\r')
    if [[ "${rep#*|}" == 234* ]]; then ok t.live "Test réel : le serveur accepte AUTH TLS (FTPS)" "${rep%%|*}"
    elif [[ "$rep" == 220* ]]; then ko t.live "Test réel : le serveur accepte AUTH TLS (FTPS)" "${rep#*|}" "ssl_enable=YES puis systemctl restart vsftpd"
    else ko t.live "Test réel : connexion au port 21" "${rep:-aucune réponse}" "journalctl -u vsftpd"; fi
  else ko t.live "vsftpd écoute sur le port 21" "rien n'écoute" "systemctl status vsftpd"; fi

  chk_parefeu t.fw "Pare-feu : port 21 et plage passive 50000-50100" \
    "iptables -I INPUT <n° avant le DROP> -p tcp --dport 21 -j ACCEPT ; idem --dport 50000:50100" tcp:21 tcp:50000 tcp:50100
}

chk_ftp_client() {
  section "Client FTP (routeur)" 06
  if have lftp; then ok t.client "Client lftp installé"
  elif have ftp; then warn t.client "Client FTPS installé (lftp)" "seul ftp est présent : il ne sait pas faire FTPS" "apt install lftp ; lftp -u <compte> -e 'set ftp:ssl-force true' 10.68.69.10"
  else ko t.client "Client FTPS installé (lftp)" "aucun client FTP" "apt install lftp"; fi
  if tcp_ouvert "$IP_PC" 21; then ok t.joint "Le serveur FTP du PC répond (10.68.69.10:21)"
  else ko t.joint "Le serveur FTP du PC répond (10.68.69.10:21)" "port fermé" "vsftpd actif sur le PC ? pare-feu du PC : port 21"; fi
}

# ------------------------ Labo 07 : NFS (PC = serveur) -----------------------
chk_nfs_serveur() {
  section "NFS : serveur" 07
  if ! pkg_ok nfs-kernel-server; then ko n.pkg "nfs-kernel-server installé" "paquet absent" "apt install nfs-kernel-server"; return 0; fi
  ok n.pkg "nfs-kernel-server installé"
  if svc_active nfs-server; then ok n.actif "Service nfs-server actif"
  else ko n.actif "Service nfs-server actif" "$(systemctl is-active nfs-server 2>&1)" "exportfs -ra ; journalctl -u nfs-server -n 20"; fi
  if svc_enabled nfs-server; then ok n.enabled "nfs-server démarre au boot"
  else ko n.enabled "nfs-server démarre au boot" "" "systemctl enable nfs-server"; fi

  if [ -d /srv/data ]; then
    local own; own=$(stat -c '%U:%G' /srv/data)
    if [ "$own" = "nobody:nogroup" ]; then ok n.dir "/srv/data appartient à nobody:nogroup"
    else warn n.dir "/srv/data appartient à nobody:nogroup" "propriétaire : $own" "chown nobody:nogroup /srv/data"; fi
    if find /srv/data -maxdepth 1 -type f 2>/dev/null | grep -q .; then ok n.test "Fichier de test présent dans /srv/data"
    else warn n.test "Fichier de test présent dans /srv/data" "dossier vide" "echo test > /srv/data/exercice.lab"; fi
  else ko n.dir "Dossier partagé /srv/data" "introuvable" "mkdir -p /srv/data && chown nobody:nogroup /srv/data"; fi

  local ex; ex=$(cat /etc/exports /etc/exports.d/*.exports 2>/dev/null | sed 's/#.*//' | grep -E '^[[:space:]]*/srv/data[[:space:]]')
  if [ -z "$ex" ]; then
    ko n.exports "/etc/exports : /srv/data 10.68.69.0/24(rw,sync,no_subtree_check)" "aucune ligne pour /srv/data" "echo '/srv/data 10.68.69.0/24(rw,sync,no_subtree_check)' >> /etc/exports && exportfs -ra"
  elif grep -qE '[[:space:]](\*|0\.0\.0\.0)' <<<"$ex"; then
    ko n.exports "Partage limité au LAN" "ouvert à tous : $ex" "Remplacer * par 10.68.69.0/24"
  elif grep -qF '10.68.69.0/24' <<<"$ex"; then
    local opt miss=""; opt=$(grep -oE '10\.68\.69\.0/24\([^)]*\)' <<<"$ex")
    for o in rw sync no_subtree_check; do grep -qE "[(,]$o[,)]" <<<"$opt" || miss="$miss $o"; done
    if [ -z "$miss" ]; then ok n.exports "/etc/exports : /srv/data pour 10.68.69.0/24 (rw,sync,no_subtree_check)" "$opt"
    else warn n.exports "/etc/exports : options rw,sync,no_subtree_check" "manquant :$miss" "$opt → (rw,sync,no_subtree_check)"; fi
  else warn n.exports "Partage limité à 10.68.69.0/24" "$ex" "Le cours partage pour le réseau 10.68.69.0/24"; fi
  if grep -q 'no_root_squash' <<<"$ex"; then ko n.squash "root_squash actif (pas de no_root_squash)" "no_root_squash présent" "Retirer no_root_squash : root du client deviendrait root sur le serveur."
  else ok n.squash "root_squash actif (pas de no_root_squash)"; fi
  if exportfs -v 2>/dev/null | grep -q '^/srv/data'; then ok n.export "Partage publié (exportfs -v)"
  else ko n.export "Partage publié (exportfs -v)" "/srv/data absent" "exportfs -ra"; fi

  local vers; vers=$(cat /proc/fs/nfsd/versions 2>/dev/null)
  if [ -n "$vers" ] && ! grep -qE '(^| )\+3( |$)' <<<"$vers"; then ok n.v4 "NFSv4 seul (v3 désactivé)" "$vers"
  elif grep -RqsE '^[[:space:]]*vers3[[:space:]]*=[[:space:]]*(n|no|0)' /etc/nfs.conf /etc/nfs.conf.d/; then
    warn n.v4 "NFSv4 seul (v3 désactivé)" "réglé dans nfs.conf mais pas encore appliqué" "systemctl restart nfs-server"
  else ko n.v4 "NFSv4 seul (v3 désactivé)" "versions : ${vers:-?}" "printf '[nfsd]\\nvers3=n\\n' > /etc/nfs.conf.d/nfsv4-only.conf && systemctl restart nfs-server"; fi

  if fw_actif; then
    local rg; rg=$(fw_regle tcp 2049)
    if [ -z "$rg" ]; then ko n.fw "Pare-feu : 2049/tcp pour le LAN seulement" "bloqué par le DROP" "iptables -I INPUT <n° avant le DROP> -p tcp -s 10.68.69.0/24 --dport 2049 -j ACCEPT"
    elif ! grep -qF -- '-s 10.68.69.0/24' <<<"$rg"; then warn n.fw "Pare-feu : 2049/tcp pour le LAN seulement" "ouvert sans restriction de source" "Ajouter -s 10.68.69.0/24 à la règle"
    elif ! fw_regle tcp 2049 /etc/iptables/rules.v4 >/dev/null; then ko n.fw "Pare-feu : 2049/tcp pour le LAN seulement" "règle non sauvegardée" "netfilter-persistent save"
    else ok n.fw "Pare-feu : 2049/tcp pour le LAN seulement"; fi
  else info n.fw "Pare-feu : 2049/tcp" "pare-feu INPUT ouvert (aucun DROP)"; fi
}

# ----------------------- Labo 07 : NFS (routeur = client) --------------------
chk_nfs_client() {
  section "NFS : client" 07
  if pkg_ok nfs-common; then ok n.cpkg "nfs-common installé"
  else ko n.cpkg "nfs-common installé" "paquet absent" "apt install nfs-common"; return 0; fi
  if [ -d /mnt/data ]; then ok n.point "Point de montage /mnt/data"
  else ko n.point "Point de montage /mnt/data" "introuvable" "mkdir -p /mnt/data"; fi

  local fs; fs=$(sed 's/#.*//' /etc/fstab | awk '$2=="/mnt/data"')
  local automount=0
  if [ -z "$fs" ]; then
    warn n.fstab "Ligne /etc/fstab (nfs4, _netdev, nofail)" "aucune ligne pour /mnt/data" "10.68.69.10:/srv/data /mnt/data nfs4 defaults,_netdev,nofail 0 0"
  else
    local t o; t=$(awk '{print $3}' <<<"$fs"); o=$(awk '{print $4}' <<<"$fs")
    grep -q 'x-systemd.automount' <<<"$o" && automount=1
    if [ "$t" != "nfs4" ] && ! grep -qE 'vers=4|nfsvers=4' <<<"$o"; then warn n.fstab "Ligne /etc/fstab (nfs4, _netdev, nofail)" "type $t" "Type nfs4 (ou nfs avec vers=4)"
    elif ! grep -q '_netdev' <<<"$o" || ! grep -q 'nofail' <<<"$o"; then warn n.fstab "Ligne /etc/fstab (nfs4, _netdev, nofail)" "options : $o" "Ajouter _netdev,nofail : sinon le démarrage bloque si le serveur est absent"
    else ok n.fstab "Ligne /etc/fstab (nfs4, _netdev, nofail)" "$(awk '{print $1}' <<<"$fs")"; fi
  fi

  local srv_ok=0; tcp_ouvert "$IP_PC" 2049 && srv_ok=1
  if [ "$srv_ok" -eq 1 ]; then ok n.joint "Le serveur NFS répond (10.68.69.10:2049)"
  else ko n.joint "Le serveur NFS répond (10.68.69.10:2049)" "port fermé" "nfs-server actif sur le PC ? règle 2049 dans le pare-feu du PC ?"; fi

  if pkg_ok autofs && svc_active autofs && grep -RqsE '10\.68\.69\.10:/srv/data' /etc/auto.master /etc/auto.master.d/ /etc/auto.*; then
    ok n.auto "Montage à la demande (autofs)"; automount=1
  elif systemctl list-units --type=automount --all --no-legend 2>/dev/null | grep -q 'data'; then
    ok n.auto "Montage à la demande (automount systemd)"; automount=1
  elif [ "$automount" -eq 1 ]; then ok n.auto "Montage à la demande (x-systemd.automount)"
  else ko n.auto "Montage à la demande (autofs ou automount)" "aucun" "apt install autofs ; ou option x-systemd.automount dans fstab"; fi

  # Lecture réelle (déclenche l'automontage), seulement si le serveur répond, pour ne jamais bloquer.
  if [ "$srv_ok" -eq 1 ]; then
    local f; f=$(timeout -k 2 8 bash -c 'ls /mnt/data/exercice.lab 2>/dev/null || ls -d /mnt/data/* 2>/dev/null | head -n1' )
    local m; m=$(findmnt -n -o FSTYPE,OPTIONS -T /mnt/data 2>/dev/null | grep -E '^nfs')
    if [ -n "$m" ]; then
      local vv; vv=$(grep -oE 'vers=4(\.[0-9])?' <<<"$m")
      if [ -n "$vv" ]; then ok n.monte "Partage monté en NFSv4" "$vv"
      else warn n.monte "Partage monté en NFSv4" "$(cut -c1-80 <<<"$m")" "nfsstat -m doit montrer vers=4.x"; fi
      if [ -n "$f" ]; then ok n.lit "Lecture du partage" "$f"
      else warn n.lit "Lecture du partage (exercice.lab)" "partage vide ou illisible" "Sur le PC : echo test > /srv/data/exercice.lab"; fi
    else ko n.monte "Partage monté sur /mnt/data" "non monté" "mount -a (fstab) ou ls /mnt/data (autofs) ; dmesg | tail"; fi
  fi
}

# ------------------------------ Labo 08 : CUPS -------------------------------
chk_cups() {
  section "CUPS" 08
  if ! pkg_ok cups; then ko c.pkg "CUPS installé" "paquet absent" "apt install cups"; return 0; fi
  ok c.pkg "CUPS installé"
  if svc_active cups; then ok c.actif "Service cups actif"
  else ko c.actif "Service cups actif" "$(systemctl is-active cups 2>&1)" "journalctl -u cups -n 20"; fi
  if svc_enabled cups || svc_enabled cups.socket; then ok c.enabled "cups démarre au boot"
  else ko c.enabled "cups démarre au boot" "" "systemctl enable cups"; fi

  local l; l=$(ecoute tcp 631)
  if grep -qE '(^| )(0\.0\.0\.0|\*|\[::\]|10\.68\.69\.10):631' <<<"$l"; then ok c.ecoute "CUPS écoute sur le LAN (port 631)" "$l"
  elif [ -n "$l" ]; then ko c.ecoute "CUPS écoute sur le LAN (port 631)" "seulement : $l" "cupsctl --remote-admin --share-printers (ou Port 631 dans cupsd.conf)"
  else ko c.ecoute "CUPS écoute sur le LAN (port 631)" "rien n'écoute" "systemctl restart cups"; fi
  if cupsctl 2>/dev/null | grep -q '^_remote_admin=1'; then ok c.admin "Administration web ouverte au LAN (_remote_admin=1)"
  else ko c.admin "Administration web ouverte au LAN (_remote_admin=1)" "_remote_admin=0" "cupsctl --remote-admin"; fi
  local adm; adm=$(getent group lpadmin | cut -d: -f4)
  if [ -n "$adm" ]; then ok c.lpadmin "Un compte du groupe lpadmin" "$adm"
  else warn c.lpadmin "Un compte du groupe lpadmin" "groupe vide" "usermod -aG lpadmin <utilisateur> (pour s'identifier sur l'interface web)"; fi

  if pkg_ok printer-driver-cups-pdf; then ok c.pdfpkg "Imprimante virtuelle cups-pdf installée"
  else ko c.pdfpkg "Imprimante virtuelle cups-pdf installée" "paquet absent" "apt install printer-driver-cups-pdf"; fi
  local lv np; lv=$(lpstat -v 2>/dev/null); np=$(grep -c '^device for' <<<"$lv")
  if grep -q 'cups-pdf:/' <<<"$lv"; then ok c.pdfq "File d'impression PDF (lpstat -v)" "$(grep 'cups-pdf:/' <<<"$lv" | head -n1 | awk '{print $3}' | tr -d :)"
  else ko c.pdfq "File d'impression PDF (lpstat -v)" "aucune file cups-pdf" "lpadmin -p PDF -v cups-pdf:/ -m lsb/usr/cups-pdf/CUPS-PDF_opt.ppd -E (ou réinstaller printer-driver-cups-pdf)"; fi
  if [ "$np" -ge 2 ]; then ok c.second "Seconde imprimante ajoutée (interface web)" "$np files"
  else warn c.second "Seconde imprimante ajoutée (interface web)" "$np file(s)" "https://10.68.69.10:631/admin depuis le routeur ou dupont-gui : Ajouter une imprimante"; fi
  local dis; dis=$(lpstat -p 2>/dev/null | grep -i 'disabled' | awk '{print $2}' | tr '\n' ' ')
  if [ -n "$dis" ]; then warn c.dis "Files d'impression activées" "désactivée(s) : $dis" "cupsenable <file> && cupsaccept <file>"; fi
  local pdf; pdf=$(find /root/PDF /home/*/PDF /var/spool/cups-pdf -type f -iname '*.pdf' 2>/dev/null | grep -c .)
  if [ "$pdf" -gt 0 ]; then ok c.out "Fichier imprimé en PDF" "$pdf fichier(s) PDF produit(s)"
  else warn c.out "Fichier imprimé en PDF" "aucun PDF dans ~/PDF" "lp -d PDF /etc/hostname ; ls ~/PDF"; fi
  if grep -qs 'Print-Job' /var/log/cups/access_log* 2>/dev/null || zgrep -qs 'Print-Job' /var/log/cups/access_log* 2>/dev/null; then ok c.log "Journal : requête Print-Job (access_log)"
  else info c.log "Journal : requête Print-Job" "aucune trace dans /var/log/cups/access_log"; fi
  chk_parefeu c.fw "Pare-feu : port 631 (IPP et interface web)" "iptables -I INPUT <n° avant le DROP> -p tcp -s 10.68.69.0/24 --dport 631 -j ACCEPT" tcp:631
}

chk_cups_client() {
  section "CUPS : accès depuis le routeur" 08
  if tcp_ouvert "$IP_PC" 631; then ok c.joint "L'interface CUPS du PC répond (10.68.69.10:631)"
  else ko c.joint "L'interface CUPS du PC répond (10.68.69.10:631)" "port fermé" "Sur le PC : cupsctl --remote-admin et règle 631 dans iptables"; fi
}

# ---------------------------- Labo 09 : OpenVPN ------------------------------
chk_vpn_serveur() {
  section "OpenVPN : serveur" 09
  if ! pkg_ok openvpn; then ko v.pkg "OpenVPN installé" "paquet absent" "Lancer le script d'installation du cours (openvpn-install.sh)"; return 0; fi
  ok v.pkg "OpenVPN installé"
  if [ -c /dev/net/tun ]; then ok v.tun "/dev/net/tun présent (VM)"
  else ko v.tun "/dev/net/tun présent" "absent" "Le serveur doit être une VM : un conteneur LXC n'a pas /dev/net/tun par défaut."; fi
  local unit="" u
  for u in openvpn-server@server openvpn@server; do svc_active "$u" && { unit=$u; break; }; done
  if [ -n "$unit" ]; then ok v.actif "Service OpenVPN actif" "$unit"
    if svc_enabled "$unit"; then ok v.enabled "OpenVPN démarre au boot"
    else ko v.enabled "OpenVPN démarre au boot" "" "systemctl enable $unit"; fi
  else ko v.actif "Service OpenVPN actif (openvpn@server)" "aucun service server actif" "systemctl status openvpn@server (ou openvpn-server@server) ; journalctl -u openvpn@server"; fi

  local l; l=$(ecoute udp 1194)
  if [ -n "$l" ]; then ok v.ecoute "Écoute UDP 1194" "$l"
  else ko v.ecoute "Écoute UDP 1194" "rien n'écoute" "port 1194 et proto udp dans server.conf"; fi
  if ip -4 -o addr show dev tun0 2>/dev/null | grep -q ' 10\.8\.0\.1/'; then ok v.tun0 "tun0 = 10.8.0.1"
  else ko v.tun0 "tun0 = 10.8.0.1" "$(ip -br -4 addr show dev tun0 2>/dev/null || echo 'tun0 absent')" "server 10.8.0.0 255.255.255.0 dans server.conf"; fi

  local pki; pki=$(find /etc/openvpn -maxdepth 4 -type d -name pki 2>/dev/null | head -n1)
  if [ -n "$pki" ]; then
    local cl n; cl=$(ls "$pki/issued" 2>/dev/null | sed 's/\.crt$//' | grep -viE '^server' | tr '\n' ' '); n=$(wc -w <<<"$cl")
    if [ "$n" -ge 2 ]; then ok v.clients "Deux clients au moins (client1 + second)" "$cl"
    elif [ "$n" -eq 1 ]; then warn v.clients "Deux clients au moins (client1 + second)" "un seul : $cl" "Relancer le script : « Add a new client »"
    else ko v.clients "Certificat client créé" "aucun" "Relancer le script : « Add a new client » (client1, sans mot de passe)"; fi
    if grep -q '^R' "$pki/index.txt" 2>/dev/null; then ok v.revoke "Révocation testée" "$(grep -c '^R' "$pki/index.txt") certificat(s) révoqué(s)"
    else info v.revoke "Révocation" "aucun certificat révoqué : à expliquer dans le rapport"; fi
  else warn v.clients "PKI easy-rsa trouvée" "aucun dossier pki sous /etc/openvpn" "Le script d'installation crée /etc/openvpn/easy-rsa/pki"; fi
  local st; st=$(cat /var/log/openvpn/status.log /run/openvpn-server/status-server.log /etc/openvpn/openvpn-status.log 2>/dev/null | grep -c '^CLIENT_LIST')
  info v.connect "Clients connectés au moment du contrôle" "$st"
  chk_parefeu v.fw "Pare-feu : UDP 1194" "iptables -I INPUT <n° avant le DROP> -p udp --dport 1194 -j ACCEPT" udp:1194
}

chk_vpn_client() {
  section "OpenVPN : client" 09
  if ! pkg_ok openvpn; then ko v.cpkg "OpenVPN installé (client)" "paquet absent" "apt install openvpn"; return 0; fi
  ok v.cpkg "OpenVPN installé (client)"
  local f; f=$(find /root /home /etc/openvpn -maxdepth 3 -type f -name '*.ovpn' 2>/dev/null | head -n1)
  if [ -n "$f" ]; then
    ok v.profil "Profil .ovpn copié sur le routeur" "$f"
    local rem; rem=$(awk '$1=="remote" {print $2" "$3; exit}' "$f")
    if [[ "$rem" == "$IP_PC"* ]]; then ok v.remote "Le profil vise le serveur 10.68.69.10" "remote $rem"
    else warn v.remote "Le profil vise le serveur 10.68.69.10" "remote ${rem:-absent}" "Dans le .ovpn : remote 10.68.69.10 1194"; fi
  else ko v.profil "Profil .ovpn copié sur le routeur" "aucun fichier .ovpn" "scp client1.ovpn depuis le PC (étape 3)"; fi
  if ip -4 -o addr show dev tun0 2>/dev/null | grep -qE ' 10\.8\.0\.[0-9]+/'; then
    ok v.tun0 "Tunnel ouvert : tun0 en 10.8.0.x" "$(ip -4 -o addr show dev tun0 | awk '{print $4}')"
    if ping_ok 10.8.0.1; then ok v.ping "ping 10.8.0.1 à travers le tunnel"
    else ko v.ping "ping 10.8.0.1 à travers le tunnel" "pas de réponse" "Pare-feu du PC ? ip route ; journal du client openvpn"; fi
  else
    warn v.tun0 "Tunnel ouvert : tun0 en 10.8.0.x" "tunnel fermé au moment du contrôle" "openvpn --config ${f:-client1.ovpn} --daemon , puis relancer le contrôle"
  fi
}

# ------------------------------ Labo 10 : DNS --------------------------------
zone_fichier() { # zone → fichier déclaré (named-checkconf -p)
  named-checkconf -p 2>/dev/null | awk -v z="$1" '
    $1=="zone" { gsub(/"/,"",$2); cur=$2 }
    cur==z && $1=="file" { gsub(/[";]/,"",$2); print $2; exit }
    /^};/ { cur="" }'
}
zone_type() {
  named-checkconf -p 2>/dev/null | awk -v z="$1" '
    $1=="zone" { gsub(/"/,"",$2); cur=$2 }
    cur==z && $1=="type" { gsub(/;/,"",$2); print $2; exit }
    /^};/ { cur="" }'
}

chk_dns_serveur() {
  section "DNS : serveur bind9" 10
  local prenom zone; prenom=$(hostname); prenom=${prenom%%-*}; zone="$prenom.test"
  if ! pkg_ok bind9; then ko d2.pkg "bind9 installé" "paquet absent" "apt install bind9 bind9-dnsutils"; return 0; fi
  ok d2.pkg "bind9 installé"
  if svc_active named || svc_active bind9; then ok d2.actif "Service named actif"
  else ko d2.actif "Service named actif" "$(systemctl is-active named 2>&1)" "named-checkconf ; journalctl -u named -n 20"; fi
  if svc_enabled named || svc_enabled bind9; then ok d2.enabled "named démarre au boot"
  else ko d2.enabled "named démarre au boot" "" "systemctl enable named"; fi
  local cc; cc=$(named-checkconf 2>&1)
  if [ -z "$cc" ]; then ok d2.conf "named-checkconf sans erreur"
  else ko d2.conf "named-checkconf sans erreur" "$(head -n1 <<<"$cc")" "Corriger le fichier et la ligne indiqués"; fi

  local inv="69.68.10.in-addr.arpa" z t f out
  for z in "$zone" "$inv"; do
    t=$(zone_type "$z"); f=$(zone_fichier "$z")
    if [ -z "$t" ]; then
      ko "d2.z.$z" "Zone $z déclarée (type primary)" "absente de named.conf.local" "zone \"$z\" { type primary; file \"/etc/bind/db.$([ "$z" = "$inv" ] && echo 10.68.69 || echo "$z")\"; };"
      continue
    fi
    if [ "$t" = "primary" ] || [ "$t" = "master" ]; then ok "d2.z.$z" "Zone $z déclarée (type primary)" "$f"
    else ko "d2.z.$z" "Zone $z déclarée (type primary)" "type $t" "type primary;"; fi
    out=$(named-checkzone "$z" "$f" 2>&1)
    if grep -q '^OK' <<<"$out"; then ok "d2.cz.$z" "named-checkzone $z" "$(grep -m1 'loaded serial' <<<"$out" | grep -oE 'serial [0-9]+')"
    else ko "d2.cz.$z" "named-checkzone $z" "$(grep -v '^$' <<<"$out" | head -n1)" "named-checkzone $z $f ; penser au point final des noms et au serial"; fi
  done

  if ! have dig; then ko d2.dig "Outil dig installé (bind9-dnsutils)" "absent" "apt install bind9-dnsutils"; return 0; fi
  dq() { dig +time=2 +tries=1 +short @"$1" "${@:2}" 2>/dev/null; }
  local a; a=$(dq 127.0.0.1 "www.$zone" A)
  if grep -qx "$IP_PC" <<<"$a"; then ok d2.www "www.$zone → 10.68.69.10" "$(tr '\n' ' ' <<<"$a")"
  else ko d2.www "www.$zone → 10.68.69.10" "${a:-aucune réponse}" "www IN CNAME $prenom-pc ; $prenom-pc IN A 10.68.69.10 ; incrémenter le serial puis rndc reload"; fi
  if [ -n "$(dq 127.0.0.1 "www.$zone" CNAME)" ]; then ok d2.cname "www est un CNAME"
  else warn d2.cname "www est un CNAME" "enregistrement A direct" "www IN CNAME $prenom-pc"; fi
  for h in "$prenom-pc" "$prenom-routeur"; do
    a=$(dq 127.0.0.1 "$h.$zone" A)
    if [ -n "$a" ]; then ok "d2.a.$h" "Enregistrement A $h.$zone" "$a"
    else ko "d2.a.$h" "Enregistrement A $h.$zone" "absent" "$h IN A <adresse>"; fi
  done
  if [ -n "$(dq 127.0.0.1 "$zone" NS)" ]; then ok d2.ns "Enregistrement NS de la zone" "$(dq 127.0.0.1 "$zone" NS | tr '\n' ' ')"
  else ko d2.ns "Enregistrement NS de la zone" "absent" "@ IN NS ns1.$zone. et ns1 IN A 10.68.69.10"; fi
  local ptr; ptr=$(dq 127.0.0.1 -x "$IP_PC")
  if grep -q "\.$zone\.$" <<<"$ptr"; then ok d2.ptr "PTR 10.68.69.10 → nom de la zone" "$ptr"
  else ko d2.ptr "PTR 10.68.69.10 → nom de la zone" "${ptr:-aucune réponse}" "Dans db.10.68.69 : 10 IN PTR $prenom-pc.$zone."; fi
  local nx; nx=$(dig +time=2 +tries=1 @127.0.0.1 "inexistant-$RANDOM.$zone" A 2>/dev/null | grep -oE 'status: [A-Z]+' | awk '{print $2}')
  if [ "$nx" = "NXDOMAIN" ]; then ok d2.nx "Nom inexistant → NXDOMAIN"
  else warn d2.nx "Nom inexistant → NXDOMAIN" "statut : ${nx:-?}" "Un joker (*) dans la zone ? dig inconnu.$zone"; fi
  a=$(dq "$IP_PC" "www.$zone" A)
  if grep -qx "$IP_PC" <<<"$a"; then ok d2.lan "named répond sur l'adresse LAN (10.68.69.10)"
  else ko d2.lan "named répond sur l'adresse LAN (10.68.69.10)" "pas de réponse sur 10.68.69.10" "named.conf.options : listen-on { 127.0.0.1; 10.68.69.10; }; allow-query { localhost; 10.68.69.0/24; };"; fi
  chk_parefeu d2.fw "Pare-feu : port 53 (UDP et TCP)" "iptables -I INPUT <n° avant le DROP> -p udp --dport 53 -j ACCEPT ; idem en tcp" udp:53 tcp:53
}

chk_dns_client() {
  section "DNS : client (routeur)" 10
  local prenom zone; prenom=$(hostname); prenom=${prenom%%-*}; zone="$prenom.test"
  local ns1; ns1=$(awk '$1=="nameserver" {print $2; exit}' /etc/resolv.conf 2>/dev/null)
  if [ "$ns1" = "$IP_PC" ]; then ok d2.resolv "resolv.conf : nameserver 10.68.69.10 en premier"
  else ko d2.resolv "resolv.conf : nameserver 10.68.69.10 en premier" "premier nameserver : ${ns1:-aucun}" "nameserver 10.68.69.10 en première ligne de /etc/resolv.conf"; fi
  if grep -qE "^(search|domain)[[:space:]].*\b$zone\b" /etc/resolv.conf 2>/dev/null; then ok d2.search "resolv.conf : search $zone"
  else warn d2.search "resolv.conf : search $zone" "absent" "search $zone (pour écrire « ping www » sans le domaine)"; fi
  local r; r=$(timeout 5 getent hosts "www.$zone" | awk '{print $1; exit}')
  if [ "$r" = "$IP_PC" ]; then ok d2.cwww "Le routeur résout www.$zone → 10.68.69.10"
  else ko d2.cwww "Le routeur résout www.$zone → 10.68.69.10" "${r:-échec}" "dig @10.68.69.10 www.$zone ; pare-feu du PC (53) et listen-on de named"; fi
  r=$(timeout 5 getent hosts "$IP_PC" | awk '{print $2; exit}')
  if [[ "$r" == *".$zone" ]]; then ok d2.cptr "Résolution inverse de 10.68.69.10" "$r"
  else warn d2.cptr "Résolution inverse de 10.68.69.10" "${r:-échec}" "Zone inverse 69.68.10.in-addr.arpa sur le PC"; fi
  if timeout 5 getent hosts debian.org >/dev/null 2>&1; then ok d2.inet "Internet se résout toujours (debian.org)"
  else warn d2.inet "Internet se résout toujours (debian.org)" "échec" "named doit faire la récursion pour le LAN (allow-recursion { 10.68.69.0/24; localhost; }; forwarders)"; fi
}

# ------------------------------- lancement -----------------------------------
# Ce que chaque labo contrôle, selon la machine.
lancer_labo() { # n° de labo
  case "$ROLE:$1" in
    *:01)        chk_base ;;
    routeur:02)  chk_routage ;;
    pc:02)       chk_pc_reseau ;;
    routeur:03)  chk_dhcp ;;
    pc:03)       chk_pc_dhcp ;;
    pc:04)       chk_ssh; chk_apache; chk_iptables; chk_fail2ban ;;
    pc:05)       chk_smtp ;;
    pc:06)       chk_ftp ;;
    routeur:06)  chk_ftp_client ;;
    pc:07)       chk_nfs_serveur ;;
    routeur:07)  chk_nfs_client ;;
    pc:08)       chk_cups ;;
    routeur:08)  chk_cups_client ;;
    pc:09)       chk_vpn_serveur ;;
    routeur:09)  chk_vpn_client ;;
    pc:10)       chk_dns_serveur ;;
    routeur:10)  chk_dns_client ;;
    *) return 0 ;;   # rien à contrôler pour ce labo sur cette machine (labos 04 et 05 : PC seulement)
  esac
}

meta version "$VERSION"
meta date "$(date '+%Y-%m-%d %H:%M:%S')"
meta labos "$(tr ' ' ',' <<<"$LABOS")"
chk_systeme
for l in $LABOS; do lancer_labo "$l"; done

if [ "$MODE" = "tsv" ]; then
  printf 'META\tfin\t%s\n' "$(date +%s)"
else
  total=$(( COUNT[OK] + COUNT[KO] + COUNT[WARN] ))
  printf '\n%sBilan (%s) : %s OK, %s KO, %s à améliorer, sur %s contrôles (hors infos).%s\n' "$W" "$( [ "$LABOS" = "$TOUS_LABOS" ] && echo "tous les labos" || echo "labo $LABOS")" "${COUNT[OK]}" "${COUNT[KO]}" "${COUNT[WARN]}" "$total" "$N"
fi
exit 0
