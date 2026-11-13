# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Repo Does

Infrastructure repository for Creatura: two static web apps (player PWA and admin dashboard) served through AWS CloudFront from a private S3 bucket. The application source lives in the separate `creatura-app` repository (pnpm monorepo, `apps/player` and `apps/admin`). This repo owns the Terraform, the GitHub Actions workflows, the deploy script, and the sprite images.

## AWS Constraints (verified 2026-11-11)

- **Region: `eu-north-1`.** The organization SCP `p-0vevikxq` explicitly denies `eu-west-1` and `eu-west-3`. `us-east-1` is allowed, which CloudFront (a global service) needs.
- **No IAM.** Team members use IAM users with static access keys and cannot read or create IAM resources. The stacks therefore create no role, policy or OIDC provider, and CI authenticates with static keys stored as GitHub secrets.
- **CloudFront needs explicit permissions.** An IAM user that only has S3 rights gets `AccessDenied ... no identity-based policy allows the cloudfront:...`. That is a missing IAM policy on the user, not the SCP. `CloudFrontFullAccess` is enough.

## Two Terraform Stacks

### `bootstrap/` — run once

Creates only the S3 bucket that stores the Terraform state. Its own state stays local.

### `infra/`

Creates the application bucket (`creatura-assets-<suffix>`), uploads the PNGs of `images/` under `sprites/`, and provisions the CloudFront distribution, its Origin Access Control and the `creatura-spa-rewrite` CloudFront Function. Uses the S3 backend with a partial configuration, so `terraform init` needs `-backend-config` values (see `infra/README.md`).

Checks that need no AWS access:

```powershell
terraform -chdir=infra init -backend=false
terraform -chdir=infra fmt -check -recursive
terraform -chdir=infra validate
```

## Create and Destroy on Demand

The whole infrastructure is meant to be created and destroyed repeatedly to save AWS credits, so both buckets use `force_destroy = true` and no `prevent_destroy`. Create: `bootstrap` apply, `infra` init + apply, `scripts/deploy-frontend.ps1`. Destroy: `infra` destroy first, then `bootstrap` destroy. A bucket created before `force_destroy` was added needs one `terraform apply` before `terraform destroy`. The CloudFront hostname and the application bucket name change on every re-creation.

## Site Layout and Caching

- `/` player PWA, `/admin/` admin dashboard (built with `--base=/admin/`), `/sprites/*` images, `/api/*` the backend.
- Both apps use history-mode routing. `infra/functions/spa-rewrite.js` rewrites any URL without a file extension to `/index.html` or `/admin/index.html`. It is attached to the default cache behavior only.
- `assets/*`, `admin/assets/*`, `sprites/*`: managed `CachingOptimized` policy, objects uploaded with a one-year immutable `Cache-Control`.
- Default behavior (HTML, `sw.js`, manifest, icons): managed `CachingDisabled` policy, objects uploaded with `no-cache`.
- The player service worker must not handle `/admin` navigations: see `navigateFallbackDenylist` in `creatura-app/apps/player/vite.config.ts`.

## Publishing the Web Apps

`scripts/deploy-frontend.ps1` (Windows PowerShell 5.1 compatible) builds both apps from a sibling `creatura-app` folder, stages them in `.deploy/site`, uploads them with explicit content types, and invalidates CloudFront. `-StageOnly` stops before any AWS call.

`scripts/deploy-frontend.sh` is the macOS / Linux twin (`--stage-only`, `--bucket`, `--distribution-id`, `--profile`). Keep both scripts in sync. Its `--mock` flag builds the apps with the in-browser simulated API, for when CloudFront has no `/api/*` route (variable `api_origin_domain_name` empty): a normal build served from the CDN then cannot reach a backend.

## One Command

`scripts/aws-up.sh` creates or completes the whole environment (bootstrap, ECR + CodeBuild images, `eks/` and `infra/` in parallel, schema Job, backend Secret and Deployment, `/api/*` route, health check through CloudFront); `scripts/aws-down.sh [--snapshot]` destroys it. Both are idempotent, bash 3.2 compatible, keep their logs in `.deploy/logs/`, and use `.deploy/kubeconfig-eks`, never the user's `~/.kube/config`. The workstation public IP is passed to `eks/` on each run (`endpoint_public_access_cidrs`). Keep them in sync with the manual steps in `eks/README.md`.

## Backend on Kubernetes

- `k8s/backend/` holds the Deployment and Service templates. On EKS they are rendered by `scripts/render-backend.py` (image pinned by GHCR digest) and applied by `deploy-backend.yml`; the cluster comes from the separate `eks/` stack (see `eks/README.md`).
- `eks/rds.tf` puts the PostgreSQL 16 RDS instance in the private subnets of the cluster VPC: no bastion, no tunnel, port 5432 open to the EKS nodes only. The backend authenticates with IAM through EKS Pod Identity (ServiceAccount `creatura-backend`, PostgreSQL user `creatura_back`). `k8s/db/schema-job.yaml` applies the schema and creates that user from inside the cluster. `infra/rds.tf` on branch `AS-49-rds` is the earlier version of the same database: never apply both.
- Local cluster: `scripts/k8s-local.sh up` creates a kind cluster named `creatura`, builds the images from the sibling `creatura-app`, and applies the `k8s/local` Kustomize overlay (backend + in-cluster PostgreSQL with demo data). The API answers on `http://localhost:30080/api/v1`. `down` deletes the cluster.
- Public API path: CloudFront `/api/*` → ALB of `eks/api.tf` (HTTP, security group open to CloudFront only) → NodePort 30080 of the `creatura-backend` Service → pods. The `/api/*` origin and behavior exist in `infra/cloudfront.tf` only when the `api_origin_domain_name` variable is set (output of `eks/`, also the `API_ORIGIN_DOMAIN_NAME` GitHub variable used by `terraform.yml`). Leaving it empty removes the route.
- Both stacks can be planned without credentials through `terraform test` and `mock_provider "aws"`; `terraform validate` alone misses AWS-side rules such as allowed characters in security group descriptions (ASCII, no apostrophe).
- The local overlay forces one replica: the trade room keeps its WebSocket connections in process memory. Verified on EKS through CloudFront (2026-11-12): with two replicas, a chat message reaches the other player in about half of the connections; with one replica, in all of them.
- `eks/ecr.tf` (`create_ecr_repositories`, off by default) creates ECR repositories for when GHCR cannot be used; `render-backend.py` accepts GHCR or the account ECR registry, always pinned by digest.
- Images are built in AWS, not with local Docker: `eks/codebuild.tf` (`create_image_builder`, needs the ECR repositories) + `eks/buildspec-images.yml`, driven by `scripts/build-images.sh` through the AWS CLI only (zip of git-tracked or non-ignored files to S3, `aws codebuild start-build`, digests printed at the end). It can be applied alone with `-target=aws_codebuild_project.images` so images build while the cluster is created. EKS nodes are x86_64.
- In zsh, `$name:a…` / `$name:l…` are history modifiers (`docker tag $i:amd64` breaks): write `${i}:amd64`. macOS has no `timeout` command.

## CI/CD

- `terraform.yml`: plan on pull requests, apply on `main`, for changes under `infra/`.
- `deploy-frontend.yml`: publishes a frontend artifact produced by the app repository CI. Not usable yet, because the app repository has no CI.

Both use the `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` secrets and the repository variables listed in `infra/README.md`.

## Sprite Image Utilities (`sprites.py`)

Not part of CI. Manual utility requiring `Pillow`:

```bash
python sprites.py sheet images/ sheet.png
python sprites.py resize images/ images-resized/ --size 128 --margin 4
python sprites.py cutout drawing-512.png images/new_creature.png   # opaque drawing -> 128x128 transparent sprite
```

`cutout` removes a plain background by flood fill from the image borders (enclosed light areas such as eyes stay) and shrinks by an integer factor (512 → 128) to keep pixels even. Sprite file names are lowercase snake case: the S3 key is case-sensitive and must match `image` in `creatura-app/db/init/02_catalogue.sql`.

## Outdated Documents

`summary.md` and `audit-report.md` describe the first design (region `eu-west-3`, GitHub OIDC, three IAM roles). They no longer match the code.

## CI/CD develop (current)

`checks.yml` validates pull requests without AWS credentials. `deploy-aws.yml` automatically deploys develop after checks and consumes the verified app CI release. Follow the root README for current secrets, prerequisites and state keys. The legacy separate deployment workflows have been removed; do not reintroduce parallel writers. No OIDC required. The eks stack does create IAM resources and therefore needs an authorized identity. App builds occur in creatura-app only; EKS pulls the existing GHCR images directly by digest using the dedicated ghcr-pull Secret; no ECR mirror or rebuild. Frontend archives are tied to the run/attempt and checked by SHA-256. Bootstrap remains a one-time manual prerequisite.
