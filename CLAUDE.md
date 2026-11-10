# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Does

Infrastructure-only repository for Creatura: a static frontend served through AWS CloudFront. The application source code lives in a separate app repository. This repo owns all Terraform, IAM roles, GitHub Actions workflows, and the sprite image assets.

Target AWS region: `eu-west-3` (Paris).

## Two Terraform Stacks

### `bootstrap/` — run once by an admin

Creates the remote state S3 bucket, GitHub OIDC provider, and three IAM roles (apply, plan-only, frontend-deploy). Bootstrap state stays **local** because it creates the bucket that stores the main stack's state. Run with an administrator AWS session:

```powershell
cd bootstrap
Copy-Item terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values
terraform init
terraform fmt -check
terraform validate
terraform plan -out=bootstrap.tfplan
terraform apply bootstrap.tfplan
```

Outputs feed the GitHub Actions variables `AWS_ROLE_ARN`, `TF_STATE_BUCKET`, `TF_STATE_REGION`.

### `infra/` — managed by CI

Creates the S3 application bucket (`creatura-assets-<suffix>`), uploads all PNGs from `images/` under the `sprites/` prefix, and provisions the CloudFront distribution. Uses an S3 remote backend — `terraform init` requires the state bucket to already exist.

Local plan (requires AWS credentials):
```bash
cd infra
terraform init \
  -backend-config="bucket=<TF_STATE_BUCKET>" \
  -backend-config="key=creatura-infra/terraform.tfstate" \
  -backend-config="region=eu-west-3" \
  -backend-config="encrypt=true" \
  -backend-config="use_lockfile=true"
terraform fmt -check -recursive
terraform validate
terraform plan -var="aws_region=eu-west-3"
```

## CI/CD Architecture

Two workflows under `.github/workflows/`:

**`terraform.yml`** — triggered on PRs and pushes to `main` affecting `infra/**`:
- PR → `terraform-plan` environment, plan only (read-only IAM role)
- Push to `main` → `production` environment, plan + apply

**`deploy-frontend.yml`** — triggered by `repository_dispatch` event `frontend-updated` from app CI, or manually via `workflow_dispatch`:
1. Verifies the source app workflow run (completed, success, correct branch)
2. Downloads the frontend artifact
3. Reads S3 bucket name and CloudFront distribution ID from Terraform state outputs
4. Syncs frontend to S3, excluding `sprites/*` and `.creatura/*`
5. Uploads `index.html` last (with `no-cache` headers)
6. Invalidates CloudFront and waits for completion
7. Verifies HTTP response headers on root, a sprite, and a hashed asset
8. Writes `.creatura/frontend-release.json` as a release marker

Rollback: manually dispatch `deploy-frontend.yml` with a previous successful run ID and `allow_rollback: true`.

## IAM Role Split

Three roles created by bootstrap, each with minimal permissions:
- **apply role** (`AWS_ROLE_ARN`): full Terraform lifecycle (S3, CloudFront CRUD)
- **plan role** (`AWS_PLAN_ROLE_ARN`): read-only, used for PR plans
- **frontend deploy role** (`AWS_FRONTEND_ROLE_ARN`): can S3 sync + CloudFront invalidate + read state, **cannot** write Terraform state

No long-lived AWS keys — all authentication is GitHub OIDC.

## CloudFront Caching Strategy

Defined in `infra/cloudfront.tf`:
- `index.html` (default behavior): zero TTL cache policy — always revalidates
- `assets/*` and `sprites/*`: managed long-lived policy `658327ea-...` (1-year immutable)
- Sprites served from the private S3 bucket through Origin Access Control (SigV4)

The deployment workflow uploads hashed assets first, then `index.html` last to ensure no window where new HTML references missing assets.

## Sprite Image Utilities (`sprites.py`)

Not part of CI. Manual utility requiring `Pillow`:

```bash
# Generate a numbered contact sheet for reviewing all sprites
python sprites.py sheet images/ sheet.png

# Resize all sprites to uniform size with margin
python sprites.py resize images/ images-resized/ --size 128 --margin 4
```

## GitHub Repository Configuration

Variables needed (repository or environment level):
```
AWS_REGION=eu-west-3
AWS_ROLE_ARN          # from bootstrap output
AWS_PLAN_ROLE_ARN     # from bootstrap output
AWS_FRONTEND_ROLE_ARN # from bootstrap output
TF_STATE_BUCKET       # from bootstrap output
TF_STATE_REGION=eu-west-3
TF_STATE_KEY=creatura-infra/terraform.tfstate
APP_REPOSITORY=<owner>/<app-repo>
APP_PRODUCTION_BRANCH=main
APP_WORKFLOW_ID       # optional, locks frontend deploy to a specific workflow
```

Secret (for private app repository):
```
APP_REPO_TOKEN  # GitHub token with access to app workflow artifacts
```

Protect the `production` environment with required reviewers and restrict it to the `main` branch. The IAM trust policies are scoped to these environment subjects — if environment names change, the bootstrap stack must be re-applied.
