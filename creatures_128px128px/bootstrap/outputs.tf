output "aws_role_arn" {
  description = "Set this as the GitHub Actions AWS_ROLE_ARN variable."
  value       = aws_iam_role.github_actions.arn
}

output "plan_role_arn" {
  description = "Set this as the GitHub Actions AWS_PLAN_ROLE_ARN variable."
  value       = aws_iam_role.github_plan.arn
}

output "frontend_deploy_role_arn" {
  description = "Set this as the GitHub Actions AWS_FRONTEND_ROLE_ARN variable."
  value       = aws_iam_role.frontend_deploy.arn
}

output "state_bucket_name" {
  description = "Set this as the TF_STATE_BUCKET variable."
  value       = aws_s3_bucket.terraform_state.bucket
}

output "state_bucket_region" {
  description = "Set this as the TF_STATE_REGION variable."
  value       = var.aws_region
}

output "terraform_state_key" {
  description = "Set this as the GitHub Actions TF_STATE_KEY variable."
  value       = var.terraform_state_key
}