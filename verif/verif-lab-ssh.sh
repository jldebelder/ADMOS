#!/bin/bash
# =============================================================================
# verif-lab-ssh — commande imposée du compte prof (authorized_keys : command="…")
# EAFC Uccle — Logiciel open source 2026-2027 — Jean-Louis De Belder
#
# Quelle que soit la commande demandée par le client SSH, c'est CE script qui tourne.
# Il lit la demande (variable SSH_ORIGINAL_COMMAND) et n'accepte que :
#     verif            tous les labos
#     verif tout       tous les labos
#     verif 05         un seul labo (01 à 10)
# puis lance verif-lab par sudo, sous une forme autorisée dans /etc/sudoers.d/prof-verif.
# =============================================================================
set -u
export PATH=/usr/sbin:/sbin:/usr/bin:/bin

demande="${SSH_ORIGINAL_COMMAND:-verif}"
case "$demande" in
  verif|"verif tout")
    exec sudo -n /usr/local/sbin/verif-lab ;;
esac
if [[ "$demande" =~ ^verif\ (0[1-9]|10)$ ]]; then
  exec sudo -n /usr/local/sbin/verif-lab --labo "${BASH_REMATCH[1]}"
fi
echo "Demande refusée. Seules sont permises : verif, verif tout, verif 01 … verif 10." >&2
exit 2
