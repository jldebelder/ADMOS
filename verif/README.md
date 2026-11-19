# Contrôle des labos

Un petit site (PHP) qui vérifie que votre laboratoire est fait dans les règles de l'art, et qui vous
dit **ce qui ne va pas, et comment le corriger**. Il couvre les dix labos : base Proxmox, routage et NAT,
DHCP, SSH/Apache2/iptables/fail2ban, SMTP, FTP, NFS, CUPS, OpenVPN et DNS. On peut contrôler **un seul labo**
ou **toute la configuration**. Chaque résultat est aussi transmis au serveur de suivi de l'enseignant
(voir [`../suivi/`](../suivi/README.md)).

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
(c'est la page d'accueil, et il y a aussi un lanceur « Contrôle du labo » dans le menu). Choisissez dans la liste
**le labo à contrôler** (ou « Toute la configuration »), puis **Lancer la vérification**. Pour « Toute la configuration »,
une grille donne le score de chaque labo.

Le résultat part automatiquement chez l'enseignant : la page affiche « Résultat transmis à l'enseignant ».

**Mise à jour** (nouveaux labos) : sur dupont-pc puis sur dupont-routeur, `cd ADMOS && git pull && cd verif && bash install-prof.sh`.

Corrigez ce qui est en **KO** (rouge) ou **À AMÉLIORER** (jaune), en suivant le conseil affiché, puis relancez.
Le bouton **Télécharger le rapport (.txt)** donne un fichier à joindre à votre rapport de labo.

### Comment voir la page ?

1. **Poste graphique dupont-gui (recommandé)** : voir ci-dessus. Il est dans le LAN, `eafc.lab` y est déjà connu.
2. **Depuis votre portable, par un tunnel SSH passant par le routeur** :
   `ssh -L 8080:10.68.69.10:80 <utilisateur>@<adresse WAN du routeur 172.17.X.Y>`, puis `http://localhost:8080/verif/`.
3. **Sans navigateur** — rapport dans la console, sur chaque machine :
   ```bash
   verif-lab --texte              # tous les labos
   verif-lab --texte --labo 05    # un seul labo (01 à 10) ; --labo 06,07 pour plusieurs
   verif-lab --liste              # numéros et titres des labos
   ```
   ou, depuis dupont-pc : `curl -s -X POST -d action=run -d labo=05 'http://10.68.69.10/verif/?format=txt'`

## Ce qui est contrôlé

| Labo | Routeur (10.68.69.1) | PC (10.68.69.10) |
|---|---|---|
| **01** Base Proxmox | agent QEMU actif, système à jour, serveur SSH, pas de bureau | idem |
| **02** Routage et NAT | cartes LAN/WAN, route par défaut, `ip_forward` (actif et permanent), MASQUERADE (actif et sauvegardé), Internet et DNS | adresse, passerelle, DNS, ping routeur / Internet |
| **03** DHCP | dnsmasq : service, limité au LAN, plage `.100–.200`, options 3 et 6, `dhcp-authoritative`, écoute udp/67, réservation `.10`, bail | carte en DHCP, bail reçu pour `.10` |
| **04** SSH, Apache, iptables, fail2ban | — | SSH : `PermitRootLogin no`, `PasswordAuthentication no`, `MaxAuthTries 3`, **test réel** ; Apache2 : Virtual Host `eafc.lab`, DocumentRoot, PHP, pas de `phpinfo` oublié ; iptables : ordre, DROP en dernier, sauvegarde ; fail2ban : jail `sshd`, `maxretry`, `bantime`, `ignoreip` |
| **05** SMTP | — | Postfix actif, `relayhost = [relay.edpnet.be]:25` (**port 25, sans authentification**), `inet_interfaces = loopback-only`, `mydestination` vide, `myhostname`, **le relais répond (bannière 220)**, `mail` installé, file d'attente vide, `status=sent` dans le journal, envoi à l'enseignant, envoi depuis le dernier démarrage, `documentation.txt` |
| **06** FTP | client lftp, port 21 du PC joignable | vsftpd : anonyme interdit, chroot, `local_root`, liste blanche, passif 50000-50100, FTPS forcé, compte `/bin/ftponly`, racine non writable + `ftp_data` writable, **test réel `AUTH TLS`**, pare-feu (21 + plage passive) sauvegardé |
| **07** NFS | nfs-common, `/mnt/data`, ligne fstab (`nfs4,_netdev,nofail`), autofs ou automount, partage monté en v4.x et lisible | nfs-server, `/srv/data` à `nobody:nogroup`, `/etc/exports` limité au LAN, `root_squash`, NFSv4 seul, port 2049 ouvert pour le LAN seulement |
| **08** CUPS | interface du PC joignable (631) | cups actif, écoute LAN, `_remote_admin`, groupe lpadmin, file PDF (cups-pdf), seconde imprimante, PDF produit, `Print-Job` dans le journal, pare-feu 631 |
| **09** OpenVPN | profil `.ovpn` (remote 10.68.69.10), tunnel ouvert, ping 10.8.0.1 | `/dev/net/tun`, service `openvpn@server`, UDP 1194, `tun0 = 10.8.0.1`, deux clients, révocation, pare-feu UDP 1194 |
| **10** DNS | `nameserver 10.68.69.10`, `search prenom.test`, résolution directe et inverse, Internet toujours résolu | bind9 : `named-checkconf`, zones `prenom.test` et `69.68.10.in-addr.arpa` (primary, `named-checkzone`), A, CNAME www, NS, PTR, NXDOMAIN, réponse sur l'adresse LAN, pare-feu 53 |
| **Toujours** | nom `prénom-rôle`, Debian 13, ressources (vCPU, mémoire, disque), dernier démarrage | idem |

Pour les labos 06 à 10, les contrôles de pare-feu ne s'appliquent que si le PC filtre l'entrée (DROP du labo 04) ;
sinon ils sont signalés en INFO.

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
* `authorized_keys` : `restrict,command="/usr/local/bin/verif-lab-ssh" ssh-ed25519 …`
  → pas de shell, pas de tunnel, pas d'agent, une seule commande.
* `verif-lab-ssh` n'accepte que `verif`, `verif tout` ou `verif 01` … `verif 10` (tout le reste est refusé),
  et lance `sudo -n /usr/local/sbin/verif-lab [--labo NN]`.
* `sudoers` : `prof ALL=(root) NOPASSWD: /usr/local/sbin/verif-lab ""` et une ligne par labo
  (`… verif-lab --labo 01` à `--labo 10`) → ce script, avec ces arguments exacts et aucun autre.
* Clé de l'enseignant (`cle_enseignant.pub`) : mêmes limites ; **sur le routeur seulement**, elle peut en plus
  ouvrir un tunnel, et un seul : vers `10.68.69.10:22` (`port-forwarding,permitopen="10.68.69.10:22"`). C'est ce qui
  permet la relève du PC depuis le serveur de suivi.
* Le site n'est consultable que depuis `10.68.69.0/24` et `127.0.0.1`, et limite la fréquence des vérifications.
* `PasswordAuthentication no` et `PermitRootLogin no` restent intacts : le compte prof ne les affaiblit pas.

## Pour l'enseignant

**Publier** : déposer le contenu du dossier `ADMOS/` à la racine du dépôt `jldebelder/ADMOS`.
Si vous envoyez les fichiers par l'interface web de GitHub, le bit « exécutable » est perdu : c'est pour cela
que la procédure utilise `bash install-prof.sh`. Le fichier `.gitattributes` garde les scripts en fins de ligne LF.

**Votre clé** : collez dans `cle_enseignant.pub` la clé publique affichée par `install-suivi.sh` (serveur de suivi),
avant de publier. Elle permet la relève de toute la classe depuis vmbr0 :
`ssh prof@<WAN du routeur> 'verif 05'` pour le routeur, et pour le PC, à travers le routeur :
`ssh -o ProxyCommand="ssh -W %h:%p prof@<WAN>" prof@10.68.69.10 'verif 05'`.

**Envoi au suivi** : l'adresse du serveur est `suivi_url` dans `site/config.php` (vide = pas d'envoi).

**Limite à connaître** : ce sont les machines de l'étudiant qui produisent le rapport. C'est un outil d'**auto-évaluation**
fiable pour guider le travail ; pour une note, fiez-vous à la **relève** du serveur de suivi (que vous déclenchez
vous-même), de préférence en présence de l'étudiant, car un étudiant root pourrait modifier `verif-lab`.

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
| « Demande refusée » ou un seul rapport complet quel que soit le labo | `verif-lab-ssh` absent (ancienne installation) | `git pull` puis `bash install-prof.sh` sur les deux machines |
| « Résultat non transmis à l'enseignant » | serveur de suivi éteint, ou routage/NAT du routeur | le contrôle reste valable ; réessayer plus tard |
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
