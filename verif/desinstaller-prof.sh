#!/bin/bash
# desinstaller-prof.sh — retire le compte prof, le script de contrôle et le site.
# À lancer en root : bash desinstaller-prof.sh
set -u
export PATH=/usr/sbin:/sbin:/usr/bin:/bin
[ "$(id -u)" -eq 0 ] || { echo "À lancer en root." >&2; exit 1; }
read -r -p "Supprimer le compte prof, verif-lab et le site de contrôle sur cette machine ? [o/N] " r
case "$r" in o|O|oui|OUI) ;; *) echo "Annulé."; exit 0 ;; esac
rm -f /etc/sudoers.d/prof-verif /usr/local/sbin/verif-lab
if id prof >/dev/null 2>&1; then userdel -r prof 2>/dev/null; fi
rm -rf /var/lib/verif /var/www/eafc.lab/html/verif
echo "Terminé : compte prof, script de contrôle et site supprimés."
