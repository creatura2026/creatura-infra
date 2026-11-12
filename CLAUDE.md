# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Does

Infrastructure-only repository for Creatura: a static frontend served through AWS CloudFront from a private S3 bucket. The application source code lives in the separate `creatura-app` repository. This repo owns all Terraform, the GitHub Actions workflows, and the sprite image assets.

## AWS Constraints

- **Region: `eu-north-1`.** The organization SCP explicitly denies `eu-west-1` and `eu-west-3`. CloudFront is a global service; only the buckets live in `eu-north-1`.
- **No IAM.** Team members use IAM users with static access keys and cannot read or create IAM resources. The stacks therefore create no role, policy or OIDC provider, and CI authenticates with static keys stored as GitHub secrets.

## Two Terraform Stacks

### `bootstrap/` — run once

Creates only the S3 bucket that stores the Terraform state of `infra/`. Its own state stays **local**, because it creates the bucket that would hold it.

```powershell
cd bootstrap
Copy-Item terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values
terraform init
terraform plan -out=bootstrap.tfplan
terraform apply bootstrap.tfplan
```

Outputs feed the GitHub Actions variables `TF_STATE_BUCKET`, `TF_STATE_REGION` and `TF_STATE_KEY`.

### `infra/` — managed by CI

Creates the S3 application bucket (`creatura-assets-<suffix>`), uploads all PNGs from `images/` under the `sprites/` prefix, and provisions the CloudFront distribution. Uses an S3 remote backend with a partial configuration, so `terraform init` needs `-backend-config` values and the state bucket must already exist.

Checks that need no AWS access:

```powershell
terraform -chdir=infra init -backend=false
terraform fmt -check -recursive
terraform -chdir=infra validate
```

Local plan (requires AWS credentials):

```powershell
cd infra
terraform init `
  -backend-config="bucket=<TF_STATE_BUCKET>" `
  -backend-config="key=creatura-infra/terraform.tfstate" `
  -backend-config="region=eu-north-1" `
  -backend-config="encrypt=true" `
  -backend-config="use_lockfile=true"
terraform plan -var="aws_region=eu-north-1"
```

## CI/CD

Two workflows under `.github/workflows/`, both authenticated with the `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` repository secrets:

- **`terraform.yml`** — on pull requests and pushes to `main` that touch `infra/**`: format check, init, validate, plan; **apply on `main`**. Merging an `infra/` change into `main` therefore changes the real AWS resources.
- **`deploy-frontend.yml`** — triggered by the app CI (`repository_dispatch` `frontend-updated`) or manually: downloads the frontend artifact, syncs it to S3 (excluding `sprites/*`), uploads `index.html` last and invalidates CloudFront.

Repository variables: `AWS_REGION` (`eu-north-1`), `TF_STATE_BUCKET`, `TF_STATE_KEY`, `TF_STATE_REGION`, `APP_REPOSITORY`, `APP_PRODUCTION_BRANCH`, optionally `APP_WORKFLOW_ID`. Secret `APP_REPO_TOKEN` gives read access to the app repository artifacts.

The same access keys are used for plans and applies: they must belong to a dedicated IAM user restricted to this stack, not to a personal administrator account.

## CloudFront Caching Strategy

Defined in `infra/cloudfront.tf`:

- `index.html` (default behavior): zero-TTL cache policy, always revalidated.
- `assets/*` and `sprites/*`: managed long-lived policy (one-year immutable files).
- The private bucket is read only by this distribution, through Origin Access Control (SigV4).

## Sprite Image Utilities (`sprites.py`)

Not part of CI. Manual utility requiring `Pillow`:

```bash
python sprites.py sheet images/ sheet.png
python sprites.py resize images/ images-resized/ --size 128 --margin 4
```

## Outdated Documents

`summary.md` and `audit-report.md` describe the first design (region `eu-west-3`, GitHub OIDC, three IAM roles). They no longer match the code.
