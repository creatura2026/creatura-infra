# A51 — Déploiement du backend sur AWS EKS

Base : `as-44-v2-config-cdn-s3`. Cette partie déploie le backend ; elle ne construit aucune image et ne crée pas de cluster AWS lui-même (voir la stack `eks/`).

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
- RDS joignable depuis les pods et ses règles réseau ; chiffrement TLS configuré dans le client applicatif.

La stack `eks/` crée les rôles du cluster et des nœuds. Son exécution nécessite donc une identité autorisée à gérer IAM ; les identités administrateur et CI doivent déjà exister.

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

Les migrations RDS doivent être exécutées une seule fois par livraison dans un Job dédié adapté au framework réel, avant les nouvelles instances et avec compatibilité avec les anciens pods. Ne pas lancer de migration automatiquement dans chaque replica. Aucun Job de migration générique ne peut être fourni sans connaître le backend.

## Accès à l'API

Le Service est interne (`ClusterIP`), port 80. Pour un essai :

```sh
kubectl -n creatura port-forward service/creatura-backend 8080:80
```

L'accès depuis le frontend nécessite encore un Ingress HTTPS, un certificat et le contrôleur d'entrée choisi par l'équipe. Le chemin `/api/*` de la distribution CloudFront actuelle n'est pas raccordé à ce Service : définir cette intégration avant la mise en production (ou utiliser un domaine API HTTPS distinct avec CORS configuré). Ce workflow ne rend pas RDS ni le backend publics automatiquement.

## Validation locale

```sh
python -m pip install PyYAML==6.0.2
python scripts/render-backend.py --image 'ghcr.io/creatura2026/creatura-backend@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > /tmp/backend.yaml
kubectl apply --dry-run=server -f /tmp/backend.yaml
```

Ne pas appliquer les templates directement : le renderer remplace `IMAGE_REQUIRED`, le port et les sondes. Les manifests ne sont pas gérés simultanément par Terraform ou un autre contrôleur GitOps.

## Secrets applicatifs et images privées

Le Secret `creatura-backend` doit fournir au minimum `DATABASE_URL` (RDS avec `?sslmode=require`) et `JWT_SECRET` ; configurer aussi `TIMEZONE=Europe/Paris`, `IMAGE_BASE_URL` et `CORS_ORIGINS` selon les domaines déployés. Lire `backend/.env.example` sur develop pour les options restantes. Ne pas copier les secrets dans Git.

Si le package GHCR est privé : créer un Secret de type kubernetes.io/dockerconfigjson nommé `ghcr-pull` avec un jeton de lecture de packages, puis ajouter `imagePullSecrets: [{name: ghcr-pull}]` dans `spec.template.spec` du Deployment. Ne pas utiliser un jeton éphémère de CI comme identifiant permanent de pull. Le workflow attendra et échouera si l'image est inaccessible.
