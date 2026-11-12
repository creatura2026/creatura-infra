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
