# ADMOS

Ressources du cours **Administration de réseaux sous logiciel open source** — EAFC Uccle, 2026-2027.
Auteur : Jean-Louis De Belder.

| Dossier | Contenu |
|---|---|
| [`verif/`](verif/README.md) | Outil de contrôle des labos 01 à 10 (un labo au choix ou toute la configuration), installé par chaque étudiant |
| [`suivi/`](suivi/README.md) | Serveur de suivi de l'enseignant : résultats envoyés par les étudiants, relève de toute la classe, export CSV |

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
