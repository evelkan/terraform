# Terraform — Déploiement de Laboratoires Virtuels avec Terraform et Debian 12

Projet pédagogique visant à automatiser, avec Terraform, le déploiement et la gestion de machines virtuelles Debian 12 sous VMware Workstation Pro, à l'aide du provider communautaire [`elsudano/vmworkstation`](https://registry.terraform.io/providers/elsudano/vmworkstation) (v1.0.4).

**Environnement** : Linux Mint 22.3 (hôte) · VMware Workstation Pro · Terraform CLI

---

## Sommaire

- [Étape 1 : Préparation de l'environnement](#étape-1--préparation-de-lenvironnement)
- [Étape 2 : Installation de Terraform et du provider VMware Workstation](#étape-2--installation-de-terraform-et-du-provider-vmware-workstation)
- [Étape 3 : Premier déploiement de VM Debian 12](#étape-3--premier-déploiement-de-vm-debian-12)
- [Étape 4 : Amélioration et gestion du cycle de vie](#étape-4--amélioration-et-gestion-du-cycle-de-vie)
- [Étape 5 : Laboratoire de Cybersécurité simple](#étape-5--laboratoire-de-cybersécurité-simple)
- [Pour aller plus loin : intégration Ansible](#pour-aller-plus-loin--intégration-ansible)
- [Structure finale du dépôt](#structure-finale-du-dépôt)

---

## Étape 1 : Préparation de l'environnement

### Objectif

Avant d'écrire la moindre ligne de code Terraform, il faut disposer d'une VM Debian 12 de référence (le "template") que le provider VMware Workstation pourra cloner automatiquement. Terraform ne crée pas une VM depuis une ISO : il **clone** une VM existante déjà installée et configurée.

### Prérequis de la VM template

| Prérequis | Raison |
|---|---|
| Serveur SSH actif | Seul moyen pour Terraform de se connecter à la VM clonée et d'exécuter des provisioners (`remote-exec`) |
| Pas d'interface graphique | Allège le clone, accélère le boot — essentiel avec plusieurs VMs déployées en parallèle |
| Open-VM-Tools installés | Permet à VMware (et donc à Terraform) de récupérer l'adresse IP de la VM clonée |
| Utilisateur standard avec accès `sudo` | Terraform et les provisioners se connectent avec cet utilisateur, jamais en root |

### Procédure réalisée

1. Création de la VM dans VMware Workstation Pro à partir de l'ISO Debian 12.
2. Installation minimale : seules les options *standard system utilities* et *SSH server* sélectionnées lors du `tasksel` (pas d'environnement de bureau).
3. Création d'un utilisateur standard, ajouté au groupe `sudo` :
   ```bash
   su -
   apt update && apt install -y sudo
   usermod -aG sudo mon_utilisateur
   ```
4. Installation et activation du serveur SSH (si nécessaire) :
   ```bash
   apt install -y openssh-server
   systemctl enable ssh
   systemctl start ssh
   ```
5. Installation d'Open-VM-Tools :
   ```bash
   apt install -y open-vm-tools
   ```
6. Extinction propre de la VM avant clonage :
   ```bash
   sudo shutdown now
   ```
   > Une VM template doit impérativement être éteinte avant que Terraform ne la clone : VMware ne peut pas cloner une VM en cours d'exécution.

### Résultat

Chemin du fichier `.vmx` de la VM template, noté pour être réutilisé dans `main.tf` :
```
/home/anna/vmware/Debian12-Base/Debian12-Base.vmx
```

---

## Étape 2 : Installation de Terraform et du provider VMware Workstation

### Objectif

Installer le binaire Terraform CLI sur la machine hôte (celle qui pilote VMware Workstation), puis préparer VMware Workstation Pro pour qu'il accepte d'être piloté par Terraform via le provider `elsudano/vmworkstation`.

### 2.1 Installation de Terraform CLI

```bash
# Ajout des dépendances et de la clé GPG HashiCorp
sudo apt update && sudo apt install -y gnupg software-properties-common wget
wget -O- https://apt.releases.hashicorp.com/gpg | \
  gpg --dearmor | sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg > /dev/null

# Ajout du dépôt HashiCorp
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
  sudo tee /etc/apt/sources.list.d/hashicorp.list
```

> Terraform n'est pas disponible dans les dépôts officiels Debian (ou alors dans une version ancienne). Le dépôt HashiCorp garantit la dernière version stable, avec mise à jour facile via `apt`.

**Difficulté rencontrée** : sur la machine hôte Linux Mint, `$(lsb_release -cs)` renvoie le nom de code Mint (ex : `zena` pour Mint 22.3), inconnu du dépôt HashiCorp, qui ne référence que des codenames Debian/Ubuntu → `404 Not Found` sur `.../zena Release`.

**Solution appliquée** : remplacer le codename par celui de la version Ubuntu sous-jacente (Mint 22.x → Ubuntu 24.04 "noble") :
```bash
sudo rm /etc/apt/sources.list.d/hashicorp.list
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
https://apt.releases.hashicorp.com noble main" | \
  sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install -y terraform
```

**Seconde difficulté, distincte** : à un moment du projet, cette procédure a par erreur été exécutée **dans la VM Debian** (session SSH) plutôt que sur l'hôte Linux Mint — le prompt `debian@debian:~$` en est la preuve (au lieu de `anna@anna:~$`). Le dépôt HashiCorp s'est alors installé avec le codename `bookworm` (celui de Debian), et Terraform a fini installé au mauvais endroit, invisible depuis l'hôte qui pilote pourtant VMware Workstation. Ce mélange hôte/VM a causé plusieurs erreurs `terraform: commande introuvable` plus tard dans le projet.

> **Point de vigilance retenu** : toujours vérifier le prompt (`anna@anna` = hôte, `debian@debian` = VM) avant toute commande liée à Terraform ou VMware Workstation.

Vérification :
```bash
terraform -version
```

### 2.2 Activation de l'API `vmrest` sur VMware Workstation Pro

Le provider `elsudano/vmworkstation` ne communique pas directement avec le processus VMware : il passe par une API REST fournie par VMware elle-même, `vmrest`, qu'il faut activer avec des identifiants dédiés.

> **Important** : `vmrest` est un composant de VMware Workstation Pro, installé sur la **machine hôte** (ici Linux Mint), pas dans la VM Debian.

Sur cette installation, `vmrest` a été retrouvé directement dans le `PATH` :
```bash
$ sudo find / -iname "vmrest" 2>/dev/null
/usr/bin/vmrest
/usr/lib/vmware/bin/vmrest
```

```bash
# Configuration du service (définit un user/password dédiés à l'API)
vmrest --config

# Démarrage du service (à garder actif tant que Terraform pilote VMware)
vmrest
```

Le mot de passe doit respecter une politique de complexité imposée par `vmrest` (minimum 8 caractères, au moins une minuscule, un chiffre et un caractère spécial). Une fois les identifiants acceptés :
```
Serving HTTP on 127.0.0.1:8697
Press Ctrl+C to stop.
```

> **Note** : le service sert l'API en **HTTP** (et non HTTPS) sur `127.0.0.1:8697` par défaut. L'endpoint déclaré dans le provider Terraform doit donc utiliser `http://`, pas `https://`. Le terminal doit rester ouvert avec ce processus actif tant que des commandes Terraform sont exécutées.
>
> Les identifiants `vmrest` sont indépendants du compte utilisateur système de la VM Debian créée à l'étape 1 : ce sont ceux que Terraform utilise pour dialoguer avec VMware Workstation lui-même (créer/cloner/détruire des VMs), pas pour se connecter en SSH dedans.

### 2.3 Création du répertoire de projet

À exécuter sur la machine hôte, pas dans la VM Debian :
```bash
mkdir terraform_debian_lab
cd terraform_debian_lab
```

### 2.4 Déclaration du provider dans le code Terraform

```hcl
terraform {
  required_providers {
    vmworkstation = {
      source  = "elsudano/vmworkstation"
      version = "~> 1.0.4"
    }
  }
  required_version = ">= 1.0.0"
}

provider "vmworkstation" {
  user     = var.vmws_user
  password = var.vmws_password
  url      = "http://127.0.0.1:8697"
  https    = false
  debug    = false
}
```

`terraform init` se chargera de télécharger automatiquement ce provider depuis le Terraform Registry.

**Difficulté** : l'API `vmrest` doit rester active en arrière-plan pendant toute la durée d'utilisation de Terraform (`plan`, `apply`, `destroy`). Si le service s'arrête ou que VMware Workstation est fermé, les commandes Terraform échoueront avec une erreur de connexion à l'endpoint.

---

## Étape 3 : Premier déploiement de VM Debian 12

### Objectif

Écrire la configuration Terraform qui clone la VM template pour créer une nouvelle VM Debian 12, puis exécuter le cycle `init` / `plan` / `apply`.

### 3.1 Récupérer l'identifiant (`sourceid`) de la VM template

```bash
curl -u <vmrest_user>:<vmrest_password> http://127.0.0.1:8697/api/vms
```

**Difficulté rencontrée** : si le mot de passe `vmrest` contient un `!` (imposé par la politique de complexité), Bash l'interprète comme un déclencheur d'expansion d'historique et renvoie `bash: !: event not found`, même entre guillemets simples.

**Solution** : échapper le `!` avec un antislash, ou désactiver temporairement l'expansion d'historique :
```bash
curl -u anna:MonMotDePasse\! http://127.0.0.1:8697/api/vms
# ou
set +H
curl -u anna:MonMotDePasse! http://127.0.0.1:8697/api/vms
```

Réponse obtenue :
```json
[
  {
    "id": "NAD9PIJQJF6DULO6ADTFU2LCSEVTNQEQ",
    "path": "/home/anna/vmware/Debian12-Base/Debian12-Base.vmx"
  }
]
```

Le champ `id` correspondant au chemin de la VM template est la valeur à utiliser comme `sourceid` : `NAD9PIJQJF6DULO6ADTFU2LCSEVTNQEQ`.

### 3.2 Fichier de variables (`variables.tf`)

```hcl
variable "vmws_user" {
  description = "Identifiant de l'API vmrest (VMware Workstation)"
  type        = string
}

variable "vmws_password" {
  description = "Mot de passe de l'API vmrest"
  type        = string
  sensitive   = true
}

variable "vmws_endpoint" {
  description = "URL complète de l'API vmrest, incluant le suffixe /api"
  type        = string
  default     = "http://127.0.0.1:8697/api"
}

variable "template_sourceid" {
  description = "ID vmrest de la VM template Debian 12 (récupéré via GET /api/vms)"
  type        = string
}
```

### 3.3 Fichier de valeurs (`terraform.tfvars`)

> ⚠️ Ce fichier contient des identifiants sensibles : il doit être ajouté au `.gitignore` avant tout `git push`.

```hcl
vmws_user         = "anna"
vmws_password     = "<mot_de_passe_vmrest>"
template_sourceid = "NAD9PIJQJF6DULO6ADTFU2LCSEVTNQEQ"
```

### 3.4 Fichier principal (`main.tf`)

```hcl
terraform {
  required_providers {
    vmworkstation = {
      source  = "elsudano/vmworkstation"
      version = "~> 1.0.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
  required_version = ">= 1.0.0"
}

provider "vmworkstation" {
  user     = var.vmws_user
  password = var.vmws_password
  url      = var.vmws_endpoint
  https    = false
  debug    = false
}

resource "random_id" "vm_suffix" {
  byte_length = 4
}

resource "vmworkstation_vm" "debian_lab" {
  sourceid     = var.template_sourceid
  denomination = "debian-vm-${random_id.vm_suffix.hex}"
  description  = "Première VM Debian 12 déployée via Terraform"
  path         = "/home/anna/vmware/debian-vm-${random_id.vm_suffix.hex}/debian-vm-${random_id.vm_suffix.hex}.vmx"
  processors   = 2
  memory       = 2048
}

output "vm_id" {
  value = vmworkstation_vm.debian_lab.id
}
```

**Difficultés rencontrées et résolues :**

1. **`EOF` sans message exploitable** au premier `terraform apply`. Diagnostic par reproduction manuelle avec `curl -v` (ciblant directement `POST /api/vms`), révélant le vrai message d'erreur caché : `Code 107 — "The virtual machine is not powered off"`.
   *Cause* : la VM template n'était pas complètement éteinte.
   *Solution* : arrêt propre via VMware Workstation (VM → Power → Shut Down Guest) avant tout clonage.

2. **URL incomplète** : l'erreur `connection refused` provenait d'une URL `http://127.0.0.1:8697/vms` (sans `/api`) construite à partir de la variable d'endpoint.
   *Solution* : inclure `/api` directement dans `vmws_endpoint`.

3. **`"One of the parameters was invalid: path"`** puis **`"The virtual machine already exists"`** en boucle.
   *Cause identifiée* (confirmée par la communauté du provider en v1.0.4) : l'attribut `path` doit correspondre exactement à l'emplacement par défaut des VMs configuré dans VMware Workstation (Edit → Preferences → Workspace), pas à un chemin arbitraire ; le provider ne crée pas de nouvelle arborescence. De plus, chaque tentative échouée laissait une "VM fantôme" dans l'inventaire `vmrest`, bloquant les tentatives suivantes avec le même nom.
   *Solution* : aligner `path` sur l'emplacement réel par défaut, et ajouter `random_id` pour générer un nom unique à chaque apply.

Résultat obtenu :
```
random_id.vm_suffix: Creating...
random_id.vm_suffix: Creation complete after 0s [id=rCDKBw]
vmworkstation_vm.debian_lab: Creating...
vmworkstation_vm.debian_lab: Creation complete after 7s [id=4AS6Q6042EQKCK78L6PUG129OMI1H5OI]

Apply complete! Resources: 2 added, 0 changed, 0 destroyed.

Outputs:
vm_id = "4AS6Q6042EQKCK78L6PUG129OMI1H5OI"
```

### 3.5 Exécution des commandes Terraform

```bash
terraform init   # télécharge le provider depuis le Terraform Registry
terraform plan   # affiche le plan d'exécution sans rien modifier
terraform apply  # applique le plan : clone effectivement la VM
```

> `terraform apply` recalcule et affiche automatiquement le même plan que `terraform plan` avant de demander confirmation (`yes`) — en pratique, `apply` = `plan` + confirmation + exécution en une seule commande. Lancer `plan` séparément reste une bonne pratique pour vérifier les changements sans risque.

**Ce que fait chaque commande :**

| Commande | Effet |
|---|---|
| `terraform init` | Télécharge le provider déclaré dans `required_providers`, initialise `.terraform/` et `.terraform.lock.hcl` |
| `terraform plan` | Compare l'état désiré (le code `.tf`) à l'état réel et affiche les actions prévues (`+ create`) sans les exécuter |
| `terraform apply` | Exécute réellement les actions du plan : clonage de la VM template |

**Vérification** : une fois `apply` terminé, la VM clonée doit apparaître dans la bibliothèque VMware Workstation, et un fichier `terraform.tfstate` doit avoir été créé — c'est le fichier qui permet à Terraform de savoir ce qu'il a créé, pour les prochaines exécutions.

---

## Étape 4 : Amélioration et gestion du cycle de vie

### 4.1 Utilisation de variables

Toutes les valeurs sensibles ou spécifiques à la machine (identifiants `vmrest`, `sourceid` de la template, endpoint de l'API) ont été externalisées dans `variables.tf` / `terraform.tfvars`, plutôt que codées en dur dans `main.tf`. Cela permet de réutiliser le même code en ne changeant qu'un seul fichier (`terraform.tfvars`), sans toucher à la logique.

| Variable | Rôle |
|---|---|
| `vmws_user` / `vmws_password` | Identifiants de connexion à l'API `vmrest` |
| `vmws_endpoint` | URL de l'API `vmrest` (avec `/api`) |
| `template_sourceid` | ID de la VM template à cloner |

### 4.2 Gestion des modifications

Terraform ne se limite pas à la création : si on modifie le code `.tf` puis qu'on relance `apply`, Terraform compare l'état désiré (le code) à l'état réel (`terraform.tfstate`) et applique uniquement la différence (`~ update in-place`), sans tout recréer quand c'est possible.

**Exemple** : augmenter les ressources de la VM créée.

```hcl
resource "vmworkstation_vm" "debian_lab" {
  # ...
  processors = 4     # 2 → 4
  memory     = 4096   # 2048 → 4096
}
```

```bash
terraform plan
```
```
~ resource "vmworkstation_vm" "debian_lab" {
    ~ memory     = 2048 -> 4096
    ~ processors = 2 -> 4
      # (autres attributs inchangés)
  }

Plan: 0 to add, 1 to change, 0 to destroy.
```

```bash
terraform apply
```
```
vmworkstation_vm.debian_lab: Modifying... [id=4AS6Q6042EQKCK78L6PUG129OMI1H5OI]
vmworkstation_vm.debian_lab: Modifications complete after 0s [id=4AS6Q6042EQKCK78L6PUG129OMI1H5OI]

Apply complete! Resources: 0 added, 1 changed, 0 destroyed.
```

L'`id` de la VM reste identique avant/après : Terraform a bien modifié la VM existante en place, sans la recréer.

> **Point d'attention** : `random_id.vm_suffix` n'est régénéré que si sa ressource est explicitement recréée (ex. après un `destroy` puis `apply`) — un apply de modification n'en génère pas un nouveau.

### 4.3 Destruction de l'infrastructure

```bash
terraform destroy
```
```
Plan: 0 to add, 0 to change, 2 to destroy.

Do you really want to destroy all resources?
  Terraform will destroy all your managed infrastructure, as shown above.
  There is no undo. Only 'yes' will be accepted to confirm.

  Enter a value: yes

vmworkstation_vm.debian_lab: Destroying... [id=4AS6Q6042EQKCK78L6PUG129OMI1H5OI]
vmworkstation_vm.debian_lab: Destruction complete after 0s
random_id.vm_suffix: Destroying... [id=rCDKBw]
random_id.vm_suffix: Destruction complete after 0s

Destroy complete! Resources: 2 destroyed.
```

> **Note** : `terraform destroy` ne supprime que les ressources suivies dans `terraform.tfstate`, c'est-à-dire celles créées par Terraform lui-même. Une VM créée manuellement en dehors de Terraform (par exemple via un appel `curl` direct à l'API `vmrest`, lors des tests de diagnostic de l'étape 3.4) n'apparaît pas dans le state et n'est donc jamais nettoyée automatiquement, même après un `destroy`.
>
> Vérification après coup : `curl -u anna:<mot_de_passe> http://127.0.0.1:8697/api/vms` a bien confirmé la disparition de la VM gérée par Terraform, mais aussi la persistance d'une VM de test créée manuellement plus tôt (`debian-vm-01`), nécessitant un nettoyage manuel séparé (`curl ... -X DELETE` + `rm -rf`). Rappel du principe central de l'Infrastructure as Code : **Terraform ne gère que ce qui existe dans son propre état, pas l'ensemble de l'infrastructure réelle.**

---

## Étape 5 : Laboratoire de Cybersécurité simple

### Objectif

Déployer deux VMs à partir de la même template Debian 12 : une VM "attaquante" (outils de reconnaissance réseau) et une VM "victime" (service vulnérable exposé), sur le même réseau virtuel, pour simuler un scénario basique de reconnaissance/exploitation.

### 5.1 Limitation majeure découverte : pas d'IP exposée par le provider

```bash
terraform providers schema -json | python3 -m json.tool | grep -A 30 '"vmworkstation_vm"'
```

La resource `vmworkstation_vm` (v1.0.4) n'expose que 7 attributs : `denomination`, `description`, `id`, `memory`, `path`, `processors`, `sourceid`. **Aucun attribut d'adresse IP n'est exposé**, et aucun data source ne comble ce manque. Impossible donc d'utiliser un bloc `connection { host = self.ip_address }` dans un provisioner `remote-exec` classique — approche pourtant documentée dans de nombreux exemples génériques, mais qui ne fonctionne pas avec ce provider précis.

**Solution retenue** : l'API `vmrest` expose de son côté un endpoint dédié, `GET /api/vms/{id}/ip`, capable de renvoyer l'adresse IP d'une VM (une fois qu'Open-VM-Tools l'a remontée). On contourne donc la limitation du provider en utilisant :
- des resources `vmworkstation_vm` sans provisioner intégré (clonage pur, comme aux étapes 3-4) ;
- une resource `null_resource` avec un provisioner `local-exec` (exécuté sur l'hôte, pas dans la VM) qui interroge l'IP via `curl` sur `vmrest`, attend qu'elle soit disponible, puis se connecte elle-même en SSH pour lancer les commandes d'installation.

### 5.2 Fichier `main.tf` complet du laboratoire

```hcl
terraform {
  required_providers {
    vmworkstation = {
      source  = "elsudano/vmworkstation"
      version = "~> 1.0.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
  required_version = ">= 1.0.0"
}

provider "vmworkstation" {
  user     = var.vmws_user
  password = var.vmws_password
  url      = var.vmws_endpoint
  https    = false
  debug    = false
}

resource "random_id" "lab_suffix" {
  byte_length = 4
}

# --- VM 1 : Attaquant ---
resource "vmworkstation_vm" "kali_like" {
  sourceid     = var.template_sourceid
  denomination = "kali-like-vm-${random_id.lab_suffix.hex}"
  description  = "VM attaquante (Debian + outils reseau) - simule un Kali"
  path         = "/home/anna/vmware/kali-like-vm-${random_id.lab_suffix.hex}/kali-like-vm-${random_id.lab_suffix.hex}.vmx"
  processors   = 2
  memory       = 2048
}

# --- Provisioning de kali-like-vm via l'IP recuperee depuis vmrest ---
resource "null_resource" "provision_kali_like" {
  depends_on = [vmworkstation_vm.kali_like]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      curl -s -u ${var.vmws_user}:${var.vmws_password} -X PUT \
        ${var.vmws_endpoint}/vms/${vmworkstation_vm.kali_like.id}/power \
        -H "Content-Type: application/vnd.vmware.vmw.rest-v1+json" -d 'on'

      IP=""
      for i in $(seq 1 30); do
        IP=$(curl -s -u ${var.vmws_user}:${var.vmws_password} \
          ${var.vmws_endpoint}/vms/${vmworkstation_vm.kali_like.id}/ip \
          | python3 -c "import sys,json; print(json.load(sys.stdin).get('ip',''))" 2>/dev/null || true)
        if [ -n "$IP" ]; then break; fi
        sleep 5
      done
      if [ -z "$IP" ]; then echo "IP introuvable" && exit 1; fi
      echo "IP kali-like-vm : $IP"

      sshpass -p '${var.ssh_password}' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        ${var.ssh_user}@$IP "echo '${var.ssh_password}' | sudo -S apt update && echo '${var.ssh_password}' | sudo -S apt install -y nmap masscan"
    EOT
  }
}

resource "vmworkstation_vm" "victim" {
  depends_on   = [vmworkstation_vm.kali_like]
  sourceid     = var.template_sourceid
  denomination = "victim-vm-${random_id.lab_suffix.hex}"
  description  = "VM victime exposant un service web vulnerable"
  path         = "/home/anna/vmware/victim-vm-${random_id.lab_suffix.hex}/victim-vm-${random_id.lab_suffix.hex}.vmx"
  processors   = 2
  memory       = 2048
}

resource "null_resource" "provision_victim" {
  depends_on = [vmworkstation_vm.victim]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -e
      curl -s -u ${var.vmws_user}:${var.vmws_password} -X PUT \
        ${var.vmws_endpoint}/vms/${vmworkstation_vm.victim.id}/power \
        -H "Content-Type: application/vnd.vmware.vmw.rest-v1+json" -d 'on'

      IP=""
      for i in $(seq 1 30); do
        IP=$(curl -s -u ${var.vmws_user}:${var.vmws_password} \
          ${var.vmws_endpoint}/vms/${vmworkstation_vm.victim.id}/ip \
          | python3 -c "import sys,json; print(json.load(sys.stdin).get('ip',''))" 2>/dev/null || true)
        if [ -n "$IP" ]; then break; fi
        sleep 5
      done
      if [ -z "$IP" ]; then echo "IP introuvable" && exit 1; fi
      echo "IP victim-vm : $IP"

      sshpass -p '${var.ssh_password}' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        ${var.ssh_user}@$IP "echo '${var.ssh_password}' | sudo -S apt update && echo '${var.ssh_password}' | sudo -S apt install -y python3"
      sshpass -p '${var.ssh_password}' ssh -f -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        ${var.ssh_user}@$IP "nohup python3 -m http.server 8080 < /dev/null > /tmp/http.log 2>&1 &"
    EOT
  }
}
```

**Pourquoi `sshpass`** : l'authentification SSH par mot de passe demande normalement une saisie interactive, incompatible avec un script automatisé. `sshpass -p '<mot_de_passe>' ssh ...` fournit le mot de passe de façon non interactive.
```bash
sudo apt install -y sshpass
```

**Pourquoi une boucle `for`/`sleep`** : juste après le clonage, la VM démarre et met un peu de temps avant qu'Open-VM-Tools ne remonte son adresse IP à `vmrest`. La boucle réessaie toutes les 5 secondes, jusqu'à 30 fois (2 min 30 max), plutôt que d'échouer immédiatement.

**Pourquoi `depends_on = [vmworkstation_vm.kali_like]` sur `victim`** : sans cette dépendance explicite, Terraform clone les deux VMs en parallèle, ce qui provoque une erreur `"The virtual machine has been locked"` — les deux clonages entrent en conflit sur l'accès à la template source. Le forcer en séquentiel règle le problème.

**Pourquoi deux connexions SSH séparées pour `victim`, avec `ssh -f` sur la seconde** : une première tentative chaînant tout en une seule commande (`apt update && apt install && nohup ... &`) provoquait un blocage de la session SSH pendant plusieurs dizaines de minutes, même avec `nohup` et une redirection de stdin (`< /dev/null`). Le `&` final ne suffisait pas à détacher proprement la commande de la session. Solution fiable : séparer l'installation (SSH classique, bloquant, qui se termine normalement) du lancement du serveur (SSH avec l'option `-f`, qui fait passer `ssh` lui-même en arrière-plan juste après authentification, sans attendre la fin de la commande distante).

**Pourquoi `sudo -S`** : `sudo` demande normalement une saisie interactive du mot de passe depuis un vrai terminal, ce qui n'existe pas dans une commande SSH non-interactive lancée depuis un script (erreur *"un terminal est requis pour lire le mot de passe"*). L'option `-S` fait lire ce mot de passe depuis l'entrée standard, alimentée ici par `echo '<mot_de_passe>' | sudo -S ...`.

### 5.3 Nouvelles variables nécessaires (`variables.tf`)

```hcl
variable "ssh_user" {
  description = "Utilisateur SSH pour se connecter aux VMs déployées (créé à l'étape 1)"
  type        = string
}

variable "ssh_password" {
  description = "Mot de passe SSH de l'utilisateur standard de la VM"
  type        = string
  sensitive   = true
}
```

Et dans `terraform.tfvars` :
```hcl
ssh_user     = "anna"
ssh_password = "<mot_de_passe_utilisateur_debian>"
```

### 5.4 Déploiement et vérification

```bash
sudo apt install -y sshpass   # si pas déjà présent

terraform init
terraform plan
terraform apply
```

> `terraform apply` clone les deux VMs, puis exécute automatiquement les `null_resource` qui récupèrent leur IP et installent les outils via SSH ; cette dernière partie peut prendre 1 à 3 minutes le temps que les VMs démarrent et qu'Open-VM-Tools remonte leur IP.

Récupération des IPs des deux VMs via l'API `vmrest` (non exposées en output direct, le provider ne les fournit pas comme attribut) :
```bash
curl -u <vmrest_user>:<vmrest_password> http://127.0.0.1:8697/api/vms | python3 -m json.tool
curl -u <vmrest_user>:<vmrest_password> http://127.0.0.1:8697/api/vms/<ID_de_la_VM>/ip
```

Vérification manuelle de la connectivité et de l'interaction entre les deux VMs :
```bash
# Se connecter à la VM attaquante
ssh anna@<ip_kali_like>

# Depuis kali-like-vm, scanner la VM victime
nmap -p 8080 <ip_victim>

# Interagir avec le service vulnérable
curl http://<ip_victim>:8080
```

**Résultat obtenu et validé, depuis `kali-like-vm` :**
```
debian@debian:~$ which nmap masscan
/usr/bin/nmap
/usr/bin/masscan

debian@debian:~$ nmap -p 8080 172.16.197.136
Starting Nmap 7.93 ( https://nmap.org )
Nmap scan report for 172.16.197.136
Host is up (0.0051s latency).

PORT     STATE SERVICE
8080/tcp open  http-proxy

debian@debian:~$ wget -qO- http://172.16.197.136:8080
<!DOCTYPE HTML>
<html lang="en">
<head><title>Directory listing for /</title></head>
<body>
<h1>Directory listing for /</h1>
<ul>
<li><a href=".bash_history">.bash_history</a></li>
<li><a href=".bashrc">.bashrc</a></li>
...
</ul>
</body>
</html>
```

Le scénario est validé de bout en bout : la VM attaquante détecte le port ouvert sur la victime, puis interagit avec le service exposé et récupère son contenu.

> **Point d'attention (persistance après redémarrage de l'hôte)** : le service `vmrest`, ainsi que le serveur web Python lancé en mémoire sur `victim-vm` (via `nohup ... &`), ne survivent pas à un redémarrage de la machine hôte. Après un reboot, il faut : relancer `vmrest`, rallumer les VMs via l'API (`PUT .../power` avec `on`), puis relancer manuellement `python3 -m http.server 8080` en SSH sur `victim-vm`. Terraform ne gère pas ce redémarrage automatiquement — une limitation à connaître pour toute reprise de session.

---

## Pour aller plus loin : intégration Ansible

Terraform excelle à créer et détruire de l'infrastructure (provisionner des VMs, réseaux, etc.), mais son mécanisme de provisioning (`local-exec`/`remote-exec`) reste rudimentaire pour la configuration logicielle : pas de gestion d'idempotence native, pas de rapport détaillé des changements, scripts shell vite difficiles à maintenir (comme constaté avec les commandes `sshpass`/`sudo -S` de l'étape 5).

Ansible est dédié à la configuration de machines : on lui décrit un état désiré (*"nmap doit être installé"*, *"ce service doit tourner"*), et il l'atteint de façon idempotente (relancer le playbook sur une machine déjà configurée ne fait rien de plus, contrairement à un script shell qui referait `apt install` à chaque fois).

**Répartition des rôles :**
- **Terraform** : crée/détruit les VMs (le "quoi" de l'infrastructure)
- **Ansible** : configure le contenu de ces VMs (le "comment" logiciel)

### Prérequis

```bash
sudo apt install -y ansible
```

### 1. Fichier d'inventaire dynamique (`inventory.ini`)

Plutôt que de coder les IPs en dur, l'inventaire est généré à partir des sorties Terraform :

```bash
cat > inventory.ini << EOF
[attaquant]
kali-like ansible_host=$(curl -s -u ${vmws_user}:${vmws_password} \
  ${vmws_endpoint}/vms/$(terraform output -raw kali_like_id 2>/dev/null)/ip \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['ip'])")

[victime]
victim ansible_host=$(curl -s -u ${vmws_user}:${vmws_password} \
  ${vmws_endpoint}/vms/$(terraform output -raw victim_id 2>/dev/null)/ip \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['ip'])")

[lab:children]
attaquant
victime

[lab:vars]
ansible_user=debian
ansible_ssh_pass=<mot_de_passe>
ansible_become_pass=<mot_de_passe>
ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
EOF
```

> Nécessiterait d'ajouter deux `output` supplémentaires dans `main.tf` (`kali_like_id`, `victim_id`) pour automatiser entièrement cette génération.

### 2. Playbook Ansible (`playbook.yml`)

```yaml
---
- name: Configurer la VM attaquante
  hosts: attaquant
  become: true
  tasks:
    - name: Mettre à jour le cache apt
      apt:
        update_cache: true
    - name: Installer les outils de reconnaissance reseau
      apt:
        name:
          - nmap
          - masscan
        state: present

- name: Configurer la VM victime
  hosts: victime
  become: true
  tasks:
    - name: Mettre à jour le cache apt
      apt:
        update_cache: true
    - name: Installer python3
      apt:
        name: python3
        state: present
    - name: Lancer le serveur web vulnerable
      shell: nohup python3 -m http.server 8080 < /dev/null > /tmp/http.log 2>&1 &
      args:
        executable: /bin/bash
      async: 1
      poll: 0
```

**Avantages immédiats par rapport aux scripts shell de l'étape 5 :**
- module `apt` d'Ansible : idempotent nativement, pas besoin de vérifier manuellement l'état avant d'agir ;
- `async`/`poll: 0` : équivalent Ansible du problème `ssh -f` résolu à la main — Ansible gère nativement le lancement de tâches en arrière-plan sans bloquer ;
- pas de mot de passe en clair dans une commande shell visible (`ps aux`) : Ansible gère l'authentification différemment.

### 3. Exécution

```bash
ansible-playbook -i inventory.ini playbook.yml
```

**Première tentative :**
```
PLAY [Configurer la VM attaquante] *********************************************
TASK [Gathering Facts] *********************************************************
fatal: [kali-like]: FAILED! => sudo: il est necessaire de saisir un mot de passe
```

**Difficulté rencontrée** : échec sur `become` (l'escalade de privilèges Ansible, équivalent de `sudo`), malgré `ansible_ssh_pass` déjà renseigné pour l'authentification SSH.

**Cause** : Ansible distingue deux mots de passe différents — celui de connexion SSH (`ansible_ssh_pass`) et celui utilisé pour `sudo` côté distant (`ansible_become_pass`) — à fournir séparément dans l'inventaire, même s'ils sont identiques.

**Solution** : ajouter `ansible_become_pass=<mot_de_passe>` dans le bloc `[lab:vars]`.

**Une fois corrigé :**
```
PLAY RECAP *********************************************************************
kali-like : ok=3 changed=1 unreachable=0 failed=0 skipped=0 rescued=0 ignored=0
victim    : ok=4 changed=2 unreachable=0 failed=0 skipped=0 rescued=0 ignored=0
```

`failed=0` sur les deux hôtes — la configuration a réussi du premier coup une fois le mot de passe `become` corrigé, sans aucun des multiples contournements shell qu'il avait fallu construire à la main à l'étape 5 (`sudo -S`, `ssh -f`, boucles de retry...).

**Vérification finale, depuis `kali-like-vm` :**
```
debian@debian:~$ which nmap masscan
/usr/bin/nmap
/usr/bin/masscan

debian@debian:~$ nmap -p 8080 172.16.197.136
PORT     STATE SERVICE
8080/tcp open  http-proxy

debian@debian:~$ wget -qO- http://172.16.197.136:8080
<!DOCTYPE HTML>
...
<li><a href=".ansible/">.ansible/</a></li>
...
```

Le listing de fichiers renvoyé par `victim-vm` inclut désormais un dossier `.ansible/` (créé automatiquement par Ansible lors de l'exécution des modules), preuve visible que la configuration est bien passée par Ansible cette fois, plutôt que par les scripts shell manuels.

### Comparaison avec l'approche scripts shell de l'étape 5

| | Scripts shell (étape 5) | Ansible |
|---|---|---|
| Temps de mise au point | Plusieurs heures, ~10 itérations d'erreurs | Fonctionnel en 2 tentatives |
| Gestion de `sudo` non-interactif | Contournement manuel (`echo mdp \| sudo -S`) | Géré nativement (`become` + `ansible_become_pass`) |
| Lancement en arrière-plan sans bloquer | Contournement manuel (`ssh -f`, `< /dev/null`) | Géré nativement (`async`/`poll: 0`) |
| Idempotence (relancer sans tout refaire) | Aucune (réinstallerait à chaque fois) | Native (le module `apt` vérifie l'état avant d'agir) |
| Lisibilité | Scripts bash imbriqués dans des `local-exec` | Déclaratif, un module = une action |

---

## `.gitignore`

```gitignore
# Fichiers contenant des secrets
terraform.tfvars
*.tfvars

# Etat Terraform (peut contenir des donnees sensibles en clair)
terraform.tfstate
terraform.tfstate.backup
.terraform.tfstate.lock.info

# Repertoire local du provider
.terraform/

# Inventaire Ansible (contient des mots de passe)
inventory.ini
```

## Structure finale du dépôt

```
terraform/
├── README.md
├── .gitignore
├── main.tf
├── variables.tf
├── terraform.tfvars.example
├── terraform.tfvars   (présent localement, exclu par .gitignore)
├── inventory.ini       (présent localement, exclu par .gitignore)
└── playbook.yml
```
