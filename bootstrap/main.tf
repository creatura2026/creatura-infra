locals {
  application_bucket_arns = var.application_bucket_name != "" ? [
    "arn:aws:s3:::${var.application_bucket_name}",
    ] : [
    "arn:aws:s3:::creatura-assets-*",
  ]

  application_object_arns = var.application_bucket_name != "" ? [
    "arn:aws:s3:::${var.application_bucket_name}/*",
    ] : [
    "arn:aws:s3:::creatura-assets-*/*",
  ]

  cloudfront_distribution_arns = [
    "arn:aws:cloudfront::${data.aws_caller_identity.current.account_id}:distribution/*",
  ]

  cloudfront_oac_arns = [
    "arn:aws:cloudfront::${data.aws_caller_identity.current.account_id}:origin-access-control/*",
  ]

  cloudfront_cache_policy_arns = [
    "arn:aws:cloudfront::${data.aws_caller_identity.current.account_id}:cache-policy/*",
  ]

  terraform_state_object_arn = "${aws_s3_bucket.terraform_state.arn}/${var.terraform_state_key}"
  terraform_lock_object_arn  = "${local.terraform_state_object_arn}.tflock"
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "github_actions_trust" {
  statement {
    effect = "Allow"

    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_organization}/${var.github_repository}:environment:${var.github_production_environment}",
      ]
    }
  }
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

resource "aws_iam_role" "github_actions" {
  name               = "${var.github_repository}-github-actions"
  assume_role_policy = data.aws_iam_policy_document.github_actions_trust.json
}

data "aws_iam_policy_document" "github_actions_permissions" {
  statement {
    sid    = "TerraformStateBucketMetadata"
    effect = "Allow"
    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket",
    ]
    resources = [aws_s3_bucket.terraform_state.arn]
  }

  statement {
    sid    = "TerraformStateObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = [local.terraform_state_object_arn, local.terraform_lock_object_arn]
  }

  statement {
    sid       = "CreateApplicationBucket"
    effect    = "Allow"
    actions   = ["s3:CreateBucket"]
    resources = ["*"]
  }

  statement {
    sid    = "ApplicationS3BucketMetadata"
    effect = "Allow"
    actions = [
      "s3:GetBucketAcl",
      "s3:GetBucketAccelerateConfiguration",
      "s3:GetBucketCORS",
      "s3:GetBucketLocation",
      "s3:GetBucketLogging",
      "s3:GetBucketNotification",
      "s3:GetBucketObjectLockConfiguration",
      "s3:GetBucketOwnershipControls",
      "s3:GetBucketPolicy",
      "s3:GetBucketRequestPayment",
      "s3:GetBucketTagging",
      "s3:GetBucketVersioning",
      "s3:GetReplicationConfiguration",
      "s3:GetEncryptionConfiguration",
      "s3:GetLifecycleConfiguration",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
      "s3:GetBucketPublicAccessBlock",
      "s3:PutBucketOwnershipControls",
      "s3:PutBucketPolicy",
      "s3:PutBucketPublicAccessBlock",
      "s3:PutBucketVersioning",
      "s3:PutEncryptionConfiguration",
      "s3:DeleteBucketOwnershipControls",
      "s3:DeleteBucketPolicy",
      "s3:DeleteBucketPublicAccessBlock",
      "s3:DeleteBucket",
    ]
    resources = local.application_bucket_arns
  }

  statement {
    sid    = "ApplicationS3EncryptionAndLifecycle"
    effect = "Allow"
    actions = [
      "s3:DeleteEncryptionConfiguration",
      "s3:DeleteLifecycleConfiguration",
    ]
    resources = local.application_bucket_arns
  }

  statement {
    sid    = "ApplicationS3Objects"
    effect = "Allow"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
      "s3:PutObject",
      "s3:GetObject",
      "s3:DeleteObject",
    ]
    resources = local.application_object_arns
  }

  statement {
    sid    = "CloudFrontCreateAndList"
    effect = "Allow"
    actions = [
      "cloudfront:CreateDistribution",
      "cloudfront:ListDistributions",
      "cloudfront:CreateInvalidation",
      "cloudfront:CreateOriginAccessControl",
      "cloudfront:ListOriginAccessControls",
      "cloudfront:CreateCachePolicy",
      "cloudfront:ListCachePolicies",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "CloudFrontDistributionLifecycle"
    effect = "Allow"
    actions = [
      "cloudfront:GetDistribution",
      "cloudfront:GetDistributionConfig",
      "cloudfront:UpdateDistribution",
      "cloudfront:DeleteDistribution",
      "cloudfront:ListTagsForResource",
      "cloudfront:TagResource",
      "cloudfront:UntagResource",
      "cloudfront:CreateInvalidation",
    ]
    resources = local.cloudfront_distribution_arns
  }

  statement {
    sid    = "CloudFrontOACLifecycle"
    effect = "Allow"
    actions = [
      "cloudfront:GetOriginAccessControl",
      "cloudfront:GetOriginAccessControlConfig",
      "cloudfront:UpdateOriginAccessControl",
      "cloudfront:DeleteOriginAccessControl",
      "cloudfront:ListTagsForResource",
      "cloudfront:TagResource",
      "cloudfront:UntagResource",
    ]
    resources = local.cloudfront_oac_arns
  }

  statement {
    sid    = "CloudFrontCachePolicyLifecycle"
    effect = "Allow"
    actions = [
      "cloudfront:GetCachePolicy",
      "cloudfront:GetCachePolicyConfig",
      "cloudfront:UpdateCachePolicy",
      "cloudfront:DeleteCachePolicy",
    ]
    resources = local.cloudfront_cache_policy_arns
  }

  statement {
    sid       = "IdentifyCaller"
    effect    = "Allow"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "github_actions" {
  name   = "terraform-deployment"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.github_actions_permissions.json
}

# Read-oriented role for pull-request plans. This role cannot apply changes.
# Backend state locking is limited to the single state lock object.
data "aws_iam_policy_document" "github_plan_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_organization}/${var.github_repository}:environment:${var.github_plan_environment}"]
    }
  }
}

resource "aws_iam_role" "github_plan" {
  name               = "${var.github_repository}-terraform-plan"
  assume_role_policy = data.aws_iam_policy_document.github_plan_trust.json
}

data "aws_iam_policy_document" "github_plan_permissions" {
  statement {
    sid       = "ReadStateBucket"
    effect    = "Allow"
    actions   = ["s3:GetBucketLocation", "s3:ListBucket"]
    resources = [aws_s3_bucket.terraform_state.arn]
  }

  statement {
    sid       = "ReadStateObject"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = [local.terraform_state_object_arn]
  }

  statement {
    sid       = "ManageOnlyStateLock"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [local.terraform_lock_object_arn]
  }

  statement {
    sid    = "ReadApplicationBuckets"
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation",
      "s3:GetBucketAcl",
      "s3:GetBucketOwnershipControls",
      "s3:GetBucketPublicAccessBlock",
      "s3:GetBucketPolicy",
      "s3:GetBucketVersioning",
      "s3:GetEncryptionConfiguration",
    ]
    resources = local.application_bucket_arns
  }

  statement {
    sid       = "ReadApplicationObjects"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = local.application_object_arns
  }

  statement {
    sid    = "ListCloudFrontResources"
    effect = "Allow"
    actions = [
      "cloudfront:ListDistributions",
      "cloudfront:ListOriginAccessControls",
      "cloudfront:ListCachePolicies",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ReadCloudFrontDistributions"
    effect = "Allow"
    actions = [
      "cloudfront:GetDistribution",
      "cloudfront:GetDistributionConfig",
      "cloudfront:ListTagsForResource",
    ]
    resources = local.cloudfront_distribution_arns
  }

  statement {
    sid    = "ReadCloudFrontOAC"
    effect = "Allow"
    actions = [
      "cloudfront:GetOriginAccessControl",
      "cloudfront:GetOriginAccessControlConfig",
      "cloudfront:ListTagsForResource",
    ]
    resources = local.cloudfront_oac_arns
  }

  statement {
    sid    = "ReadCloudFrontCachePolicies"
    effect = "Allow"
    actions = [
      "cloudfront:GetCachePolicy",
      "cloudfront:GetCachePolicyConfig",
    ]
    resources = local.cloudfront_cache_policy_arns
  }
}

resource "aws_iam_role_policy" "github_plan" {
  name   = "terraform-plan-readonly"
  role   = aws_iam_role.github_plan.id
  policy = data.aws_iam_policy_document.github_plan_permissions.json
}

data "aws_iam_policy_document" "frontend_deploy_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_organization}/${var.github_repository}:environment:${var.github_production_environment}"]
    }
  }
}

resource "aws_iam_role" "frontend_deploy" {
  name               = "${var.github_repository}-frontend-deploy"
  assume_role_policy = data.aws_iam_policy_document.frontend_deploy_trust.json
}

data "aws_iam_policy_document" "frontend_deploy_permissions" {
  statement {
    sid    = "ReadTerraformState"
    effect = "Allow"
    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket",
    ]
    resources = [aws_s3_bucket.terraform_state.arn]
  }

  statement {
    sid    = "ReadTerraformStateObjects"
    effect = "Allow"
    actions = [
      "s3:GetObject",
    ]
    resources = [local.terraform_state_object_arn]
  }

  statement {
    sid    = "ListApplicationBucket"
    effect = "Allow"
    actions = [
      "s3:GetBucketLocation",
      "s3:ListBucket",
    ]
    resources = local.application_bucket_arns
  }

  statement {
    sid    = "PublishFrontendObjects"
    effect = "Allow"
    actions = [
      "s3:DeleteObject",
      "s3:GetObject",
      "s3:PutObject",
    ]
    resources = local.application_object_arns
  }

  statement {
    sid       = "InvalidateFrontendDistribution"
    effect    = "Allow"
    actions   = ["cloudfront:CreateInvalidation"]
    resources = local.cloudfront_distribution_arns
  }
}

resource "aws_iam_role_policy" "frontend_deploy" {
  name   = "frontend-publish"
  role   = aws_iam_role.frontend_deploy.id
  policy = data.aws_iam_policy_document.frontend_deploy_permissions.json
}

resource "aws_s3_bucket" "terraform_state" {
  bucket = var.state_bucket_name

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_ownership_controls" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

data "aws_iam_policy_document" "terraform_state" {
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"
    actions = [
      "s3:*",
    ]
    resources = [
      aws_s3_bucket.terraform_state.arn,
      "${aws_s3_bucket.terraform_state.arn}/*",
    ]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "terraform_state" {
  bucket = aws_s3_bucket.terraform_state.id
  policy = data.aws_iam_policy_document.terraform_state.json
}