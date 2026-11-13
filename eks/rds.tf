# =============================================================================
# CREATURA - Base PostgreSQL 16 sur RDS, dans le VPC du cluster EKS
#
# La base vit dans les sous-réseaux privés du cluster : les pods la joignent
# directement, sans bastion ni tunnel. Elle n'a pas d'adresse publique et
# n'accepte que le port 5432 venant des nœuds EKS.
#
# Reprend infra/rds.tf de la branche AS-49-rds (MDi), déplacé ici pour partager
# le VPC et l'état Terraform du cluster : ne pas fusionner les deux, sinon deux
# bases seraient créées.
#
# Accès du back : authentification IAM. Le pod reçoit un rôle IAM par EKS Pod
# Identity et signe un jeton à chaque connexion ; aucun mot de passe applicatif.
# Mot de passe du compte principal : généré par RDS dans Secrets Manager, jamais
# écrit dans le code ni dans l'état Terraform.
#
# Infra créée et détruite à la demande : ni protection contre la suppression,
# ni snapshot final.
# =============================================================================

variable "db_instance_class" {
  description = "Taille de l'instance RDS."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_allocated_storage" {
  description = "Stockage de la base, en Go."
  type        = number
  default     = 20
}

variable "db_engine_version" {
  description = "Version de PostgreSQL (même version majeure que l'image creatura-db)."
  type        = string
  default     = "16"
}

variable "db_backup_retention_days" {
  description = "Durée de conservation des sauvegardes automatiques, en jours (0 = désactivées, 35 au plus). Gratuit jusqu'à la taille de la base."
  type        = number
  default     = 7

  validation {
    condition     = var.db_backup_retention_days >= 0 && var.db_backup_retention_days <= 35
    error_message = "db_backup_retention_days doit être compris entre 0 et 35."
  }
}

variable "db_backup_window" {
  description = "Plage quotidienne de la sauvegarde automatique, en UTC (la nuit, hors des heures de jeu)."
  type        = string
  default     = "01:00-02:00"
}

variable "db_maintenance_window" {
  description = "Plage hebdomadaire de maintenance, en UTC. Ne doit pas chevaucher la sauvegarde."
  type        = string
  default     = "sun:02:30-sun:03:30"
}

variable "db_app_username" {
  description = "Utilisateur PostgreSQL du back, créé par le Job de schéma (k8s/db/schema-job.yaml)."
  type        = string
  default     = "creatura_back"
}

variable "backend_namespace" {
  description = "Namespace Kubernetes du back."
  type        = string
  default     = "creatura"
}

variable "backend_service_account" {
  description = "ServiceAccount du back (k8s/backend/serviceaccount.yaml)."
  type        = string
  default     = "creatura-backend"
}

locals {
  db_name = "creatura"
  db_tags = { Component = "database" }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# -----------------------------------------------------------------------------
# Réseau : sous-réseaux privés du cluster, port 5432 ouvert aux seuls nœuds
# -----------------------------------------------------------------------------
resource "aws_db_subnet_group" "creatura" {
  name_prefix = "creatura-db-"
  description = "Sous-reseaux prives du cluster EKS"
  subnet_ids  = module.vpc.private_subnets
  tags        = local.db_tags
}

resource "aws_security_group" "rds" {
  name_prefix = "creatura-db-"
  description = "PostgreSQL Creatura - acces limite aux noeuds EKS"
  vpc_id      = module.vpc.vpc_id
  tags        = local.db_tags

  lifecycle {
    create_before_destroy = true
  }
}

# Avec le CNI VPC, les pods sortent avec le groupe de sécurité de leur nœud.
resource "aws_vpc_security_group_ingress_rule" "rds_from_nodes" {
  security_group_id            = aws_security_group.rds.id
  description                  = "PostgreSQL depuis les pods du cluster"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = module.eks.node_security_group_id
}

# -----------------------------------------------------------------------------
# La base
# -----------------------------------------------------------------------------
resource "aws_db_parameter_group" "creatura" {
  name_prefix = "creatura-pg16-"
  family      = "postgres16"
  description = "Parametres PostgreSQL 16 de Creatura"
  tags        = local.db_tags

  # Connexions chiffrées obligatoires (le back utilise ?sslmode=require).
  # AWS enregistre ce paramètre en « pending-reboot » : le déclarer ainsi évite un écart à chaque plan.
  parameter {
    name         = "rds.force_ssl"
    value        = "1"
    apply_method = "pending-reboot"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "creatura" {
  identifier_prefix = "creatura-db-"
  engine            = "postgres"
  engine_version    = var.db_engine_version
  instance_class    = var.db_instance_class

  allocated_storage = var.db_allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true

  db_name                     = local.db_name
  username                    = "creatura"
  manage_master_user_password = true

  # Le back se connecte avec un jeton IAM, pas avec un mot de passe.
  iam_database_authentication_enabled = true

  db_subnet_group_name   = aws_db_subnet_group.creatura.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.creatura.name
  publicly_accessible    = false
  multi_az               = false

  # Sauvegarde quotidienne + journaux de transactions : restauration à la seconde près
  # sur toute la durée de conservation (procédure testée : eks/README.md).
  backup_retention_period    = var.db_backup_retention_days
  backup_window              = var.db_backup_window
  maintenance_window         = var.db_maintenance_window
  copy_tags_to_snapshot      = true
  auto_minor_version_upgrade = true
  apply_immediately          = true

  deletion_protection      = false
  skip_final_snapshot      = true
  delete_automated_backups = true

  tags = local.db_tags
}

# -----------------------------------------------------------------------------
# Rôle IAM du back (EKS Pod Identity) : seulement « se connecter à la base en
# tant que creatura_back »
# -----------------------------------------------------------------------------
resource "aws_iam_role" "backend_pod" {
  name        = "${var.cluster_name}-pod"
  description = "Role des pods du back Creatura (EKS Pod Identity)"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy" "backend_rds_connect" {
  name = "rds-db-connect"
  role = aws_iam_role.backend_pod.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "rds-db:connect"
      Resource = "arn:${data.aws_partition.current.partition}:rds-db:${var.aws_region}:${data.aws_caller_identity.current.account_id}:dbuser:${aws_db_instance.creatura.resource_id}/${var.db_app_username}"
    }]
  })
}

resource "aws_eks_pod_identity_association" "backend" {
  cluster_name    = module.eks.cluster_name
  namespace       = var.backend_namespace
  service_account = var.backend_service_account
  role_arn        = aws_iam_role.backend_pod.arn

  # L'agent Pod Identity est un add-on du cluster (main.tf).
  depends_on = [module.eks]
}

# -----------------------------------------------------------------------------
# Sorties : de quoi remplir les Secrets Kubernetes (voir README.md)
# -----------------------------------------------------------------------------
output "db_endpoint" {
  description = "Adresse de la base (sans le port)."
  value       = aws_db_instance.creatura.address
}

output "db_port" {
  description = "Port PostgreSQL."
  value       = aws_db_instance.creatura.port
}

output "db_name" {
  description = "Nom de la base."
  value       = aws_db_instance.creatura.db_name
}

output "db_master_username" {
  description = "Compte principal, utilisé seulement par le Job de schéma."
  value       = aws_db_instance.creatura.username
}

output "db_master_secret_arn" {
  description = "Secret Secrets Manager du compte principal (clé \"password\")."
  value       = aws_db_instance.creatura.master_user_secret[0].secret_arn
}

output "backend_database_url" {
  description = "DATABASE_URL du back : sans mot de passe, le jeton IAM en tient lieu (DB_IAM_AUTH=true)."
  value       = "postgres://${var.db_app_username}@${aws_db_instance.creatura.address}:${aws_db_instance.creatura.port}/${aws_db_instance.creatura.db_name}?sslmode=require"
}

output "backend_pod_role_arn" {
  description = "Rôle IAM porté par les pods du back."
  value       = aws_iam_role.backend_pod.arn
}
