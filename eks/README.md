# A51 — Création EKS

Stack séparée du CDN : VPC sur deux zones, nœuds privés, NAT unique, cluster EKS et deux nœuds x86 t3.medium, accès IAM de déploiement limité au namespace creatura et accès administrateur distinct. Cette stack crée des rôles IAM : elle doit être exécutée par une identité autorisée, contrairement à la stack CDN existante.

Coûts permanents : plan de contrôle EKS, EC2, disques, NAT et trafic. Le NAT unique réduit le coût mais représente une dépendance à une seule zone. Aucun apply automatique n'est ajouté au pipeline CDN.

1. Copier terraform.tfvars.example vers terraform.tfvars et remplacer toutes les valeurs d'exemple. Choisir une version EKS en support standard disponible dans la région. Les deux identités IAM doivent exister et être différentes.
2. Initialiser avec le bucket d'état existant et une **clé distincte**, par exemple :

```sh
terraform -chdir=eks init -backend-config='bucket=VOTRE_BUCKET_ETAT' -backend-config='key=eks/terraform.tfstate' -backend-config='region=eu-north-1' -backend-config='encrypt=true' -backend-config='use_lockfile=true'
terraform -chdir=eks plan -out=eks.tfplan
terraform -chdir=eks apply eks.tfplan
```

3. Utiliser l'identité administrateur pour `aws eks update-kubeconfig --name creatura-backend --region eu-north-1`, puis `kubectl create namespace creatura`.
4. Créer le Secret applicatif, le secret GHCR si privé, puis lancer le workflow de déploiement.

L'API EKS accepte uniquement les CIDR fournis : utiliser un runner à IP de sortie fixe, ou un runner privé et adapter l'accès au cluster. Les runners GitHub publics n'ont pas d'IP stable. La CI doit pouvoir lire les métadonnées du namespace ; si nécessaire l'administrateur lui donne ce droit de lecture via RBAC (ne pas donner cluster-admin au déploiement).

RDS n'est pas créé par cette stack. Si RDS existe dans un autre VPC, configurer peering/transit, routes, DNS et règles réseau avant de déployer. Autoriser le port PostgreSQL depuis la source réseau effective des pods ; ne pas ouvrir RDS à Internet. La readiness de l'API vérifie PostgreSQL.

L'Ingress HTTPS et le raccordement CloudFront `/api/*` restent à configurer selon le DNS/certificat et le contrôleur retenus. Aucun certificat ni domaine n'a été inventé.

Destruction : retirer d'abord les Services LoadBalancer/Ingress et contrôleurs créant des ressources AWS, puis détruire cette stack. Ne pas détruire le bucket d'état avant les stacks qui l'utilisent.

## Contrat avec creatura-app

La CI existante de `creatura-app/develop` teste et publie dÃ©jÃ  `ghcr.io/creatura2026/creatura-backend`. RÃ©utiliser le digest affichÃ© dans son rÃ©sumÃ©, sans rebuild. Le commentaire de cette CI mentionne Argo CD, mais cette livraison utilise GitHub Actions : ne pas gÃ©rer le mÃªme Deployment avec Argo CD en parallÃ¨le.

Backend rÃ©el : FastAPI, utilisateur UID 10001, port 8000. Readiness et startup sur `/api/v1/health` (inclut PostgreSQL), vivacitÃ© TCP pour Ã©viter les redÃ©marrages lors d'une panne DB. Deux replicas ; vÃ©rifier que la crÃ©ation facultative du compte administrateur au dÃ©marrage est compatible avec des dÃ©marrages concurrents ; prÃ©fÃ©rer un provisioning initial sÃ©parÃ©.

Pour crÃ©er le cluster, suivre `eks/README.md`. Les permissions IAM nÃ©cessaires sont un prÃ©requis rÃ©el.

## PrÃ©requis administrateur AWS / Kubernetes

- Cluster EKS existant, nÅ“uds disponibles et capables de tirer les images GHCR (accÃ¨s rÃ©seau vers GHCR).
- Endpoint Kubernetes accessible depuis le runner. Pour un cluster privÃ©, utiliser un runner hÃ©bergÃ© dans le rÃ©seau adÃ©quat au lieu de `ubuntu-latest`.
- IdentitÃ© CI autorisÃ©e Ã  `eks:DescribeCluster`, et accÃ¨s Kubernetes accordÃ© via une entrÃ©e d'accÃ¨s EKS et RBAC limitÃ© au namespace `creatura`.
- Namespace `creatura` crÃ©Ã© par l'administrateur. Droits CI : lecture du namespace et des mÃ©tadonnÃ©es du Secret, gestion des Deployments/Services, lecture des ReplicaSets/Pods/Events.
- Secret Kubernetes `creatura-backend` prÃ©crÃ©Ã© dans ce namespace : variables attendues par l'application pour RDS et autres secrets. Aucune valeur secrÃ¨te dans Git. IdÃ©alement synchroniser AWS Secrets Manager avec le mÃ©canisme choisi par l'Ã©quipe.
- RDS joignable depuis les pods et ses rÃ¨gles rÃ©seau ; chiffrement TLS configurÃ© dans le client applicatif.

La stack `eks/` crÃ©e les rÃ´les du cluster et des nÅ“uds. Son exÃ©cution nÃ©cessite donc une identitÃ© autorisÃ©e Ã  gÃ©rer IAM ; les identitÃ©s administrateur et CI doivent dÃ©jÃ  exister.

## Configuration GitHub

Dans l'environnement `production`, configurer :

| Type | Nom | Valeur |
|---|---|---|
| Variable | AWS_REGION | RÃ©gion AWS du cluster EKS |
| Variable | EKS_CLUSTER_NAME | Cluster existant |
| Variable | BACKEND_PORT | Port applicatif, dÃ©faut 8000 |
| Variable | BACKEND_HEALTH_PATH | Endpoint HTTP, dÃ©faut /api/v1/health |
| Secret | AWS_ACCESS_KEY_ID | IdentitÃ© CI existante |
| Secret | AWS_SECRET_ACCESS_KEY | ClÃ© de cette identitÃ© |

L'authentification reprend le mÃ©canisme existant du dÃ©pÃ´t. Migrer vers OIDC quand l'administrateur autorisera sa configuration.

## DÃ©ploiement et retour arriÃ¨re

Lancer manuellement le workflow avec le digest publiÃ© par la CI app. Il rend les manifests, valide ceux-ci sur le serveur Kubernetes puis attend la disponibilitÃ© du Deployment. Deux replicas, remplacement progressif, sondes HTTP, limites de ressources et exÃ©cution non-root sont configurÃ©s.

En cas d'Ã©chec, le workflow Ã©choue ; il ne dÃ©clare pas la livraison rÃ©ussie. Pour revenir en arriÃ¨re, relancer le mÃªme workflow avec le dernier digest validÃ©. Un changement incompatible de schÃ©ma DB ne peut pas Ãªtre annulÃ© par un simple changement d'image.

Les migrations RDS doivent Ãªtre exÃ©cutÃ©es une seule fois par livraison dans un Job dÃ©diÃ© adaptÃ© au framework rÃ©el, avant les nouvelles instances et avec compatibilitÃ© avec les anciens pods. Ne pas lancer de migration automatiquement dans chaque replica. Aucun Job de migration gÃ©nÃ©rique ne peut Ãªtre fourni sans connaÃ®tre le backend.

## AccÃ¨s Ã  l'API

Le Service est interne (`ClusterIP`), port 80. Pour un essai :

```sh
kubectl -n creatura port-forward service/creatura-backend 8080:80
```

L'accÃ¨s depuis le frontend nÃ©cessite encore un Ingress HTTPS, un certificat et le contrÃ´leur d'entrÃ©e choisi par l'Ã©quipe. Le chemin `/api/*` de la distribution CloudFront actuelle n'est pas raccordÃ© Ã  ce Service : dÃ©finir cette intÃ©gration avant la mise en production (ou utiliser un domaine API HTTPS distinct avec CORS configurÃ©). Ce workflow ne rend pas RDS ni le backend publics automatiquement.

## Validation locale

```sh
python -m pip install PyYAML==6.0.2
python scripts/render-backend.py --image 'ghcr.io/creatura2026/creatura-backend@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > /tmp/backend.yaml
kubectl apply --dry-run=server -f /tmp/backend.yaml
```

Ne pas appliquer les templates directement : le renderer remplace `IMAGE_REQUIRED`, le port et les sondes. Les manifests ne sont pas gÃ©rÃ©s simultanÃ©ment par Terraform ou un autre contrÃ´leur GitOps.

## Secrets applicatifs et images privÃ©es

Le Secret `creatura-backend` doit fournir au minimum `DATABASE_URL` (RDS avec `?sslmode=require`) et `JWT_SECRET` ; configurer aussi `TIMEZONE=Europe/Paris`, `IMAGE_BASE_URL` et `CORS_ORIGINS` selon les domaines dÃ©ployÃ©s. Lire `backend/.env.example` sur develop pour les options restantes. Ne pas copier les secrets dans Git.

Si le package GHCR est privÃ© : crÃ©er un Secret de type kubernetes.io/dockerconfigjson nommÃ© `ghcr-pull` avec un jeton de lecture de packages, puis ajouter `imagePullSecrets: [{name: ghcr-pull}]` dans `spec.template.spec` du Deployment. Ne pas utiliser un jeton Ã©phÃ©mÃ¨re de CI comme identifiant permanent de pull. Le workflow attendra et Ã©chouera si l'image est inaccessible.

