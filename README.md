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

Détails : [`eks/README.md`](eks/README.md) (cluster, base, API, images) et [`infra/README.md`](infra/README.md) (CDN).
