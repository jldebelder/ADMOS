# Contrôle des labos

Un petit site (PHP) qui vérifie que votre laboratoire est fait dans les règles de l'art, et qui vous
dit **ce qui ne va pas, et comment le corriger**. Il couvre les labos : routage et NAT, DHCP,
SSH, Apache2 et PHP, iptables, fail2ban.

## Comment ça marche

```
  dupont-gui (Firefox)              dupont-pc (10.68.69.10)
  10.68.69.1xx (DHCP)               Apache2 + PHP : site de contrôle
        │  http://eafc.lab/verif/          │
        └────────────────────────────────► │  ssh -i clé du site  prof@…
                                           ├───► prof@10.68.69.10 ──► verif-lab (ce PC)
                                           └───► prof@10.68.69.1  ──► verif-lab (le routeur)
```

Les trois machines sont dans le même LAN 10.68.69.0/24 : **dupont-gui** n'est qu'un navigateur.

* Sur chaque machine, le compte **prof** n'a ni mot de passe ni shell utile : sa clé SSH ne peut lancer
  **qu'une seule commande**, `verif-lab`, qui **lit** la configuration et ne modifie rien.
* La clé du site est **générée sur votre machine** par l'installation : elle n'est dans aucun dépôt.

## Procédure (étudiants)

À faire **dans cet ordre**. Les étapes 1 et 2 se font en root (`su -`).

**1. Sur dupont-pc**

```bash
apt install -y git
git clone https://github.com/jldebelder/ADMOS.git
cd ADMOS/verif
bash install-prof.sh
```

**2. Sur dupont-routeur** (le script récupère tout seul la clé publique du site sur dupont-pc)

```bash
apt install -y git
git clone https://github.com/jldebelder/ADMOS.git
cd ADMOS/verif
bash install-prof.sh
```

**3. Démarrer le poste graphique dupont-gui** (dans Proxmox)

Clone complet du modèle `template-debian13-gui`, nom `dupont-gui`, une seule carte réseau sur **vmbr1 avec le même
VLAN Tag que dupont-pc**. Démarrez-la : elle reçoit son adresse du DHCP de votre routeur (`10.68.69.100` à `.200`).
Dans un terminal : `poste-graphique --test` (adresse, ping, `eafc.lab`, site de contrôle).

**4. Ouvrir le site et lancer la vérification** : dans Firefox sur dupont-gui, `http://eafc.lab/verif/`
(c'est la page d'accueil, et il y a aussi un lanceur « Contrôle du labo » dans le menu) → bouton **Lancer la vérification**.

Corrigez ce qui est en **KO** (rouge) ou **À AMÉLIORER** (jaune), en suivant le conseil affiché, puis relancez.
Le bouton **Télécharger le rapport (.txt)** donne un fichier à joindre à votre rapport de labo.

### Comment voir la page ?

1. **Poste graphique dupont-gui (recommandé)** : voir ci-dessus. Il est dans le LAN, `eafc.lab` y est déjà connu.
2. **Depuis votre portable, par un tunnel SSH passant par le routeur** :
   `ssh -L 8080:10.68.69.10:80 <utilisateur>@<adresse WAN du routeur 172.17.X.Y>`, puis `http://localhost:8080/verif/`.
3. **Sans navigateur** — rapport dans la console, sur chaque machine :
   ```bash
   verif-lab --texte
   ```
   ou, depuis dupont-pc : `curl -s -X POST -d action=run 'http://10.68.69.10/verif/?format=txt'`

## Ce qui est contrôlé

| Machine | Sections |
|---|---|
| **Routeur** (10.68.69.1) | cartes LAN/WAN, route par défaut, `ip_forward` (actif et permanent), MASQUERADE (actif et sauvegardé), Internet et DNS ; dnsmasq : service, limité au LAN, plage `.100–.200`, options 3 et 6, `dhcp-authoritative`, écoute udp/67, réservation `.10`, bail |
| **PC** (10.68.69.10) | adresse, passerelle, DNS, ping routeur / Internet ; SSH : `PermitRootLogin no`, `PasswordAuthentication no`, `MaxAuthTries 3`, `PubkeyAuthentication yes`, **test réel** que sshd refuse le mot de passe, clé ed25519 et droits 700/600 ; Apache2 : service, `configtest`, Virtual Host `eafc.lab`, DocumentRoot, droits, réponse HTTP, PHP relié, aucun `phpinfo` oublié ; iptables : `ESTABLISHED,RELATED`, ports 22/80/443, DROP **en dernier**, règles sauvegardées ; fail2ban : service, `jail.local`, jail `sshd`, `maxretry`, `bantime`, `ignoreip`, chaîne de blocage |
| **Les deux** | nom `prénom-rôle`, Debian 13, ressources (vCPU, mémoire, disque), dernier démarrage |

Un statut **INFO** (HTTPS, jail Apache2, durée du bail…) n'est pas compté dans le score.

Le « test réel » SSH tente une connexion locale avec un utilisateur inexistant : l'échec est voulu (il prouve que le mot de passe n'est plus proposé) et apparaît dans `auth.log`.

## Le poste graphique (préparation par l'enseignant, une seule fois)

Les adresses sont les mêmes dans le LAN de chaque étudiant : **un seul modèle** sert pour toute la classe.

```bash
# Dans une VM Debian 13 neuve (réseau en DHCP, une seule carte) :
apt install -y task-xfce-desktop firefox-esr       # bureau léger ; task-gnome-desktop convient aussi
bash poste-graphique.sh                            # eafc.lab dans /etc/hosts, page d'accueil, lanceur, commande de test
```

Éteignez la VM, puis **Convertir en modèle** : `template-debian13-gui` (nom à votre convenance). Chaque étudiant en fait un
clone `dupont-gui` sur vmbr1, avec le VLAN Tag de son PC.

* Prévoir environ 2 Go de RAM par poste avec XFCE ; le poste n'a besoin d'être allumé que pour les contrôles.
* La page d'accueil de Firefox passe par `/etc/firefox/policies/policies.json` : vérifiez-la sur le modèle. Sinon, le
  lanceur « Contrôle du labo » du menu fonctionne dans tous les cas.
* Le bail DHCP du poste est un bon test supplémentaire pour l'étudiant : le rapport du routeur le signale (INFO).

## Sécurité du compte prof

* Pas de mot de passe (`*` dans `/etc/shadow`) : seule la clé SSH ouvre la porte.
* `authorized_keys` : `restrict,command="sudo -n /usr/local/sbin/verif-lab" ssh-ed25519 …`
  → pas de shell, pas de tunnel, pas d'agent, une seule commande.
* `sudoers` : `prof ALL=(root) NOPASSWD: /usr/local/sbin/verif-lab ""` → ce script, **sans argument**.
* Le site n'est consultable que depuis `10.68.69.0/24` et `127.0.0.1`, et limite la fréquence des vérifications.
* `PasswordAuthentication no` et `PermitRootLogin no` restent intacts : le compte prof ne les affaiblit pas.

## Pour l'enseignant

**Publier** : déposer le contenu du dossier `ADMOS/` à la racine du dépôt `jldebelder/ADMOS`.
Si vous envoyez les fichiers par l'interface web de GitHub, le bit « exécutable » est perdu : c'est pour cela
que la procédure utilise `bash install-prof.sh`. Le fichier `.gitattributes` garde les scripts en fins de ligne LF.

**Votre propre clé** (facultatif) : collez votre clé publique dans `cle_enseignant.pub` avant de publier.
Elle est ajoutée au compte prof avec la même limitation. Depuis une VM à vous placée dans le VLAN d'un étudiant :
`ssh prof@10.68.69.10` renvoie le rapport brut (TSV), ou `curl -s -X POST -d action=run 'http://10.68.69.10/verif/?format=txt'`
pour un rapport lisible.

**Limite à connaître** : ce sont les machines de l'étudiant qui produisent le rapport. C'est un outil d'**auto-évaluation**
fiable pour guider le travail ; pour une note, relancez le contrôle vous-même (ou en présence de l'étudiant),
car un étudiant root pourrait modifier `verif-lab`.

**Adapter** : seuils et libellés sont dans `verif-lab.sh` (une fonction par section) ; adresses, utilisateur et délais
dans `site/config.php`. Après modification : `git pull` puis `bash install-prof.sh` sur la machine.

## Dépannage

| Symptôme | Cause probable | Que faire |
|---|---|---|
| dupont-gui n'a pas d'adresse 10.68.69.x | VLAN Tag différent de celui du routeur, ou dnsmasq arrêté | `poste-graphique --test`, puis `systemctl status dnsmasq` sur le routeur |
| Firefox n'ouvre pas le site (403) | le poste n'est pas dans 10.68.69.0/24 | vérifier l'adresse reçue (`ip -br a`) |
| Firefox : 404 ou page par défaut d'Apache | `eafc.lab` mal résolu, ou site non installé | `poste-graphique --test` ; `bash install-prof.sh` sur dupont-pc |
| « Contrôle impossible : connexion refusée… clé » | `install-prof.sh` pas lancé sur cette machine | le lancer (routeur : après le PC) |
| « machine injoignable » | adresse, VLAN ou routage | `ping 10.68.69.1` depuis le PC |
| « port 22 fermé » | sshd arrêté, ou iptables bloque le port 22 | `systemctl status ssh`, `iptables -L -n` |
| `AllowUsers` dans `sshd_config` | prof est refusé | ajouter `prof` à la liste, ou retirer la ligne |
| « empreinte SSH a changé » | machine recréée | bouton **Oublier les empreintes SSH** |
| Page blanche ou code PHP affiché | PHP non relié à Apache | `apt install libapache2-mod-php`, `systemctl restart apache2` |
| « Impossible d'écrire le résultat » | droits de `/var/lib/verif` | `chown www-data: /var/lib/verif` |
| Le routeur ne trouve pas la clé | Apache ou `eafc.lab` pas prêt sur le PC | sur le PC : `cat /var/www/eafc.lab/html/verif/cle.pub` ; sur le routeur : `bash install-prof.sh --cle "<la ligne>"` |

## Désinstaller

```bash
bash desinstaller-prof.sh
```
