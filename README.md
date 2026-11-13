# creatura-infra

Infrastructure AWS de Creatura : `bootstrap/` (état Terraform), `infra/` (S3 et CloudFront), `eks/` (EKS, RDS privé, ALB, Pod Identity ; registres ECR/CodeBuild optionnels pour les scripts manuels).

## CI/CD depuis develop

1. `creatura-app` teste PostgreSQL, le backend et les deux frontends. La CI construit une fois les images backend/DB et le frontend web (joueur `/`, administration `/admin/`).
2. Elle publie les images sur GHCR et les artefacts `frontend-dist-RUN-TENTATIVE` et `creatura-release-RUN-TENTATIVE`. Ce dernier contient le commit, le run/attempt et les digests exacts.
3. Une fois les artefacts prêts, la CI app déclenche `deploy-aws.yml` sur `creatura-infra/develop`. Le déploiement attend la conclusion réussie du run applicatif et contrôle aussi sa tentative exacte. Un push sur `creatura-infra/develop` déclenche aussi le déploiement, avec la dernière CI app réussie.
4. L'infra vérifie provenance, branche, workflow, résultat et digests avant toute opération AWS. Les PR ont uniquement les contrôles sans identifiants AWS.
5. Terraform crée/met à jour EKS, RDS, ALB et CloudFront ; la route `/api/*` provient directement de l'output ALB, sans variable GitHub à recopier.
6. Les nœuds EKS récupèrent directement les images GHCR déjà testées, par digest. Le Secret Kubernetes `ghcr-pull` donne accès aux packages privés. Aucun passage par ECS ou ECR, aucun rebuild Docker/CodeBuild dans le dépôt infra.
7. Un Job applique le schéma et les migrations ré-exécutables, sans données de démo. Le backend utilise RDS via Pod Identity. Le frontend est publié depuis l'artefact, sans build.
8. Le déploiement attend les pods et l'invalidation CloudFront, vérifie HTML + santé API/DB, puis enregistre la release réussie dans S3. Le frontend est vérifié par SHA-256 avant extraction. Les releases plus anciennes sont refusées, y compris après un déploiement partiellement échoué grâce au marqueur `.creatura/deployment.json`. Le marqueur `.creatura/release.json` représente uniquement la dernière livraison entièrement réussie.

Les déploiements sont sérialisés (`creatura-aws-production`) et un nouveau push n'annule jamais une opération Terraform en cours. Un plan comportant suppression/remplacement échoue avant apply : ces changements nécessitent une intervention manuelle examinée. Aucun workflow de destruction automatique n'est fourni.

## Première installation

- Créer une fois le bucket d'état via `bootstrap/`, avec une session AWS autorisée. Son état reste local, sauvegardé hors Git. Ne jamais le recréer à chaque run CI.
- Finir toute destruction/récupération de verrou et d'état avant d'activer la CI. Ne jamais exécuter les scripts locaux et la CI simultanément sur les mêmes états.
- Utiliser le **même nom de bucket et les mêmes clés d'état** que le déploiement existant. Pour l'environnement initial de l'équipe : `creatura-tfstate-470805151953-eu-north-1`, `creatura-infra/terraform.tfstate`, `eks/terraform.tfstate`.
- Fusionner les changements infra puis app dans `develop`. GitHub exige que le workflow `workflow_dispatch` soit également enregistré sur la branche par défaut du dépôt infra. Si la branche par défaut est `main`, y ajouter la définition du workflow (sans activer de déploiement depuis main) ou choisir `develop` comme branche par défaut. Le champ `ref: develop` choisit ensuite la version à exécuter.
- Les clés AWS doivent permettre le provisioning IAM/EKS/EC2/RDS/ELB/S3/CloudFront et la lecture du secret RDS. L'identité CI reçoit un accès administrateur Kubernetes pour initialiser namespace, secrets et schéma ; une identité de release seule pourrait être restreinte dans une évolution ultérieure. Pas de clés dans Git, pas d'OIDC requis.
- La CI autorise l'IP /32 du runner courant sur l'API EKS, avec les CIDR administrateur configurés. L'IP du runner précédent n'est pas conservée. Ne pas lancer un autre provisioner en parallèle.

Si des ressources ECR/CodeBuild existent déjà et que la CI les désactive (`create_ecr_repositories=false`, `create_image_builder=false`), effectuer leur retrait manuellement avant la première release : le garde-fou du plan automatique refusera leur suppression.

## GitHub : dépôt creatura-infra

Configurer dans l'environnement `production`. Ne pas conserver d'anciennes valeurs d'environnement qui masquent les variables du dépôt.

| Variable | Valeur |
|---|---|
| `AWS_ACCOUNT_ID` | `470805151953` (le workflow vérifie ce compte) |
| `AWS_REGION` | `eu-north-1` (défaut) |
| `TF_STATE_BUCKET` | Nom réel du bucket bootstrap existant |
| `TF_STATE_REGION` | `eu-north-1` (défaut) |
| `TF_STATE_KEY` | `creatura-infra/terraform.tfstate` (défaut) |
| `TF_EKS_STATE_KEY` | `eks/terraform.tfstate` (défaut) |
| `EKS_CLUSTER_NAME` | `creatura-backend` (défaut) |
| `EKS_KUBERNETES_VERSION` | Version EKS en support standard disponible dans la région ; obligatoire |
| `EKS_ADMIN_PRINCIPAL_ARN` | ARN IAM administrateur ; vide = identité IAM de la CI |
| `EKS_ADMIN_CIDRS` | Tableau JSON des CIDR administrateur, ex. `["203.0.113.10/32"]` ; défaut `[]` |
| `GHCR_USERNAME` | Compte GitHub qui peut lire les packages privés |

| Secret | Usage |
|---|---|
| `AWS_ACCESS_KEY_ID` | Identité AWS autorisée au provisioning |
| `AWS_SECRET_ACCESS_KEY` | Secret correspondant |
| `APP_REPO_TOKEN` | Jeton GitHub avec lecture Actions du dépôt `creatura-app` (runs/artefacts) |
| `GHCR_READ_TOKEN` | PAT classique avec `read:packages` et accès aux packages backend/DB ; autoriser SSO si exigé |

## Tout lancer, tout détruire

Avec un profil AWS administrateur et `creatura-app` cloné à côté de ce dépôt :

```sh
terraform -chdir=bootstrap init -backend=false
terraform -chdir=bootstrap validate
terraform -chdir=infra init -backend=false
terraform -chdir=infra validate
terraform -chdir=eks init -backend=false
terraform -chdir=eks validate
python -m pip install PyYAML==6.0.2
python -m unittest discover -s tests -v
find scripts -name '*.sh' -print0 | xargs -0 -n1 bash -n
scripts/aws-up.sh                # crée ou complète tout l'environnement (20 à 25 min), ou reprend après une pause
scripts/aws-pause.sh             # pause sans rien détruire : nœuds à 0, NAT supprimé, base arrêtée
scripts/aws-down.sh --snapshot   # détruit tout, après un snapshot de la base
```

| État | Coût indicatif | Reprise |
| --- | --- | --- |
| En marche | environ 7 $ par jour | — |
| En pause (`aws-pause.sh`) | environ 3 $ par jour (plan de contrôle EKS, ALB, stockage) | `aws-up.sh`, 5 à 10 min, données conservées |
| Détruit (`aws-down.sh --snapshot`) | quelques centimes par mois (snapshot, zone DNS) | `aws-up.sh`, 20 à 25 min, base restaurée depuis le dernier snapshot |

À la création de la base, `aws-up.sh` restaure le dernier snapshot manuel `creatura-db-*` (`--fresh-db` pour une base neuve). La clé JWT et le mot de passe admin sont gardés dans `.deploy/backend-secrets.env` (ignoré par git, à ne pas perdre) : le compte admin d'une base restaurée garde ainsi son mot de passe.

En pause, le front reste en ligne mais l'API répond 503. AWS redémarre seul une base arrêtée au bout de 7 jours : pour une longue interruption, préférer `aws-down.sh --snapshot`.

`aws-up.sh` enchaîne : bucket d'état, images construites dans AWS (CodeBuild, sans Docker sur le poste), cluster et base, CDN et front, schéma de la base, déploiement du back, route `/api/*`, puis contrôle de santé. Il est ré-exécutable et affiche à la fin les adresses du site, de l'admin et de l'API. Prérequis : `aws`, `terraform`, `kubectl`, `python3`, `git`, `zip`, `pnpm`, et `eks/terraform.tfvars` (modèle : `eks/terraform.tfvars.example`).

Lors de la première installation, le push infra peut échouer avant AWS si la CI app existante ne fournit pas encore la release v2. C’est attendu : une fois les deux modifications installées et les secrets configurés, un nouveau push app sur develop produit la première release v2 et déclenche son déploiement. Les anciens artefacts ne sont jamais utilisés par défaut en remplacement.
## DNS dans la CI/CD

Ajouter dans `production` :

| Variable | Valeur |
|---|---|
| `CUSTOM_DOMAIN` | Sous-domaine réellement possédé/délégué, sans https:// ni chemin (exemple uniquement : `creatura.creasmaloud.dev`) |
| `TF_DNS_STATE_KEY` | `dns/terraform.tfstate` par défaut ; état séparé dans le bucket existant |

Sans `CUSTOM_DOMAIN`, l’adresse CloudFront reste utilisée. Si un domaine personnalisé est déjà présent, la CI refuse de le supprimer silencieusement quand cette variable manque.

La CI provisionne `dns/` avant EKS : zone Route 53, certificat ACM en `us-east-1` et enregistrements DNS de validation. Les NS sont affichés dans les logs et le résumé du workflow. Configurer une fois ces NS chez le fournisseur DNS parent/registrar. Tant que le certificat est en attente, la CI s'arrête après cinq minutes, avant de lancer EKS dans ce run. Attendre la propagation puis relancer le workflow infra avec la même release app. La CI n'achète pas de domaine et ne modifie pas le registrar.

Une fois le certificat `ISSUED`, les sorties DNS sont transmises automatiquement à `infra/` : alias CloudFront, certificat et enregistrements ALIAS A/AAAA. Les variables `IMAGE_BASE_URL` et `CORS_ORIGINS` du backend, ainsi que les contrôles de santé, utilisent `site_url`, donc le domaine personnalisé. Aucun rebuild app.

Permissions supplémentaires pour l'identité AWS : `dns/ci-permissions.json` contient un complément large de provisioning Route 53 et ACM. Route 53 est global ; ACM doit être autorisé en `us-east-1`, pas seulement `eu-north-1`.

La zone est permanente. Si un ancien état DNS local existe, le migrer avant d'activer la CI :

```powershell
terraform -chdir=dns init -migrate-state `
  "-backend-config=bucket=creatura-tfstate-470805151953-eu-north-1" `
  "-backend-config=key=dns/terraform.tfstate" `
  "-backend-config=region=eu-north-1" `
  "-backend-config=encrypt=true" `
  "-backend-config=use_lockfile=true"
```

Ne pas exécuter cette migration depuis un dossier dépourvu de l'ancien état local. Si la zone existe hors de l'état distant, la CI refuse d'en créer une deuxième : migrer l'état ou importer les ressources concernées. Le script `aws-down.sh` conserve le bucket bootstrap s'il contient l'état DNS permanent ; ne pas le détruire à la main sans sauvegarde/migration de cet état.

Les nœuds utilisent désormais `t3.small`, éligible dans le compte vérifié. La recréation du groupe `CREATE_FAILED` peut nécessiter un plan manuel : le garde-fou des plans destructifs reste actif.
