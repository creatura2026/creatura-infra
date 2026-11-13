terraform {
  required_version = ">= 1.10, < 2.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = { Project = "Creatura", ManagedBy = "Terraform", Ticket = "A51" }
  }
}

variable "aws_region" {
  type    = string
  default = "eu-north-1"
}
variable "cluster_name" {
  type    = string
  default = "creatura-backend"
}
variable "paused" {
  description = "Pause (scripts/aws-pause.sh) : NAT supprimé et nœuds autorisés à 0. Le cluster, la base, l'ALB et le réseau restent."
  type        = bool
  default     = false
}
variable "kubernetes_version" {
  description = "Version EKS en support standard disponible dans la région ; à choisir avant création."
  type        = string
}
variable "deployment_principal_arn" {
  description = "Identité de déploiement limitée au namespace (facultative)."
  type        = string
  default     = null
}
variable "endpoint_public_access_cidrs" {
  description = "CIDR autorisés sur l'API EKS (runner et administrateur). Pas d'accès public implicite."
  type        = list(string)
  validation {
    condition     = length(var.endpoint_public_access_cidrs) > 0 && !contains(var.endpoint_public_access_cidrs, "0.0.0.0/0")
    error_message = "Fournir les CIDR restreints des runners/administrateurs."
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}
module "vpc" {
  source               = "terraform-aws-modules/vpc/aws"
  version              = "5.21.0"
  name                 = var.cluster_name
  cidr                 = "10.51.0.0/16"
  azs                  = slice(data.aws_availability_zones.available.names, 0, 2)
  private_subnets      = ["10.51.1.0/24", "10.51.2.0/24"]
  public_subnets       = ["10.51.101.0/24", "10.51.102.0/24"]
  # En pause, plus aucun nœud ne sort sur Internet : le NAT (payant à l'heure) est supprimé.
  enable_nat_gateway   = !var.paused
  single_nat_gateway   = true
  enable_dns_hostnames = true
  public_subnet_tags   = { "kubernetes.io/role/elb" = "1" }
  private_subnet_tags  = { "kubernetes.io/role/internal-elb" = "1" }
}
module "eks" {
  source                                   = "terraform-aws-modules/eks/aws"
  version                                  = "20.37.2"
  cluster_name                             = var.cluster_name
  cluster_version                          = var.kubernetes_version
  cluster_endpoint_public_access           = true
  cluster_endpoint_private_access          = true
  cluster_endpoint_public_access_cidrs     = var.endpoint_public_access_cidrs
  enable_cluster_creator_admin_permissions = false
  authentication_mode                      = "API"
  enable_irsa                              = false
  vpc_id                                   = module.vpc.vpc_id
  subnet_ids                               = module.vpc.private_subnets
  cluster_addons = {
    coredns    = {}
    kube-proxy = {}
    vpc-cni    = { before_compute = true }
    # Donne aux pods du back leur rôle IAM (rds.tf) sans fournisseur OIDC.
    eks-pod-identity-agent = {}
  }
  # L'ALB de l'API (api.tf) joint le NodePort du back sur les nœuds.
  node_security_group_additional_rules = {
    ingress_api_alb = {
      description              = "API depuis le repartiteur de charge (ALB)"
      type                     = "ingress"
      protocol                 = "tcp"
      from_port                = var.api_node_port
      to_port                  = var.api_node_port
      source_security_group_id = aws_security_group.api_alb.id
    }
  }
  eks_managed_node_groups = {
    backend = {
      # AL2 n'existe plus à partir de Kubernetes 1.33 : type d'AMI explicite.
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["t3.small"]
      # Taille souhaitée ignorée par le module après création : aws-pause.sh et aws-up.sh la règlent par la CLI.
      min_size       = var.paused ? 0 : 2
      max_size       = 3
      desired_size   = 2
    }
  }
  access_entries = var.deployment_principal_arn == null || var.deployment_principal_arn == var.administrator_principal_arn ? {} : {
    deployment = {
      principal_arn = var.deployment_principal_arn
      policy_associations = {
        namespace = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
          access_scope = {
            type       = "namespace"
            namespaces = ["creatura"]
          }
        }
      }
    }
  }
}
variable "administrator_principal_arn" {
  description = "Identité administrateur pour initialiser namespace, secrets et contrôleurs."
  type        = string
}
resource "aws_eks_access_entry" "administrator" {
  cluster_name  = module.eks.cluster_name
  principal_arn = var.administrator_principal_arn
}
resource "aws_eks_access_policy_association" "administrator" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_eks_access_entry.administrator.principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope { type = "cluster" }
}
output "cluster_name" { value = module.eks.cluster_name }
output "vpc_id" { value = module.vpc.vpc_id }
output "node_security_group_id" { value = module.eks.node_security_group_id }

# La CI de provisioning doit initialiser namespace, secrets et Job SQL.
# Aucun doublon quand les clés CI et le poste utilisent le même utilisateur IAM.
variable "ci_administrator_principal_arn" {
  description = "Identité du workflow de provisioning, si différente de l'administrateur."
  type        = string
  default     = null
}
resource "aws_eks_access_entry" "ci_administrator" {
  count         = var.ci_administrator_principal_arn != null && var.ci_administrator_principal_arn != var.administrator_principal_arn ? 1 : 0
  cluster_name  = module.eks.cluster_name
  principal_arn = var.ci_administrator_principal_arn
}
resource "aws_eks_access_policy_association" "ci_administrator" {
  count         = length(aws_eks_access_entry.ci_administrator)
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_eks_access_entry.ci_administrator[0].principal_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  access_scope { type = "cluster" }
}
