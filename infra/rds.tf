# =============================================================================
# CREATURA - Base de données PostgreSQL 16 sur Amazon RDS
# Ticket : AS-48 · Auteur : MDi
#
# Tout est dans ce fichier (variables, ressources, sorties) pour ne pas toucher
# aux fichiers du reste de la stack.
#
# ⚠️  INTERRUPTEUR : create_rds = false par défaut.
#     Un push sur main déclenche "terraform apply" (workflow terraform.yml) :
#     tant que create_rds vaut false, ce fichier ne crée RIEN et ne coûte rien.
#     Pour créer la base : -var="create_rds=true" (ou dans un .tfvars).
#
# Choix adaptés aux contraintes du compte AWS (voir CLAUDE.md) :
#   * région de la stack (eu-north-1), pas de région en dur ici ;
#   * aucune ressource IAM créée ;
#   * infra créée et détruite à la demande : pas de protection contre la
#     suppression, pas de snapshot final ;
#   * mot de passe généré et stocké par RDS dans Secrets Manager : il n'est
#     jamais écrit dans le code ni dans le tfstate.
#
# Réseau : pas encore de VPC dédié dans la stack. Par défaut, la base est placée
# dans le VPC par défaut de la région. Dès qu'un VPC existe, renseigner
# db_vpc_id et db_subnet_ids.
# =============================================================================

# -----------------------------------------------------------------------------
# Variables
# -----------------------------------------------------------------------------
variable "create_rds" {
  description = "Crée la base RDS. false par défaut : un merge sur main ne crée rien."
  type        = bool
  default     = false
}

variable "db_vpc_id" {
  description = "VPC de la base. Vide = VPC par défaut de la région."
  type        = string
  default     = ""
}

variable "db_subnet_ids" {
  description = "Sous-réseaux de la base (au moins 2 zones). Vide = sous-réseaux du VPC par défaut."
  type        = list(string)
  default     = []
}

variable "db_allowed_security_group_ids" {
  description = "Groupes de sécurité autorisés à se connecter au port 5432 (ex. celui de l'API)."
  type        = list(string)
  default     = []
}

variable "db_allowed_cidr_blocks" {
  description = "Plages IP autorisées sur le port 5432 (ex. IP de l'équipe pour appliquer le schéma). Vide par défaut."
  type        = list(string)
  default     = []
}

variable "db_publicly_accessible" {
  description = "Donne une adresse publique à la base. À n'activer que temporairement, avec db_allowed_cidr_blocks."
  type        = bool
  default     = false
}

variable "db_instance_class" {
  description = "Taille de l'instance."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_allocated_storage" {
  description = "Stockage en Go."
  type        = number
  default     = 20
}

variable "db_multi_az" {
  description = "Réplique de secours dans une 2e zone (double le coût)."
  type        = bool
  default     = false
}

variable "db_backup_retention_days" {
  description = "Durée de conservation des sauvegardes automatiques (0 = désactivées)."
  type        = number
  default     = 1
}

variable "db_engine_version" {
  description = "Version de PostgreSQL (même version majeure que l'image Docker locale)."
  type        = string
  default     = "16"
}

# -----------------------------------------------------------------------------
# Réseau : VPC par défaut si aucun VPC n'est fourni
# -----------------------------------------------------------------------------
locals {
  rds_use_default_vpc = var.create_rds && var.db_vpc_id == ""

  rds_tags = {
    Project   = "creatura"
    Component = "database"
    Owner     = "MDi"
  }
}

data "aws_vpc" "rds_default" {
  count   = local.rds_use_default_vpc ? 1 : 0
  default = true
}

data "aws_subnets" "rds_default" {
  count = local.rds_use_default_vpc ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.rds_default[0].id]
  }
}

locals {
  rds_vpc_id     = var.db_vpc_id != "" ? var.db_vpc_id : try(data.aws_vpc.rds_default[0].id, "")
  rds_subnet_ids = length(var.db_subnet_ids) > 0 ? var.db_subnet_ids : try(data.aws_subnets.rds_default[0].ids, [])
}

resource "aws_db_subnet_group" "creatura" {
  count       = var.create_rds ? 1 : 0
  name_prefix = "creatura-db-"
  description = "Sous-reseaux de la base Creatura"
  subnet_ids  = local.rds_subnet_ids
  tags        = local.rds_tags
}

# -----------------------------------------------------------------------------
# Pare-feu : rien n'entre, sauf ce qui est explicitement autorisé
# -----------------------------------------------------------------------------
resource "aws_security_group" "rds" {
  count       = var.create_rds ? 1 : 0
  name_prefix = "creatura-db-"
  description = "PostgreSQL Creatura - acces limite a l API et aux IP autorisees"
  vpc_id      = local.rds_vpc_id
  tags        = local.rds_tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_sg" {
  for_each = var.create_rds ? toset(var.db_allowed_security_group_ids) : toset([])

  security_group_id            = aws_security_group.rds[0].id
  description                  = "PostgreSQL depuis un groupe de securite autorise"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = each.value
}

resource "aws_vpc_security_group_ingress_rule" "rds_from_cidr" {
  for_each = var.create_rds ? toset(var.db_allowed_cidr_blocks) : toset([])

  security_group_id = aws_security_group.rds[0].id
  description       = "PostgreSQL depuis une IP autorisee"
  ip_protocol       = "tcp"
  from_port         = 5432
  to_port           = 5432
  cidr_ipv4         = each.value
}

# -----------------------------------------------------------------------------
# Paramètres PostgreSQL : connexions chiffrées (SSL) obligatoires
# -----------------------------------------------------------------------------
resource "aws_db_parameter_group" "creatura" {
  count       = var.create_rds ? 1 : 0
  name_prefix = "creatura-pg16-"
  family      = "postgres16"
  description = "Parametres PostgreSQL 16 de Creatura"
  tags        = local.rds_tags

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  lifecycle {
    create_before_destroy = true
  }
}

# -----------------------------------------------------------------------------
# La base
# -----------------------------------------------------------------------------
resource "aws_db_instance" "creatura" {
  count = var.create_rds ? 1 : 0

  identifier_prefix = "creatura-db-"
  engine            = "postgres"
  engine_version    = var.db_engine_version
  instance_class    = var.db_instance_class

  allocated_storage = var.db_allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = "creatura"
  username = "creatura"
  # RDS génère le mot de passe et le range dans Secrets Manager
  manage_master_user_password = true

  db_subnet_group_name   = aws_db_subnet_group.creatura[0].name
  vpc_security_group_ids = [aws_security_group.rds[0].id]
  parameter_group_name   = aws_db_parameter_group.creatura[0].name
  publicly_accessible    = var.db_publicly_accessible
  multi_az               = var.db_multi_az

  backup_retention_period    = var.db_backup_retention_days
  auto_minor_version_upgrade = true
  apply_immediately          = true

  # Infra créée et détruite à la demande
  deletion_protection      = false
  skip_final_snapshot      = true
  delete_automated_backups = true

  tags = local.rds_tags
}

# -----------------------------------------------------------------------------
# Sorties : ce dont l'API et le Job de migration ont besoin
# -----------------------------------------------------------------------------
output "db_endpoint" {
  description = "Adresse de la base (sans le port). Vide si create_rds = false."
  value       = try(aws_db_instance.creatura[0].address, "")
}

output "db_port" {
  description = "Port PostgreSQL."
  value       = try(aws_db_instance.creatura[0].port, null)
}

output "db_name" {
  description = "Nom de la base."
  value       = try(aws_db_instance.creatura[0].db_name, "")
}

output "db_username" {
  description = "Utilisateur principal."
  value       = try(aws_db_instance.creatura[0].username, "")
}

output "db_master_secret_arn" {
  description = "Secret Secrets Manager qui contient le mot de passe (clé \"password\")."
  value       = try(aws_db_instance.creatura[0].master_user_secret[0].secret_arn, "")
}

output "db_security_group_id" {
  description = "Groupe de sécurité de la base."
  value       = try(aws_security_group.rds[0].id, "")
}
