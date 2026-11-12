# One-time AWS bootstrap

This stack creates the only resource that must exist before the main `infra/` stack can run: an encrypted, versioned, private S3 bucket that stores the Terraform state.

It does not create any IAM resource. The GitHub OIDC provider and the IAM roles of the first design were removed because IAM is not available in this AWS organization.

The state of this stack stays local, because this stack creates the remote state bucket. Never commit `terraform.tfstate`, and do not delete it while the bucket exists: Terraform needs it to manage the bucket.

The state bucket has `prevent_destroy` enabled: Terraform refuses to destroy it.

```powershell
cd bootstrap
Copy-Item terraform.tfvars.example terraform.tfvars
# Review terraform.tfvars. Bucket names are global: change state_bucket_name if it is already taken.
terraform init
terraform fmt -check
terraform validate
terraform plan -out=bootstrap.tfplan
terraform apply bootstrap.tfplan
```

Use `eu-north-1`: the organization SCP denies `eu-west-1` and `eu-west-3`.

The outputs give the values for `terraform init` in `../infra` and for the GitHub repository variables:

- `state_bucket_name` -> `TF_STATE_BUCKET`
- `state_bucket_region` -> `TF_STATE_REGION`
- `terraform_state_key` -> `TF_STATE_KEY`
