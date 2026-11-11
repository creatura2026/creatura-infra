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

- `/` player PWA, `/admin/` admin dashboard (built with `--base=/admin/`), `/sprites/*` images, `/api/*` reserved for the backend.
- Both apps use history-mode routing. `infra/functions/spa-rewrite.js` rewrites any URL without a file extension to `/index.html` or `/admin/index.html`. It is attached to the default cache behavior only.
- `assets/*`, `admin/assets/*`, `sprites/*`: managed `CachingOptimized` policy, objects uploaded with a one-year immutable `Cache-Control`.
- Default behavior (HTML, `sw.js`, manifest, icons): managed `CachingDisabled` policy, objects uploaded with `no-cache`.
- The player service worker must not handle `/admin` navigations: see `navigateFallbackDenylist` in `creatura-app/apps/player/vite.config.ts`.

## Publishing the Web Apps

`scripts/deploy-frontend.ps1` (Windows PowerShell 5.1 compatible) builds both apps from a sibling `creatura-app` folder, stages them in `.deploy/site`, uploads them with explicit content types, and invalidates CloudFront. `-StageOnly` stops before any AWS call.

## CI/CD

- `terraform.yml`: plan on pull requests, apply on `main`, for changes under `infra/`.
- `deploy-frontend.yml`: publishes a frontend artifact produced by the app repository CI. Not usable yet, because the app repository has no CI.

Both use the `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` secrets and the repository variables listed in `infra/README.md`.

## Sprite Image Utilities (`sprites.py`)

Not part of CI. Manual utility requiring `Pillow`:

```bash
python sprites.py sheet images/ sheet.png
python sprites.py resize images/ images-resized/ --size 128 --margin 4
```

## Outdated Documents

`summary.md` and `audit-report.md` describe the first design (region `eu-west-3`, GitHub OIDC, three IAM roles). They no longer match the code.
