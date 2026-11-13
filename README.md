# creatura-infra

Infrastructure AWS de Creatura : CDN du front (`infra/`), cluster EKS, base RDS et API (`eks/`), bucket d'état Terraform (`bootstrap/`).

## Tout lancer, tout détruire

Avec un profil AWS administrateur et `creatura-app` cloné à côté de ce dépôt :

```sh
scripts/aws-up.sh                # crée ou complète tout l'environnement (20 à 25 min)
scripts/aws-down.sh --snapshot   # détruit tout, après un snapshot de la base
```

`aws-up.sh` enchaîne : bucket d'état, images construites dans AWS (CodeBuild, sans Docker sur le poste), cluster et base, CDN et front, schéma de la base, déploiement du back, route `/api/*`, puis contrôle de santé. Il est ré-exécutable et affiche à la fin les adresses du site, de l'admin et de l'API. Prérequis : `aws`, `terraform`, `kubectl`, `python3`, `git`, `zip`, `pnpm`, et `eks/terraform.tfvars` (modèle : `eks/terraform.tfvars.example`).

Coût : environ 0,30 $ de l'heure tant que l'environnement existe. Journaux de chaque étape : `.deploy/logs/`.

## Nom de domaine (facultatif)

La stack permanente `dns/` crée une zone Route 53 pour un sous-domaine (ex. `creatura.creasmaloud.dev`) et son certificat HTTPS. `aws-down.sh` ne la détruit pas, pour ne pas avoir à refaire la délégation.

```sh
cp dns/terraform.tfvars.example dns/terraform.tfvars   # mettre le sous-domaine voulu
terraform -chdir=dns init && terraform -chdir=dns apply
terraform -chdir=dns output name_servers
```

Chez le registrar : un enregistrement **NS** par serveur affiché, HOST = le sous-domaine (ex. `creatura`), et aucun autre enregistrement sur ce HOST. Le certificat se valide alors seul en quelques minutes, et `aws-up.sh` branche le domaine sur CloudFront dès qu'il est validé (statut `ISSUED`). Coût : 0,50 $ par mois pour la zone. État local dans `dns/terraform.tfstate` : ne pas le perdre.

Détails : [`eks/README.md`](eks/README.md) (cluster, base, API, images) et [`infra/README.md`](infra/README.md) (CDN).
