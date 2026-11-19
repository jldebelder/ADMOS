#!/bin/bash
# =============================================================================
# maj-labos.sh — mettre à jour le contrôle de labo dans les machines des étudiants
# EAFC Uccle — Logiciel open source 2026-2027 — Jean-Louis De Belder
#
# À lancer SUR UN NŒUD PROXMOX, en root : il ne traite que les machines de CE nœud.
#
#   bash maj-labos.sh --etat            ne rien changer, montrer l'état de chaque machine
#   bash maj-labos.sh                   installer / mettre à jour ce qui est nécessaire
#   bash maj-labos.sh --id 4 [--etat]   un seul étudiant (n° du plan d'adressage)
#
# Une machine est concernée si son VMID (ou CTID) est dans la plage d'un étudiant du plan
# d'adressage (2000 + 10×ID à 2000 + 10×ID + 9) et qu'elle est démarrée.
#
# On entre dans la machine par l'agent invité QEMU (qm guest exec) — pct exec pour un
# conteneur — donc en root LOCAL, exactement comme quand l'étudiant lance lui-même
# « cd ADMOS && git pull && cd verif && bash install-prof.sh » : aucun port ouvert vers
# la machine, aucun compte de plus, la clé de l'enseignant reste limitée à verif-lab.
#
# Le PC (10.68.69.10) est traité avant le routeur (10.68.69.1), qui a besoin de la clé
# publique du PC. Sans l'une ni l'autre adresse, le rôle est indéterminable : la machine
# est signalée, pas touchée (labo pas encore configuré, ou poste graphique dupont-gui).
#
# Deux corrections sont faites automatiquement, et rien d'autre :
#   1. dépôt ADMOS mis à jour (git clone / git pull, dans le dossier déjà utilisé par
#      l'étudiant s'il existe) puis install-prof.sh, si la clé de l'enseignant du dépôt
#      n'est pas autorisée pour le compte prof ou si le dépôt a changé ;
#   2. si le durcissement sshd de l'étudiant (AllowUsers) empêche la relève, un fichier
#      /etc/ssh/sshd_config.d/90-admos-prof.conf est ajouté. Il ne contient qu'une ligne :
#        - routeur : AllowUsers prof@172.17.0.250  (le serveur de suivi vient chercher le
#          routeur par son adresse WAN et ouvre le tunnel vers le PC)
#        - PC      : AllowUsers prof@10.68.69.1    (le PC n'est jamais contacté
#          directement : il voit le routeur, qui a autorisé la clé de l'enseignant)
#      Le compte prof ne peut toujours que lire la configuration (commande imposée
#      verif-lab, clé sans mot de passe, aucun shell possible). Les autres règles
#      AllowUsers de l'étudiant restent actives ; le fichier est retiré si sshd refuse la
#      configuration ou si la règle n'est pas reprise telle quelle par sshd -T.
#
# Configuration optionnelle /etc/admos-labos.conf :  SUIVI=172.17.0.250
# =============================================================================
set -eu
export PATH=/usr/sbin:/sbin:/usr/bin:/bin
DEPOT=https://github.com/jldebelder/ADMOS.git
CLE_DEPOT=https://raw.githubusercontent.com/jldebelder/ADMOS/main/verif/cle_enseignant.pub
SUIVI=172.17.0.250          # adresse du serveur de suivi (celle des étudiants, sur vmbr0)
IP_ROUTEUR=10.68.69.1
IP_PC=10.68.69.10
MIN=2010; MAX=2300
[ -f /etc/admos-labos.conf ] && . /etc/admos-labos.conf
ETAT=0; ID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --etat) ETAT=1 ;;
    --id)   ID="${2:-}"; shift ;;
    *) echo "Option inconnue : $1 (--etat, --id N)"; exit 2 ;;
  esac
  shift
done
if [ -n "$ID" ] && ! [[ "$ID" =~ ^[0-9]+$ ]]; then echo "--id attend un numéro d'étudiant (ex. 4)"; exit 2; fi
if [ -n "$ID" ]; then MIN=$(( 2000 + 10 * ID )); MAX=$(( MIN + 10 )); fi

msg()   { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
avert() { printf '\033[1;33m!!\033[0m  %s\n' "$*"; }

# Clé de l'enseignant attendue : celle du dépôt, pas une clé plus ancienne déjà clonée.
CLE_ATT=$(curl -fsS --max-time 10 "$CLE_DEPOT" 2>/dev/null | sed -n 's/^ssh-[a-z0-9]* \([^ ]*\).*/\1/p' | head -1 || true)
if [ -z "$CLE_ATT" ]; then CLE_ATT=$(wget -qO- --timeout=10 "$CLE_DEPOT" 2>/dev/null | sed -n 's/^ssh-[a-z0-9]* \([^ ]*\).*/\1/p' | head -1 || true); fi
if [ -n "$CLE_ATT" ]; then
  msg "Clé enseignant du dépôt : $(printf '%s' "$CLE_ATT" | cut -c1-25)…"
else
  avert "Clé enseignant inaccessible : la comparaison se fera avec le dépôt présent dans la machine."
fi

# Petit programme commun aux deux scripts envoyés dans la machine : trouver le dépôt
# (l'étudiant l'a parfois cloné ailleurs que dans /root/ADMOS).
TROUVE='REPO=""
for d in /root/ADMOS /root/ADMOS-* /home/*/ADMOS /home/*/adm*/ADMOS; do
  if [ -f "$d/verif/install-prof.sh" ] && [ -f "$d/verif/verif-lab.sh" ]; then REPO="$d"; break; fi
done'

# --- lecture DANS la machine (aucune modification) --------------------------------
# Une information par ligne : IPS=, REPO=, CLE=, ALLOW=
SONDE="$TROUVE"'
CLE_ACT="%CLE%"
IPS=$(ip -4 -o addr show scope global 2>/dev/null | awk "{printf \"%s \", \$4}")
echo "IPS=$IPS"
if [ -n "$REPO" ]; then printf "REPO=%s %s\n" "$REPO" "$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo sans-commit)"; else echo "REPO=absent"; fi
printf "CLE="
if [ -z "$CLE_ACT" ]; then echo "?"
elif [ -f /home/prof/.ssh/authorized_keys ] && grep -qF "$CLE_ACT" /home/prof/.ssh/authorized_keys 2>/dev/null; then echo ok
else echo absente; fi
printf "ALLOW="
au=$(sshd -T 2>/dev/null | awk "\$1==\"allowusers\"{for(i=2;i<=NF;i++) printf \"%s \", \$i}")
if [ -z "$au" ]; then echo aucune; else echo "$au"; fi'

# --- mise à jour DANS la machine --------------------------------------------------
MAJ="$TROUVE"'
CLE_ACT="%CLE%"
set -e
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C LANG=C
if [ -z "$REPO" ]; then
  if ! command -v git >/dev/null 2>&1; then
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get install -y -qq git >/dev/null 2>&1 || { echo "git impossible a installer : la machine ne sort pas sur Internet"; exit 1; }
  fi
  REPO=/root/ADMOS
  git clone -q '"$DEPOT"' "$REPO" || { echo "clonage impossible : la machine sort-elle sur Internet ?"; exit 1; }
  echo "depot clone dans $REPO"
fi
avant=$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo absent)
pullout=$(git -C "$REPO" pull 2>&1 || true)
if [ -n "$pullout" ]; then echo "$pullout" | head -3 | tr "\n" " "; echo; fi
apres=$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo absent)
blob=$CLE_ACT
[ -n "$blob" ] || blob=$(sed -n "s/^ssh-[a-z0-9]* \([^ ]*\).*/\1/p" "$REPO/verif/cle_enseignant.pub" | head -1)
cle=absente
if [ -n "$blob" ] && [ -f /home/prof/.ssh/authorized_keys ] && grep -qF "$blob" /home/prof/.ssh/authorized_keys; then cle=ok; fi
echo "repo $REPO : $avant -> $apres, cle prof : $cle"
if [ "$avant" != "$apres" ] || [ "$avant" = absent ] || [ "$cle" = absente ]; then
  cd "$REPO/verif" && bash install-prof.sh --role %ROLE% 2>&1 | sed -e "s/\x1b\[[0-9;]*[mK]//g" | grep -E "^(==>|!!|ERREUR)" | sed -e "s/^==> //" -e "s/^!! //" -e "s/^ERREUR //" | tail -12
else
  echo "deja installe et a jour"
fi'

# --- clé publique du PC transmise au routeur quand le site HTTP du PC ne répond pas --
MAJ_CLE='echo %CLEB64% | base64 -d > /root/cle-site.pub
cd "%REPO%/verif" && bash install-prof.sh --role routeur --cle-fichier /root/cle-site.pub 2>&1 | sed -e "s/\x1b\[[0-9;]*[mK]//g" | grep -E "^(==>|!!|ERREUR)" | sed -e "s/^==> //" -e "s/^!! //" -e "s/^ERREUR //" | tail -12
rm -f /root/cle-site.pub'

# --- autoriser le compte prof depuis l'adresse qui le relie à l'enseignant ---------
FIX_ALLOW='set -e
f=/etc/ssh/sshd_config.d/90-admos-prof.conf
printf "%s\n" "# Controle des labos ADMOS - eafc-lab : le compte prof (lecture seule," "# commande imposee verif-lab, cle sans mot de passe) est seul autorise depuis la machine" "# de l enseignant. Les autres regles AllowUsers restent valables." "AllowUsers prof@%SRC%" > "$f"
if ! sshd -t 2>/dev/null; then
  rm -f "$f"; echo "sshd refuse cette configuration : rien n a ete change"; exit 0
fi
systemctl reload ssh >/dev/null 2>&1 || systemctl reload sshd >/dev/null 2>&1 || service ssh reload >/dev/null 2>&1 || true
if sshd -T 2>/dev/null | grep -qiE "^allowusers( .* )?prof@%SRC%$"; then
  echo "AllowUsers : prof@%SRC% autorise (verifie par sshd -T)"
else
  rm -f "$f"; if sshd -t 2>/dev/null; then systemctl reload ssh >/dev/null 2>&1 || systemctl reload sshd >/dev/null 2>&1 || true; fi
  echo "regle AllowUsers non cumulee : a corriger dans le fichier de durcissement de l etudiant"
fi'

b64() { printf '%s' "$1" | base64 -w0; }

# Sortie lisible : qm guest exec rend l'UTF-8 en latin-1, on le remet en place.
LIS='import json, sys
d = json.load(sys.stdin)
s = (d.get("out-data") or "") + (d.get("err-data") or "")
try:
    s = s.encode("latin-1").decode("utf-8")
except Exception:
    pass
s = s.strip()
print(s if s else "AUCUNE_SORTIE")'

exec_dans() { # id type script_base64
  local id="$1" type="$2" code="$3"
  if [ "$type" = ct ]; then
    pct exec "$id" -- /bin/bash -c "echo $code | base64 -d | bash" 2>&1 || echo "PAS_D_AGENT"
  else
    qm guest exec "$id" -- /bin/bash -c "echo $code | base64 -d | bash" 2>/dev/null \
      | python3 -c "$LIS" 2>/dev/null || echo "PAS_D_AGENT"
  fi
}

champ() { printf '%s' "$1" | sed -n "s/^$2=//p" | head -1; }

lister() {
  pvesh get /nodes/"$(hostname)"/qemu --output-format json 2>/dev/null | python3 -c '
import json, sys
for r in json.load(sys.stdin):
    if '"$MIN"' <= int(r.get("vmid", 0)) < '"$MAX"':
        print("%s|%s|%s|vm" % (r["vmid"], r.get("name", ""), r.get("status", "")))
' || true
  pvesh get /nodes/"$(hostname)"/lxc --output-format json 2>/dev/null | python3 -c '
import json, sys
for r in json.load(sys.stdin):
    if '"$MIN"' <= int(r.get("vmid", 0)) < '"$MAX"':
        print("%s|%s|%s|ct" % (r["vmid"], r.get("name", ""), r.get("status", "")))
' || true
}

role_de() { case " $1 " in *" $IP_PC/"*) echo pc ;; *" $IP_ROUTEUR/"*) echo routeur ;; *) echo inconnu ;; esac; }
plage() { echo $(( $1 - $1 % 10 )); }

# AllowUsers existe-t-il déjà, avec le compte prof depuis l'adresse voulue ?
allow_ok() { # allow source -> 0 = la relève passe déjà
  local allow="$1" src="$2"
  if [ "$allow" = aucune ]; then return 0; fi
  case " $allow " in
    *" prof "*|*" prof@$src "*) return 0 ;;
    *) return 1 ;;
  esac
}

machines=$(lister)
if [ -z "$machines" ]; then echo "Aucune machine d'étudiant concernée sur ce nœud."; exit 0; fi

PC=(); ROUTEUR=(); AUTRE=(); ETEINT=(); SONDES=()
sonde_base=${SONDE//%CLE%/$CLE_ATT}
while IFS='|' read -r id nom statut type; do
  if [ "$statut" != running ]; then ETEINT+=("$id|$nom|$type|éteinte"); continue; fi
  s=$(exec_dans "$id" "$type" "$(b64 "$sonde_base")")
  if printf '%s' "$s" | grep -q 'PAS_D_AGENT\|AUCUNE_SORTIE'; then
    SONDES+=("$id|$nom|$type|sans agent|qemu-guest-agent non installé : rien à faire|")
    AUTRE+=("$id|$nom|$type|sans agent"); continue
  fi
  ips=$(champ "$s" IPS); repo=$(champ "$s" REPO); cle=$(champ "$s" CLE); allow=$(champ "$s" ALLOW)
  role=$(role_de "$ips")
  fix=0
  if [ "$role" = pc ]; then allow_ok "$allow" "$IP_ROUTEUR" || fix=1
  elif [ "$role" = routeur ]; then allow_ok "$allow" "$SUIVI" || fix=1
  fi
  case "$cle" in ok) c="ok" ;; "?") c="à vérifier" ;; *) c="À INSTALLER" ;; esac
  if [ "$allow" = aucune ]; then a="AllowUsers aucune"
  elif [ "$fix" -eq 0 ]; then a="AllowUsers ok"
  else a="AllowUsers À CORRIGER ($allow)"; fi
  SONDES+=("$id|$nom|$type|$role|$repo · clé=$c · $a|$ips")
  case "$role" in
    pc)      PC+=("$id|$nom|$type|$fix") ;;
    routeur) ROUTEUR+=("$id|$nom|$type|$fix") ;;
    *)       AUTRE+=("$id|$nom|$type|$role") ;;
  esac
done <<< "$machines"

printf '%-6s %-20s %-4s %-9s %-64s %s\n' VMID NOM TYPE RÔLE ÉTAT ADRESSES
for l in "${SONDES[@]}"; do IFS='|' read -r id nom type role etat ips <<< "$l"; printf '%-6s %-20s %-4s %-9s %-64s %s\n' "$id" "$nom" "$type" "$role" "$etat" "$ips"; done
for l in "${ETEINT[@]}"; do IFS='|' read -r id nom type etat <<< "$l"; printf '%-6s %-20s %-4s %-9s %s\n' "$id" "$nom" "$type" "$etat"; done
echo
echo "RÔLE inconnu = ni $IP_PC (PC) ni $IP_ROUTEUR (routeur) : labo pas encore configuré, ou"
echo "poste graphique dupont-gui (le contrôle ne s'y installe pas). « sans agent » = qemu-guest-agent"
echo "à installer par l'étudiant, sinon la mise à jour automatique est impossible."

msg "${#PC[@]} PC, ${#ROUTEUR[@]} routeur(s), ${#AUTRE[@]} non concernée(s), ${#ETEINT[@]} éteinte(s)"
if [ "$ETAT" -eq 1 ]; then echo "(mode --etat : rien n'a été changé)"; exit 0; fi

maj_un() { # id type rôle fix_allow clé_publique_du_pc
  local id="$1" type="$2" role="$3" fix="$4" clepc="${5:-}" sortie script repocible
  script=${MAJ//%CLE%/$CLE_ATT}; script=${script//%ROLE%/$role}
  sortie=$(exec_dans "$id" "$type" "$(b64 "$script")")
  printf '   %-6s %-8s %s\n' "$id" "$role" "$(printf '%s' "$sortie" | tr '\n' ' ')"
  if [ "$role" = routeur ] && printf '%s' "$sortie" | grep -qi 'publique du site introuvable'; then
    repocible=$(printf '%s' "$sortie" | sed -n 's/.*repo \([^ ]*\) : .*/\1/p' | head -1)
    if [ -z "$repocible" ]; then repocible=/root/ADMOS; fi
    if [ -n "$clepc" ]; then
      script=${MAJ_CLE//%CLEB64%/$(b64 "$clepc")}; script=${script//%REPO%/$repocible}
      sortie=$(exec_dans "$id" "$type" "$(b64 "$script")")
      printf '   %-6s %-8s %s\n' "$id" "site+" "$(printf '%s' "$sortie" | tr '\n' ' ')"
    else
      avert "$id : clé publique du PC introuvable (PC éteint, ou install-prof.sh pas encore fait sur le PC)."
    fi
  fi
  if [ "$fix" = 1 ]; then
    src=$IP_ROUTEUR
    if [ "$role" = routeur ]; then src=$SUIVI; fi
    script=${FIX_ALLOW//%SRC%/$src}
    sortie=$(exec_dans "$id" "$type" "$(b64 "$script")")
    printf '   %-6s %-8s %s\n' "$id" "ssh" "$(printf '%s' "$sortie" | tr '\n' ' ')"
  fi
}

msg "Mise à jour des PC (le site HTTP du PC sert à livrer la clé au routeur)"
for l in "${PC[@]}"; do IFS='|' read -r id nom type fix <<< "$l"; maj_un "$id" "$type" pc "$fix" ""; done

msg "Mise à jour des routeurs (après les PC)"
for l in "${ROUTEUR[@]}"; do
  IFS='|' read -r id nom type fix <<< "$l"
  clepc=""
  for p in "${PC[@]}"; do
    IFS='|' read -r pid pnom ptype pfix <<< "$p"
    if [ "$(plage "$pid")" = "$(plage "$id")" ]; then
      clepc=$(exec_dans "$pid" "$ptype" "$(b64 "cat /var/lib/verif/id_ed25519.pub 2>/dev/null")")
      if printf '%s' "$clepc" | grep -q 'AUCUNE_SORTIE\|PAS_D_AGENT'; then clepc=""; fi
    fi
  done
  maj_un "$id" "$type" routeur "$fix" "$clepc"
done

echo
echo "Contrôler la relève : sudo -u www-data php /var/www/suivi/releve.php --etudiant <ID>"
echo "Voir l'état sans rien changer : bash maj-labos.sh --etat"
