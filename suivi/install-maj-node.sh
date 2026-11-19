#!/bin/bash
# =============================================================================
# install-maj-node.sh — installer la mise à jour automatique du contrôle de labo
# sur CE nœud Proxmox (celui qui fait tourner les machines des étudiants).
#
#   sudo bash install-maj-node.sh          (sur le nœud, dans le dossier du dépôt)
#   SUIVI=172.17.0.250 bash install-maj-node.sh
#
# Ce que cela installe :
#   /usr/local/sbin/maj-labos.sh   l'outil qui met à jour les machines du nœud
#                                  (via l'agent invité QEMU : qm guest exec / pct exec)
#   /etc/admos-labos.conf          l'adresse du serveur de suivi, si elle change
#   /etc/cron.d/admos-labos        toutes les heures de 8h à 19h, jours ouvrables
#   /var/log/admos-labos.log       le journal de ce qui a été fait
#
# Rien sur les machines des étudiants n'est touché par ce script : il ne fait que poser
# l'outil. Ce sont les machines qui en ont besoin (clé de l'enseignant absente ou dépôt
# pas à jour) que maj-labos.sh corrige, une par une.
#
# Désinstaller : sudo rm -f /etc/cron.d/admos-labos /usr/local/sbin/maj-labos.sh /etc/admos-labos.conf
# =============================================================================
set -eu
export LC_ALL=C LANG=C
D=$(cd "$(dirname "$0")" && pwd)
SUIVI="${SUIVI:-172.17.0.250}"
HEURE="${HEURE:-10}"

if [ "$(id -u)" != 0 ]; then echo "Lancez en root : sudo bash install-maj-node.sh"; exit 1; fi
for f in maj-labos.sh install-maj-node.sh; do
  [ -f "$D/$f" ] || { echo "Fichier $f introuvable dans $D."; exit 1; }
done
command -v qm >/dev/null 2>&1 || { echo "Ce n'est pas un nœud Proxmox (qm introuvable) : rien à installer."; exit 1; }
[[ "$HEURE" =~ ^[0-9]+$ ]] && [ "$HEURE" -le 23 ] || { echo "HEURE doit être une heure (0-23)."; exit 2; }

sed -i 's/\r$//' "$D/maj-labos.sh"
bash -n "$D/maj-labos.sh" || { echo "maj-labos.sh : erreur de syntaxe, rien n'est installé."; exit 1; }
install -m 750 "$D/maj-labos.sh" /usr/local/sbin/maj-labos.sh
printf 'SUIVI=%s\n' "$SUIVI" > /etc/admos-labos.conf
printf '%s 8-19 * * 1-5 root bash /usr/local/sbin/maj-labos.sh >> /var/log/admos-labos.log 2>&1\n' "$HEURE" > /etc/cron.d/admos-labos
chmod 644 /etc/cron.d/admos-labos
[ -f /var/log/admos-labos.log ] || : > /var/log/admos-labos.log
systemctl is-active --quiet cron || systemctl enable --now cron

echo "Installé sur $(hostname) :"
echo "  /usr/local/sbin/maj-labos.sh   (qm guest exec / pct exec, en root local de la machine)"
echo "  /etc/cron.d/admos-labos        à $HEURE minute de chaque heure de 8h à 19h, du lundi au vendredi"
echo "  /etc/admos-labos.conf          SUIVI=$SUIVI"
echo "  /var/log/admos-labos.log       journal"
echo
echo "État des machines de ce nœud :"
bash /usr/local/sbin/maj-labos.sh --etat
