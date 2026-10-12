# ADMOS

Ressources du cours **Administration de réseaux sous logiciel open source** — EAFC Uccle, 2026-2027.
Auteur : Jean-Louis De Belder.

| Dossier | Contenu |
|---|---|
| [`verif/`](verif/README.md) | Outil de contrôle des labos : routage et NAT, DHCP, SSH, Apache2 et PHP, iptables, fail2ban |

## Récupérer le dépôt sur dupont-pc

```bash
su -
apt install -y git
git clone https://github.com/jldebelder/ADMOS.git
cd ADMOS/verif
bash install-prof.sh
```

Pour mettre à jour plus tard : `cd ADMOS && git pull`, puis relancer `bash verif/install-prof.sh`.

Le site de contrôle s'ouvre depuis le poste graphique `dupont-gui` du LAN : voir [`verif/README.md`](verif/README.md).
