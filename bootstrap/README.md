# One-time AWS bootstrap

This stack creates the resources that must exist before the main `infra/` stack can run:

- GitHub Actions OIDC provider
- Environment-restricted IAM role for the infrastructure workflow
- Encrypted, versioned, private S3 bucket for Terraform state

Run this stack once from an administrator-authenticated AWS session. Do not configure this stack to use the S3 backend it creates.

The bootstrap state stays local because this stack creates the remote state bucket. Protect `terraform.tfstate` as sensitive data and keep an encrypted offline backup; never commit it to Git. The state bucket and application bucket have Terraform deletion protection enabled.

```powershell
cd bootstrap
Copy-Item terraform.tfvars.example terraform.tfvars
# Review terraform.tfvars. The example is configured for creatura2026/creatura-infra in eu-west-3; change the bucket name if it is already taken.
terraform init
terraform fmt -check
terraform validate
terraform plan -out=bootstrap.tfplan
terraform apply bootstrap.tfplan
```

Copy the outputs into GitHub repository or environment variables:

- `aws_role_arn` -> `AWS_ROLE_ARN`
- `plan_role_arn` -> `AWS_PLAN_ROLE_ARN`
- `frontend_deploy_role_arn` -> `AWS_FRONTEND_ROLE_ARN`
- `state_bucket_name` -> `TF_STATE_BUCKET`
- `state_bucket_region` -> `TF_STATE_REGION`
- `terraform_state_key` -> `TF_STATE_KEY`

Set the GitHub inputs separately. `github_organization` must be `creatura2026` and `github_repository` must be `creatura-infra`; do not use `creatura2026/creatura-infra` as the repository variable because IAM role names cannot contain `/`.

When `infra` uses a custom `bucket_name`, set the same value as `application_bucket_name` in this stack and apply the bootstrap again. Otherwise, leave it empty and use the default `creatura-assets-*` bucket prefix.

The Terraform role trusts the `terraform-plan` and `production` GitHub Environments. The frontend deployment role trusts only `production`. Configure the `terraform-plan` Environment for pull requests and the `production` Environment with required reviewers and a branch rule allowing only `main`. Environment protection rules enforce the branch and approval controls; the IAM trust policies restrict which environments may assume each role.

If the IAM policy changes, run `terraform plan` and `terraform apply` in this directory again using the bootstrap administrator session. The normal CI role cannot update its own bootstrap policy until these permissions are applied.