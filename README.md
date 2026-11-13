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
| `WAF_ENABLED` | `true` pour créer le pare-feu WAF devant CloudFront (payant, voir `infra/README.md`) ; défaut `false` |
| `WAF_MODE` | `block` (défaut) ou `count` (observation sans blocage) |

| Secret | Usage |
|---|---|
| `AWS_ACCESS_KEY_ID` | Identité AWS autorisée au provisioning |
| `AWS_SECRET_ACCESS_KEY` | Secret correspondant |
| `APP_REPO_TOKEN` | Jeton GitHub avec lecture Actions du dépôt `creatura-app` (runs/artefacts) |
| `GHCR_READ_TOKEN` | PAT classique avec `read:packages` et accès aux packages backend/DB ; autoriser SSO si exigé |

`API_ORIGIN_DOMAIN_NAME`, `AWS_ROLE_ARN`, `AWS_PLAN_ROLE_ARN`, `AWS_FRONTEND_ROLE_ARN`, `APP_WORKFLOW_ID` ne sont pas consommés par cette nouvelle chaîne.

## GitHub : dépôt creatura-app

Ajouter le secret `INFRA_REPO_TOKEN` : jeton avec **Actions: write** sur `creatura-infra`, autorisé à déclencher `deploy-aws.yml`. Le `GITHUB_TOKEN` du dépôt app ne permet pas à lui seul le déclenchement inter-dépôts. Aucun accès AWS dans la CI app.

Laisser GitHub Actions publier les packages backend/DB avec `GITHUB_TOKEN` (`packages: write`). Vérifier que `GHCR_USERNAME` côté infra a le droit de les lire.

Les secrets d'environnement et les règles GitHub `production` restent applicables. Pour une livraison entièrement automatique, cet environnement doit autoriser `develop` sans attente de validation manuelle.

## Secrets Kubernetes

Le déploiement crée le namespace, le Secret de lecture GHCR et le Secret applicatif ; aucune saisie manuelle de mot de passe RDS. Le secret administrateur DB est lu depuis Secrets Manager, transmis par stdin au Job, puis supprimé du cluster même si le Job échoue.

`creatura-backend` contient : `DATABASE_URL` directe RDS avec TLS, `DB_IAM_AUTH=true`, `AWS_REGION`, `TIMEZONE=Europe/Paris`, `IMAGE_BASE_URL`, `CORS_ORIGINS` et une `JWT_SECRET` générée une fois et conservée. À la création initiale : `ADMIN_LOGIN=admin` et mot de passe aléatoire conservé dans le Secret. Ne jamais afficher ce secret dans les logs CI. Un administrateur peut lire le mot de passe initial avec kubectl depuis une session autorisée.

Les mises à jour de Secret entraînent un redémarrage des pods pour relire la configuration. L'identité IAM des pods reste celle définie dans `eks/rds.tf` ; elle est indépendante de la clé AWS du workflow.

## Reprise et limites

`Deploy Creatura AWS` peut être relancé manuellement avec `app_run_id` et `app_run_attempt` (run CI app réussi sur develop et tentative exacte), ou sans valeur (dernier run réussi). Cela ne reconstruit rien. Les noms d’artefacts incluent le run et sa tentative. Aucune sélection par tag `latest`, `develop` ou SHA court : les deux images utilisent leur digest complet et l’archive frontend son SHA-256 dans `release.json`. Si un artefact manque, est expiré, altéré ou vient d’une autre tentative, le déploiement échoue ; il ne choisit jamais un autre build en remplacement. Relancer **tous les jobs** de la CI app après expiration ou un échec nécessitant une nouvelle tentative ; une relance partielle ne mélange pas les artefacts d’anciennes tentatives.

Pas de retour arrière DB automatique ; ne pas publier de migration incompatible avec les anciens pods pendant un rolling update. Un échec ne supprime pas les ressources et n'essaie pas de contourner les verrous d'état. Les anciennes versions front restent dans S3. Les migrations peuvent déjà avoir été appliquées si une étape ultérieure échoue.

Le tronçon CloudFront → ALB reste HTTP comme dans A52 ; le navigateur utilise HTTPS. RDS reste configuré sans protection de suppression ni snapshot final : le garde-fou CI ne remplace pas une stratégie de sauvegarde.

Les scripts locaux A52 `aws-up.sh`, `build-images.sh`, `deploy-frontend.sh` restent disponibles pour le travail manuel, mais ne doivent pas être utilisés pour relivrer en parallèle de cette CI. Seul `deploy-frontend.sh --skip-build` est appelé par la CI. `aws-up.sh` utilise encore sa convention historique de bucket : ne pas l'exécuter contre l'état CI sans adaptation.

## Vérification sans AWS

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
```

Les workflows sont contrôlés par actionlint. L'exécution réelle de la CI app et le déploiement AWS nécessitent les permissions, secrets et ressources du compte ; une validation locale ne prouve pas leur réussite.

Lors de la première installation, le push infra peut échouer avant AWS si la CI app existante ne fournit pas encore la release v2. C’est attendu : une fois les deux modifications installées et les secrets configurés, un nouveau push app sur develop produit la première release v2 et déclenche son déploiement. Les anciens artefacts ne sont jamais utilisés par défaut en remplacement.
## Nom de domaine (facultatif)

La stack permanente `dns/` crée une zone Route 53 pour un sous-domaine (ex. `creatura.creasmaloud.dev`) et son certificat HTTPS. `aws-down.sh` ne la détruit pas, pour ne pas avoir à refaire la délégation.

```sh
cp dns/terraform.tfvars.example dns/terraform.tfvars   # mettre le sous-domaine voulu
terraform -chdir=dns init && terraform -chdir=dns apply
terraform -chdir=dns output name_servers
```

Chez le registrar : un enregistrement **NS** par serveur affiché, HOST = le sous-domaine (ex. `creatura`), et aucun autre enregistrement sur ce HOST. Le certificat se valide alors seul en quelques minutes, et `aws-up.sh` branche le domaine sur CloudFront dès qu'il est validé (statut `ISSUED`). Coût : 0,50 $ par mois pour la zone. État local dans `dns/terraform.tfstate` : ne pas le perdre.

Détails : [`eks/README.md`](eks/README.md) (cluster, base, API, images) et [`infra/README.md`](infra/README.md) (CDN).
