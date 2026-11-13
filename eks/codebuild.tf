# =============================================================================
# CREATURA - Construction des images dans AWS (CodeBuild -> ECR)
#
# Remplace docker build / docker push sur un poste : scripts/build-images.sh
# dépose le code de creatura-app dans un bucket S3, puis lance ce projet avec
# la CLI AWS (aws codebuild start-build). Le build tourne sur une machine
# Linux x86_64, l'architecture des nœuds, et pousse lui-même dans ECR.
#
# Un seul projet pour les deux images : le dépôt ECR cible (variable IMAGE)
# et l'archive source sont choisis à chaque lancement.
#
# Peut être créé avant le reste de la stack, pour construire les images
# pendant la création du cluster (voir eks/README.md) :
#   terraform -chdir=eks apply -target=aws_codebuild_project.images
# =============================================================================

variable "create_image_builder" {
  description = "Crée le projet CodeBuild, son bucket source et son rôle. Exige create_ecr_repositories = true."
  type        = bool
  default     = false

  validation {
    condition     = !var.create_image_builder || var.create_ecr_repositories
    error_message = "create_image_builder exige create_ecr_repositories = true : les images sont poussées dans ces dépôts."
  }
}

locals {
  image_builder_name = "${var.cluster_name}-images"
  image_builder      = var.create_image_builder ? toset(["this"]) : toset([])
}

# data.aws_caller_identity.current est déclaré dans rds.tf.

# --- Bucket des archives source ----------------------------------------------

resource "aws_s3_bucket" "image_sources" {
  for_each = local.image_builder

  bucket_prefix = "creatura-image-sources-"
  # Créé et détruit avec la stack ; les archives se recréent à chaque build.
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "image_sources" {
  for_each = local.image_builder

  bucket                  = aws_s3_bucket.image_sources["this"].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "image_sources" {
  for_each = local.image_builder

  bucket = aws_s3_bucket.image_sources["this"].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Les archives ne servent qu'au build en cours.
resource "aws_s3_bucket_lifecycle_configuration" "image_sources" {
  for_each = local.image_builder

  bucket = aws_s3_bucket.image_sources["this"].id
  rule {
    id     = "expire-sources"
    status = "Enabled"
    filter {}
    expiration {
      days = 7
    }
  }
}

# --- Journaux ---------------------------------------------------------------

resource "aws_cloudwatch_log_group" "image_builder" {
  for_each = local.image_builder

  name              = "/aws/codebuild/${local.image_builder_name}"
  retention_in_days = 7
}

# --- Rôle du build ------------------------------------------------------------

resource "aws_iam_role" "image_builder" {
  for_each = local.image_builder

  name = "${local.image_builder_name}-codebuild"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
      }
    }]
  })
}

resource "aws_iam_role_policy" "image_builder" {
  for_each = local.image_builder

  name = "build-and-push"
  role = aws_iam_role.image_builder["this"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.image_builder["this"].arn}:*"
      },
      {
        Sid      = "ReadSources"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion"]
        Resource = "${aws_s3_bucket.image_sources["this"].arn}/*"
      },
      {
        Sid      = "EcrLogin"
        Effect   = "Allow"
        Action   = "ecr:GetAuthorizationToken"
        Resource = "*"
      },
      {
        Sid    = "PushImages"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeImages",
          "ecr:GetDownloadUrlForLayer",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
        ]
        Resource = [for repo in aws_ecr_repository.images : repo.arn]
      },
    ]
  })
}

# --- Projet ------------------------------------------------------------------

resource "aws_codebuild_project" "images" {
  for_each = local.image_builder

  name          = local.image_builder_name
  description   = "Construit creatura-backend ou creatura-db (variable IMAGE) et pousse l'image dans ECR."
  service_role  = aws_iam_role.image_builder["this"].arn
  build_timeout = 20

  # Remplacée à chaque lancement par --source-location-override.
  source {
    type      = "S3"
    location  = "${aws_s3_bucket.image_sources["this"].bucket}/placeholder.zip"
    buildspec = file("${path.module}/buildspec-images.yml")
  }

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    type            = "LINUX_CONTAINER"
    compute_type    = "BUILD_GENERAL1_SMALL"
    image           = "aws/codebuild/amazonlinux-x86_64-standard:5.0"
    privileged_mode = true # nécessaire pour lancer Docker dans le build

    environment_variable {
      name  = "REGISTRY"
      value = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
    }
    environment_variable {
      name  = "IMAGE"
      value = "creatura-backend"
    }
    environment_variable {
      name  = "TAG"
      value = "latest"
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.image_builder["this"].name
    }
  }

  depends_on = [aws_iam_role_policy.image_builder]
}

output "image_builder_project" {
  description = "Nom du projet CodeBuild (vide si create_image_builder = false)."
  value       = try(aws_codebuild_project.images["this"].name, "")
}

output "image_source_bucket" {
  description = "Bucket des archives source des builds (vide si create_image_builder = false)."
  value       = try(aws_s3_bucket.image_sources["this"].bucket, "")
}
