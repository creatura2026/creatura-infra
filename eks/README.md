# EKS, RDS et API — procédures manuelles A52

Pour la CI/CD automatique depuis `develop`, suivre le [README principal](../README.md). Les procédures ci-dessous concernent les opérations manuelles ; elles ne doivent pas être exécutées en parallèle de la CI.

Stack séparée du CDN : VPC sur deux zones, nœuds privés, NAT unique, cluster EKS et deux nœuds x86 t3.medium, base PostgreSQL 16 sur RDS dans les sous-réseaux privés du même VPC, répartiteur de charge (ALB) réservé à CloudFront devant l'API, accès IAM de déploiement limité au namespace creatura et accès administrateur distinct. Cette stack crée des rôles IAM : elle doit être exécutée par une identité autorisée, contrairement à la stack CDN existante.

Coûts permanents : plan de contrôle EKS, EC2, disques, NAT, instance RDS, ALB et trafic. Le NAT unique réduit le coût mais représente une dépendance à une seule zone. Aucun apply automatique n'est ajouté au pipeline CDN.

**En une commande** : `scripts/aws-up.sh` réalise toutes les étapes ci-dessous (et celles de `infra/`), et `scripts/aws-down.sh` détruit tout. Les étapes détaillées restent utiles pour comprendre ou reprendre une étape à la main.

1. Copier terraform.tfvars.example vers terraform.tfvars et remplacer toutes les valeurs d'exemple. Choisir une version EKS en support standard disponible dans la région. L’identité administrateur doit exister. L’identité de déploiement limitée est facultative (`null`) ; ne pas créer de doublon pour le même ARN.
2. Initialiser avec le bucket d'état existant et une **clé distincte**, par exemple :

```sh
terraform -chdir=eks init -backend-config='bucket=VOTRE_BUCKET_ETAT' -backend-config='key=eks/terraform.tfstate' -backend-config='region=eu-north-1' -backend-config='encrypt=true' -backend-config='use_lockfile=true'
terraform -chdir=eks plan -out=eks.tfplan
terraform -chdir=eks apply eks.tfplan
```

3. Avec l'identité administrateur, ouvrir l'accès au cluster et créer le namespace :

```sh
aws eks update-kubeconfig --name creatura-backend --region eu-north-1
kubectl create namespace creatura
```

4. Appliquer le schéma et créer l'utilisateur du back (`creatura_back`) avec le Job `k8s/db/schema-job.yaml`. Il tourne dans le cluster, donc dans le VPC de la base. Le mot de passe du compte principal est lu dans Secrets Manager et ne reste pas dans le cluster :

```sh
secret_arn=$(terraform -chdir=eks output -raw db_master_secret_arn)
kubectl -n creatura create secret generic creatura-db-admin \
  --from-literal=PGHOST="$(terraform -chdir=eks output -raw db_endpoint)" \
  --from-literal=PGPORT=5432 \
  --from-literal=PGDATABASE=creatura \
  --from-literal=PGUSER=creatura \
  --from-literal=PGSSLMODE=require \
  --from-literal=PGPASSWORD="$(aws secretsmanager get-secret-value --secret-id "$secret_arn" --query SecretString --output text | python3 -c 'import json, sys; print(json.load(sys.stdin)["password"])')"
kubectl apply -f k8s/db/schema-job.yaml
kubectl -n creatura wait --for=condition=complete job/creatura-db-schema --timeout=180s
kubectl -n creatura logs job/creatura-db-schema
kubectl -n creatura delete secret creatura-db-admin
```

5. Créer le Secret du back. `DATABASE_URL` ne contient pas de mot de passe : le pod signe un jeton IAM à chaque connexion.

```sh
kubectl -n creatura create secret generic creatura-backend \
  --from-literal=DATABASE_URL="$(terraform -chdir=eks output -raw backend_database_url)" \
  --from-literal=DB_IAM_AUTH=true \
  --from-literal=AWS_REGION=eu-north-1 \
  --from-literal=JWT_SECRET="$(python3 -c 'import secrets; print(secrets.token_urlsafe(48))')" \
  --from-literal=TIMEZONE=Europe/Paris \
  --from-literal=IMAGE_BASE_URL=https://DOMAINE_CLOUDFRONT \
  --from-literal=CORS_ORIGINS=https://DOMAINE_CLOUDFRONT
```

Ajouter `ADMIN_LOGIN` et `ADMIN_PASSWORD` pour que l'API crée le compte administrateur au démarrage.

6. Créer le secret GHCR si les images sont privées, puis lancer le workflow de déploiement.
7. Relier l'API à CloudFront et publier le front (section « Entrée publique de l'API »).

L'API EKS accepte uniquement les CIDR fournis : utiliser un runner à IP de sortie fixe, ou un runner privé et adapter l'accès au cluster. Les runners GitHub publics n'ont pas d'IP stable. La CI doit pouvoir lire les métadonnées du namespace ; si nécessaire l'administrateur lui donne ce droit de lecture via RBAC (ne pas donner cluster-admin au déploiement).

## Base RDS (`rds.tf`)

La base est dans les sous-réseaux privés du cluster, sans adresse publique. Son groupe de sécurité n'accepte le port 5432 que depuis les nœuds EKS : ni bastion ni tunnel, tout accès passe par un pod.

- **Back** : authentification IAM. Le ServiceAccount `creatura-backend` reçoit par EKS Pod Identity un rôle limité à `rds-db:connect` sur l'utilisateur `creatura_back`. Vérifier l'injection avec `kubectl -n creatura exec deploy/creatura-backend -- env | grep AWS_CONTAINER`.
- **Compte principal** (`creatura`) : mot de passe généré par RDS dans Secrets Manager, avec rotation automatique. Il ne sert qu'au Job de schéma ; le relire dans Secrets Manager à chaque lancement.
- **Session psql ponctuelle** : lancer un pod temporaire, par exemple `kubectl -n creatura run psql --rm -it --image=postgres:16 --env=PGPASSWORD=... -- psql "host=ADRESSE dbname=creatura user=creatura sslmode=require"`.
- **Image du Job** : `ghcr.io/creatura2026/creatura-db:develop`, publiée par la CI de creatura-app. Si le package est privé, ajouter `imagePullSecrets` au Job comme au Deployment.

`rds.tf` reprend `infra/rds.tf` de la branche `AS-49-rds`. Ne pas fusionner les deux : la base serait créée deux fois.

### Sauvegardes et restauration

- **Sauvegardes automatiques** : une par jour entre 01 h et 02 h UTC, conservées 7 jours (`db_backup_retention_days`), avec les journaux de transactions. On peut donc restaurer la base **à la seconde près** sur cette période. Le stockage est gratuit jusqu'à la taille de la base.
- **Avant une destruction** : `scripts/aws-down.sh --snapshot` garde un snapshot manuel, qui survit à `aws-down.sh`. Sans cette option, la base et ses sauvegardes automatiques sont supprimées.
- **Restaurer** : une restauration crée toujours une **nouvelle** base, la base d'origine n'est pas touchée. Procédure testée le 13/11/2026 (comptes, collection et 42 tests du schéma retrouvés sur la copie) :

```sh
SRC=$(aws rds describe-db-instances --query "DBInstances[?DBName=='creatura'].DBInstanceIdentifier | [0]" --output text)
read SUBNETS SG PG <<< "$(aws rds describe-db-instances --db-instance-identifier $SRC \
  --query 'DBInstances[0].[DBSubnetGroup.DBSubnetGroupName,VpcSecurityGroups[0].VpcSecurityGroupId,DBParameterGroups[0].DBParameterGroupName]' --output text)"
# --use-latest-restorable-time, ou --restore-time 2026-11-13T10:44:39Z pour un instant précis
aws rds restore-db-instance-to-point-in-time --source-db-instance-identifier $SRC \
  --target-db-instance-identifier creatura-restore-test --use-latest-restorable-time \
  --db-instance-class db.t4g.micro --db-subnet-group-name $SUBNETS --vpc-security-group-ids $SG \
  --db-parameter-group-name $PG --no-publicly-accessible --no-multi-az
aws rds wait db-instance-available --db-instance-identifier creatura-restore-test
```

La copie a le mot de passe principal de la base d'origine au moment de la sauvegarde (secret Secrets Manager de la source). La vérifier depuis un pod du cluster avec l'image `creatura-db`, qui contient `psql` et `/db/tests/test_schema.sql` (Secret temporaire `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGPASSWORD`, `PGSSLMODE=require`, supprimé ensuite). Pour remplacer la base, pointer `DATABASE_URL` et le rôle IAM du back sur la copie, ou la renommer ; sinon la supprimer :

```sh
aws rds delete-db-instance --db-instance-identifier creatura-restore-test --skip-final-snapshot --delete-automated-backups
```

## Entrée publique de l'API (`api.tf`)

Le front et l'API partagent le domaine CloudFront : le navigateur appelle `/api/v1` sur la même origine, sans CORS. Le trajet est CloudFront → ALB → NodePort 30080 des nœuds → pods du back. L'ALB est créé par cette stack (ni Ingress ni contrôleur à installer) et son groupe de sécurité n'accepte que CloudFront.

Après l'apply de cette stack et le déploiement du back, déclarer l'ALB à la stack `infra/` :

```sh
api_origin=$(terraform -chdir=eks output -raw api_origin_domain_name)
terraform -chdir=infra apply -var="api_origin_domain_name=$api_origin"
curl "$(terraform -chdir=infra output -raw api_url)/health"
./scripts/deploy-frontend.sh
```

Enregistrer la même valeur dans la variable GitHub `API_ORIGIN_DOMAIN_NAME` du dépôt : sans elle, le prochain apply de la CI sur `main` retirerait la route `/api/*`. Le nom de l'ALB change à chaque re-création de la stack : refaire cette étape.

Limite connue : sans nom de domaine, pas de certificat pour l'ALB. Le navigateur parle toujours en HTTPS à CloudFront, mais le tronçon CloudFront → ALB est en HTTP. Aucun certificat ni domaine n'a été inventé ; avec un domaine, ajouter un certificat ACM et un écouteur 443.

Destruction : vider d'abord `api_origin_domain_name` (apply de `infra/` sans la variable, et variable GitHub supprimée), puis détruire cette stack. Si quelqu'un a créé à la main un Service LoadBalancer ou un Ingress, le retirer avant. La base est supprimée avec la stack, sans snapshot final : ses données sont perdues. Ne pas détruire le bucket d'état avant les stacks qui l'utilisent.

## Contrat avec creatura-app

La CI existante de `creatura-app/develop` teste et publie déjà `ghcr.io/creatura2026/creatura-backend`. Réutiliser le digest affiché dans son résumé, sans rebuild. Le commentaire de cette CI mentionne Argo CD, mais cette livraison utilise GitHub Actions : ne pas gérer le même Deployment avec Argo CD en parallèle.

Backend réel : FastAPI, utilisateur UID 10001, port 8000. Readiness et startup sur `/api/v1/health` (inclut PostgreSQL), vivacité TCP pour éviter les redémarrages lors d'une panne DB. Deux replicas ; vérifier que la création facultative du compte administrateur au démarrage est compatible avec des démarrages concurrents ; préférer un provisioning initial séparé.

Pour créer le cluster, suivre `eks/README.md`. Les permissions IAM nécessaires sont un prérequis réel.

## Prérequis administrateur AWS / Kubernetes

- Cluster EKS existant, nœuds disponibles et capables de tirer les images GHCR (accès réseau vers GHCR).
- Endpoint Kubernetes accessible depuis le runner. Pour un cluster privé, utiliser un runner hébergé dans le réseau adéquat au lieu de `ubuntu-latest`.
- Identité CI autorisée à `eks:DescribeCluster`, et accès Kubernetes accordé via une entrée d'accès EKS et RBAC limité au namespace `creatura`.
- Namespace `creatura` créé par l'administrateur. Droits CI : lecture du namespace et des métadonnées du Secret, gestion des Deployments/Services, lecture des ReplicaSets/Pods/Events.
- Secret Kubernetes `creatura-backend` précréé dans ce namespace : variables attendues par l'application pour RDS et autres secrets. Aucune valeur secrète dans Git. Idéalement synchroniser AWS Secrets Manager avec le mécanisme choisi par l'équipe.
- RDS : créée par cette stack dans le VPC du cluster, joignable depuis les pods seulement ; TLS obligatoire (`?sslmode=require`).

La stack `eks/` crée les rôles du cluster, des nœuds et des pods du back. Son exécution nécessite donc une identité autorisée à gérer IAM ; les identités administrateur et CI doivent déjà exister.

## Configuration GitHub

Dans l'environnement `production`, configurer :

| Type | Nom | Valeur |
|---|---|---|
| Variable | AWS_REGION | Région AWS du cluster EKS |
| Variable | EKS_CLUSTER_NAME | Cluster existant |
| Variable | BACKEND_PORT | Port applicatif, défaut 8000 |
| Variable | BACKEND_HEALTH_PATH | Endpoint HTTP, défaut /api/v1/health |
| Secret | AWS_ACCESS_KEY_ID | Identité CI existante |
| Secret | AWS_SECRET_ACCESS_KEY | Clé de cette identité |

L'authentification reprend le mécanisme existant du dépôt. Migrer vers OIDC quand l'administrateur autorisera sa configuration.

## Déploiement et retour arrière

Lancer manuellement le workflow avec le digest publié par la CI app. Il rend les manifests, valide ceux-ci sur le serveur Kubernetes puis attend la disponibilité du Deployment. Deux replicas, remplacement progressif, sondes HTTP, limites de ressources et exécution non-root sont configurés.

En cas d'échec, le workflow échoue ; il ne déclare pas la livraison réussie. Pour revenir en arrière, relancer le même workflow avec le dernier digest validé. Un changement incompatible de schéma DB ne peut pas être annulé par un simple changement d'image.

Le schéma est appliqué par le Job `k8s/db/schema-job.yaml` (étape 4 ci-dessus), une fois par livraison qui le modifie, avant les nouveaux pods et en restant compatible avec les anciens. L'API ne modifie jamais le schéma.

## Accès à l'API

Le Service est de type `NodePort` (30080), visé par l'ALB de `api.tf`. L'accès public passe par `https://DOMAINE_CLOUDFRONT/api/v1` (section « Entrée publique de l'API »). Pour un essai direct sans passer par CloudFront :

```sh
kubectl -n creatura port-forward service/creatura-backend 8080:80
```

Le workflow de déploiement ne rend rien public par lui-même : la base n'a pas d'adresse publique, et l'API n'est joignable que par CloudFront une fois `api_origin_domain_name` renseigné dans `infra/`.

## Validation locale

```sh
python -m pip install PyYAML==6.0.2
python scripts/render-backend.py --image 'ghcr.io/creatura2026/creatura-backend@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > /tmp/backend.yaml
kubectl apply --dry-run=server -f /tmp/backend.yaml
```

Pour faire tourner le back sur un cluster local (kind) avec ces mêmes manifests : `scripts/k8s-local.sh up`.

Ne pas appliquer les templates directement : le renderer remplace `IMAGE_REQUIRED`, le port et les sondes. Les manifests ne sont pas gérés simultanément par Terraform ou un autre contrôleur GitOps.

## Secrets applicatifs et images privées

Le Secret `creatura-backend` (étape 5 ci-dessus) fournit `DATABASE_URL` (sans mot de passe), `DB_IAM_AUTH=true`, `AWS_REGION` et `JWT_SECRET` ; configurer aussi `TIMEZONE=Europe/Paris`, `IMAGE_BASE_URL` et `CORS_ORIGINS` selon les domaines déployés. Lire `backend/.env.example` sur develop pour les options restantes. Ne pas copier les secrets dans Git.

Si le package GHCR est privé : créer un Secret de type kubernetes.io/dockerconfigjson nommé `ghcr-pull` avec un jeton de lecture de packages, puis ajouter `imagePullSecrets: [{name: ghcr-pull}]` dans `spec.template.spec` du Deployment. Ne pas utiliser un jeton éphémère de CI comme identifiant permanent de pull. Le workflow attendra et échouera si l'image est inaccessible.

### Sans accès à GHCR : images dans ECR (`ecr.tf`)

Avec `create_ecr_repositories = true`, la stack crée les dépôts `creatura-backend` et `creatura-db` dans le compte. Les nœuds y lisent sans secret.

Les images se construisent dans AWS, sans Docker sur le poste (`codebuild.tf`, `create_image_builder = true`) : `scripts/build-images.sh` dépose le code de `creatura-app` dans un bucket S3 et lance un projet CodeBuild par la CLI AWS. Le build tourne sur Linux x86_64, l'architecture des nœuds, et pousse lui-même dans ECR. Le script n'envoie que les fichiers suivis ou non ignorés par git : `.env`, `.env.rds` et `.venv` ne partent jamais.

Pour gagner du temps, créer d'abord le seul projet de build et lancer les images pendant la création du cluster :

```sh
terraform -chdir=eks apply -target=aws_codebuild_project.images   # ECR, bucket, rôle et projet
./scripts/build-images.sh                                          # dans un autre terminal
terraform -chdir=eks apply                                         # le reste de la stack, en parallèle
```

Le script affiche à la fin chaque image épinglée par digest. `--stage-only` prépare les archives sans rien envoyer ; `--only backend` ou `--only db` limite à une image. Limite connue : les images de base (`python`, `postgres`, `uv`) viennent de Docker Hub et GHCR, sans compte ; Docker Hub peut refuser des téléchargements anonymes depuis les adresses partagées de CodeBuild (`toomanyrequests`). Relancer le build dans ce cas.

`scripts/render-backend.py` accepte alors `--image "<dépôt>/creatura-backend@sha256:…"`. Pour le Job de schéma, remplacer l'image GHCR à l'application, sans modifier le fichier :

```sh
sed "s#image: ghcr.io/creatura2026/creatura-db:develop#image: $reg/creatura-db@sha256:…#" k8s/db/schema-job.yaml | kubectl apply -f -
```

Les dépôts sont supprimés avec la stack, images comprises (`force_delete`).

