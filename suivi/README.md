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
id;nom;prenom;wan;classe
3;BELIBOU;Loredana;172.17.3.2;Jean-Louis
10;KENFACK;Stheve;;Hesdin
```

La colonne `classe` est libre (`Jean-Louis`, `Hesdin`, …) : elle sert au filtre du tableau de bord. Une adresse
`wan` vide signifie que les envois de l'étudiant ne sont pas encore reconnus ; ils apparaissent dans « Envois non
reconnus » jusqu'à ce que vous complétiez l'adresse. Vous pouvez corriger la fiche (nom, WAN, classe) directement
dans le tableau de bord : le fichier `classe.csv` du serveur est réécrit. Ce fichier contient des noms d'étudiants :
il **n'est pas** dans le dépôt (voir `.gitignore`). Un modèle est dans `classe.exemple.csv`.

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
| filtrer par classe | liens **Toutes / Jean-Louis / Hesdin** au-dessus du tableau (le filtre s'applique aussi à l'export CSV) |
| voir le détail d'un étudiant | cliquer sur son nom : relevé, dernier envoi et meilleur envoi par labo, historique, chaque rapport complet |
| corriger un étudiant | ✎ dans le tableau ou **Modifier la fiche** sur sa fiche : nom, prénom, adresse WAN, classe |
| relever toute la classe | bouton **Relever toute la classe** (tous les labos ou un seul). Moins d'une minute : tout part en parallèle |
| relever un seul étudiant | sa fiche → **Relever cet étudiant** |
| récupérer les scores | **Exporter en CSV** : pour chaque labo, relevé %, dernier envoi %, meilleur envoi % |
| relever en ligne de commande | `sudo -u www-data php /var/www/suivi/releve.php [--labo 05] [--etudiant 3]` |
| relancer seulement les sans-réponse | `… releve.php --non-releves` (ceux qui n'ont jamais répondu à une relève) |
| voir qui serait relancé, sans rien toucher | `… releve.php --non-releves --sans-agir` |

Avec `--cron`, deux tâches sont installées : la **classe complète** à l'heure choisie (jours de cours) et une
**relance toutes les heures de 8h à 19h** qui n'interroge **que les étudiants qui n'ont jamais répondu**
(journal séparé dans `/var/lib/suivi/relance.log`). Cette relance ne peut pas installer quoi que ce soit chez
l'étudiant : elle montre seulement, dans « relève impossible », qui doit encore faire
`git pull && bash install-prof.sh` (message « clé refusée ») ou dont la machine est éteinte.
La mise à jour automatique des machines étudiantes, elle, se fait sur les nœuds Proxmox (section suivante) ;
les deux horaires sont coordonnées : **10** sur les nœuds, **35** pour la relance du tableau de bord.

## Mettre à jour les machines des étudiants (nœuds Proxmox)

`maj-labos.sh` installe ou remet à jour le contrôle de labo **dans les machines qui en ont besoin**, sans
attendre l'étudiant. Il se lance **sur un nœud Proxmox, en root**, et ne traite que les machines de ce nœud.

| Commande | Effet |
|---|---|
| `bash install-maj-node.sh` | pose l'outil sur le nœud : `/usr/local/sbin/maj-labos.sh`, `/etc/admos-labos.conf`, tâche cron à **10 minutes de chaque heure de 8h à 19h** (jours de cours), journal `/var/log/admos-labos.log` |
| `bash maj-labos.sh --etat` | montre l'état de chaque machine (dépôt, clé de l'enseignant, `AllowUsers`), **ne rien changer** |
| `bash maj-labos.sh` | ne répare que ce qui est cassé : les machines déjà à jour ne sont pas touchées |
| `bash maj-labos.sh --id 18` | un seul étudiant (n° du plan d'adressage), pratique pour tester |

Comment ça rentre dans la machine : **l'agent invité QEMU** (`qm guest exec`, `pct exec` pour un conteneur),
donc en root local, exactement comme quand l'étudiant tape lui-même `git pull && bash install-prof.sh`.
Aucun port n'est ouvert vers la machine, aucun compte n'est ajouté, la clé de l'enseignant reste limitée à
`verif-lab`. Une machine sans `qemu-guest-agent` est signalée : seule solution, que l'étudiant l'installe.

Ce que le script change, et rien d'autre :

1. `git clone` / `git pull` du dépôt (dans le dossier déjà utilisé par l'étudiant s'il existe), puis
   `bash install-prof.sh` si la clé de l'enseignant du dépôt n'est pas dans `authorized_keys` du compte prof ;
2. le PC (10.68.69.10) est traité **avant** le routeur (10.68.69.1), qui a besoin de la clé publique du PC ;
   si le site HTTP du PC ne répond pas, la clé est lue dans `/var/lib/verif/id_ed25519.pub` sur le PC et passée
   avec `--cle-fichier` ;
3. si le durcissement sshd de l'étudiant (`AllowUsers`) bloque la relève, un fichier
   `/etc/ssh/sshd_config.d/90-admos-prof.conf` est ajouté avec une seule ligne : `AllowUsers prof@172.17.0.250`
   sur le routeur, `AllowUsers prof@10.68.69.1` sur le PC (le PC n'est jamais contacté directement, il voit le
   routeur qui a ouvert le tunnel). Les autres règles de l'étudiant restent actives ; le fichier est retiré si
   `sshd -t` refuse la configuration ou si `sshd -T` ne la reprend pas telle quelle.

Le script **ne touche jamais** aux fichiers de l'étudiant ni aux VM éteintes. Il signale (sans y toucher) les
machines au rôle indéterminable — ni 10.68.69.10 ni 10.68.69.1 : labo pas encore configuré, ou poste graphique.
Un étudiant qui a modifié un fichier du dépôt (`git pull` refusé) ou dont la machine ne sort pas sur Internet
doit réparer lui-même : c'est le cœur du labo.

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
  La mise à jour automatique (`maj-labos.sh`) n'ajoute aucun accès : elle passe par l'agent invité de la VM,
  comme l'étudiant qui taperait la commande lui-même, et la seule règle SSH ajoutée est l'adresse de la machine
  de l'enseignant pour le compte `prof` (compte sans mot de passe, commande `verif-lab` imposée, pas de shell).
  Sur le poste enseignant, `maj-labos.sh` et `install-maj-node.sh` sont copiés sur les nœuds Proxmox en root :
  ce sont les deux seuls fichiers déposés sur un nœud.
* **Données** : `/var/lib/suivi` (un fichier JSON par résultat dans `resultats/<id>/`, le résumé dans
  `resume.json`). Pour repartir de zéro en début d'année : vider `resultats/` et supprimer `resume.json`.
* **Modification de `classe.csv`** : elle se fait sur le serveur (fiche de l'étudiant). Si vous gardez une copie
  locale du fichier, reportez-y les changements ou utilisez l'export CSV comme copie de travail.
