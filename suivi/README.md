# Suivi des labos (enseignant)

Un petit site sur **une VM de l'enseignant** pour suivre les labos de toute la classe :

* **Envois** : chaque fois qu'un étudiant clique sur « Lancer la vérification » (site `verif/`), le résultat
  arrive ici. Vous voyez sa **progression** labo par labo, avec l'historique.
* **Relève** : depuis le tableau de bord (ou par cron), le serveur interroge **lui-même** les machines de chaque
  étudiant. C'est le résultat de **référence pour la note** : il ne dépend pas d'un clic de l'étudiant.
* **Export CSV** : un fichier à ouvrir dans Excel, à côté de `Evaluation_Labos_ADMOS_2026-2027.xlsx`.

```
 dupont-gui ── site verif ──(HTTP POST, à travers le NAT du routeur)──►┐
                                                                        │   VM de l'enseignant
 routeur étudiant 172.17.ID.x ◄──(SSH prof, relève)──────────────────── ┤   172.17.0.250 (vmbr0)
   └──(tunnel vers 10.68.69.10:22 seulement)──► PC étudiant            │   http://…/suivi/
                                                                        └── /var/lib/suivi
```

## Comment l'étudiant est reconnu

Par l'**adresse WAN de son routeur** : les envois de son PC sortent par le NAT, le serveur voit donc
`172.17.ID.x`. Le fichier `classe.csv` fait le lien :

```
id;nom;prenom;wan
3;BELIBOU;Loredana;172.17.3.2
```

Un envoi d'une adresse absente de `classe.csv` apparaît dans « Envois non reconnus » : complétez la colonne `wan`.
Ce fichier contient des noms d'étudiants : il **n'est pas** dans le dépôt (voir `.gitignore`). Un modèle est dans
`classe.exemple.csv`.

## Installation (une fois)

1. **Créer la VM** : clone de `template-debian13`, une carte sur **vmbr0 sans VLAN**, adresse fixe dans
   172.17.0.0/16 qui n'est attribuée à aucun étudiant (par exemple `172.17.0.250/16`, passerelle `172.17.0.1`).
2. **Installer** (en root) :
   ```bash
   apt install -y git
   git clone https://github.com/jldebelder/ADMOS.git
   cd ADMOS/suivi
   bash install-suivi.sh --classe /chemin/vers/classe.csv      # ajoutez --cron 17:45 pour une relève automatique
   ```
   Le script demande le mot de passe du tableau de bord et affiche la **clé publique de relève**.
   La relève automatique suit l'heure du serveur : réglez-le sur Bruxelles avant de l'activer
   (`timedatectl set-timezone Europe/Brussels`).
3. **Dans le dépôt** (sur votre PC) :
   * collez la clé publique dans `verif/cle_enseignant.pub` ;
   * vérifiez `suivi_url` dans `verif/site/config.php` (`http://172.17.0.250/suivi/recevoir.php` par défaut) ;
   * `git commit` puis `git push`.
4. **Chaque étudiant** met à jour ses deux machines, le PC d'abord :
   `cd ADMOS && git pull && cd verif && bash install-prof.sh`

Tableau de bord : `http://172.17.0.250/suivi/` (depuis le réseau de l'école, ou par le VPN).

## Utilisation

| Je veux… | Où |
|---|---|
| voir la classe d'un coup d'œil | page d'accueil : une ligne par étudiant, une colonne par labo. Gros chiffre = relevé ; « site NN » = dernier envoi |
| voir le détail d'un étudiant | cliquer sur son nom : relevé, dernier envoi et meilleur envoi par labo, historique, chaque rapport complet |
| relever toute la classe | bouton **Relever toute la classe** (tous les labos ou un seul). Moins d'une minute : tout part en parallèle |
| relever un seul étudiant | sa fiche → **Relever cet étudiant** |
| récupérer les scores | **Exporter en CSV** : pour chaque labo, relevé %, dernier envoi %, meilleur envoi % |
| relever en ligne de commande | `sudo -u www-data php /var/www/suivi/releve.php [--labo 05] [--etudiant 3]` |

## Ce qu'il faut savoir

* **Envoi ≠ preuve** : un étudiant root peut modifier `verif-lab` ou forger un envoi depuis son routeur. L'envoi sert
  à suivre la progression ; la relève (que vous déclenchez) est plus fiable, et la plus sûre reste une relève en
  présence de l'étudiant.
* **Relève impossible** (étiquette rouge) : survolez-la pour la raison. Les plus courantes : machine éteinte, adresse
  WAN fausse dans `classe.csv`, `install-prof.sh` lancé avant que la clé soit dans `cle_enseignant.pub`,
  machine recréée (bouton **Oublier les empreintes SSH**).
* **Sécurité** : la clé de relève ne peut lancer que `verif-lab` chez l'étudiant, et sur le routeur elle ne peut
  ouvrir qu'un tunnel, vers `10.68.69.10:22`. Le tableau de bord est protégé par mot de passe ; `recevoir.php`
  n'accepte que 172.17.0.0/16, des envois de 1 Mo au plus, un toutes les 5 secondes par adresse.
* **Données** : `/var/lib/suivi` (un fichier JSON par résultat dans `resultats/<id>/`, le résumé dans
  `resume.json`). Pour repartir de zéro en début d'année : vider `resultats/` et supprimer `resume.json`.
