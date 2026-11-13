# =============================================================================
# CREATURA - Registre d'images ECR (optionnel)
#
# Par défaut les images viennent de GHCR (CI de creatura-app). Ces dépôts
# servent quand GHCR n'est pas utilisable depuis le cluster : images privées
# sans jeton de lecture, ou essai d'une image construite sur un poste.
# Les nœuds EKS peuvent y lire sans secret (politique ECR en lecture seule
# attachée à leur rôle par le module EKS).
# =============================================================================

variable "create_ecr_repositories" {
  description = "Crée les dépôts ECR creatura-backend et creatura-db dans ce compte."
  type        = bool
  default     = false
}

resource "aws_ecr_repository" "images" {
  for_each = var.create_ecr_repositories ? toset(["creatura-backend", "creatura-db"]) : toset([])

  name = each.key
  # La stack est créée et détruite à la demande : le dépôt part avec ses images.
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

output "ecr_repository_urls" {
  description = "Adresse des dépôts ECR par image (vide si create_ecr_repositories = false)."
  value       = { for name, repo in aws_ecr_repository.images : name => repo.repository_url }
}
