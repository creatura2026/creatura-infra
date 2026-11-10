# Creatura Infrastructure Audit Report

Date: 2026-11-10

Scope: current Terraform bootstrap, infrastructure stack, GitHub Actions workflows, and project documentation.

## Findings

| File | Problem | Severity | Evidence | Correction | Validation |
| --- | --- | --- | --- | --- | --- |
| `bootstrap/main.tf` | OIDC trust and workflow environments must match. | High | Workflows use `terraform-plan` and `production` environments. | Separate trust policies use exact environment subjects. | Editor diagnostics passed. Real STS validation requires GitHub/AWS. |
| `bootstrap/main.tf` | Terraform plan, apply, and frontend deployment need different privileges. | High | A single broad role would expose production changes to pull requests or frontend releases. | Separate plan, apply, and frontend deployment roles. | Policy reviewed; real plan/apply tests still required. |
| `bootstrap/main.tf` | Terraform S3 and CloudFront lifecycle permissions must include refresh, update, replacement, and destroy actions. | High | Provider resources manage S3 configuration, CloudFront distribution, OAC, and cache policy. | Explicit bucket, object, distribution, OAC, cache-policy, state, and lock permissions; no `s3:*` or `cloudfront:*`. | Editor diagnostics passed; AWS IAM simulation or real plan/apply/destroy required. |
| `bootstrap/main.tf` | Frontend deployment must not modify Terraform state. | High | Frontend deployment only needs existing Terraform outputs. | Frontend role has state-object read access only and no state or lock writes. | Policy reviewed; deploy test required. |
| `bootstrap/main.tf` | State and application buckets must not be casually destroyed. | Medium | State and deployed assets are critical data. | `prevent_destroy = true` on both buckets; state bucket is encrypted, versioned, private, and HTTPS-only. | Editor diagnostics passed; confirm with Terraform plan. |
| `infra/cloudfront.tf` | Managed caching for all requests could cache `index.html` too aggressively. | High | Root URL resolves through the default behavior. | Default behavior uses zero-TTL HTML policy; `assets/*` and `sprites/*` use managed long-lived caching. | Public smoke test after deployment required. |
| `infra/main.tf` | Sprite cache metadata was not explicit. | Medium | Sprite objects are immutable only when filenames are versioned. | PNG objects use `public, max-age=31536000, immutable`. | Terraform plan and response-header smoke test required. |
| `.github/workflows/terraform.yml` | Infrastructure and frontend deployment were coupled. | Medium | Frontend releases do not need Terraform apply. | Workflow is Terraform-only with plan role for PRs and apply role for production. | Editor diagnostics passed; GitHub run required. |
| `.github/workflows/deploy-frontend.yml` | Artifact source could be unverified. | High | A dispatch payload can contain an incorrect run or artifact name. | Verify run success, source repository, production branch, optional workflow ID, artifact existence, and non-expired status. | GitHub run required with a real app artifact. |
| `.github/workflows/deploy-frontend.yml` | Concurrent or stale releases could overwrite a newer release. | High | Frontend releases are independent of Terraform. | Production concurrency group, release marker, stale-run rejection, explicit rollback override, and index promotion last. | Two-run concurrency test recommended. |
| `.github/workflows/deploy-frontend.yml` | CDN invalidation completion and public delivery were not verified. | Medium | Invalidation is asynchronous. | Wait for the created invalidation, then verify HTML, a repository-derived PNG, and JS/CSS headers. | Public AWS deployment required. |
| `summary.md`, `bootstrap/README.md`, `infra/README.md` | Documentation could drift from the separate workflow and role model. | Low | Architecture evolved during review. | Documentation now describes bootstrap order, three roles, variables, caching, rollback, and SPA limitations. | Editor diagnostics passed; manual review completed. |

## Implementation Checklist

1. Run the bootstrap stack with an administrator AWS session.
2. Configure GitHub OIDC environments and protection rules.
3. Set `AWS_ROLE_ARN`, `AWS_PLAN_ROLE_ARN`, and `AWS_FRONTEND_ROLE_ARN` from bootstrap outputs.
4. Set the remote-state variables consistently, especially `TF_STATE_KEY`.
5. Run infrastructure `fmt`, `init`, `validate`, `plan`, and `apply`.
6. Configure app CI to upload a successful frontend artifact.
7. Configure `APP_REPOSITORY`, `APP_PRODUCTION_BRANCH`, and optionally `APP_WORKFLOW_ID`.
8. Configure `APP_REPO_TOKEN` for cross-repository artifact access.
9. Trigger `deploy-frontend.yml` with the app run ID and artifact name.
10. Verify the public CDN checks and retain the release marker for rollback decisions.

## Validation Report

| Command/check | Result | Exit/status | Notes |
| --- | --- | --- | --- |
| `bootstrap/terraform fmt -check -recursive` | Not executed | Blocked | Terraform executable is not installed. |
| `bootstrap/terraform init -input=false` | Not executed | Blocked | Terraform executable is not installed. |
| `bootstrap/terraform validate` | Not executed | Blocked | Terraform executable is not installed. |
| `infra/terraform fmt -check -recursive` | Not executed | Blocked | Terraform executable is not installed. |
| `infra/terraform init -input=false -backend=false` | Not executed | Blocked | Terraform executable is not installed. |
| `infra/terraform validate` | Not executed | Blocked | Terraform executable is not installed. |
| `actionlint .github/workflows/terraform.yml .github/workflows/deploy-frontend.yml` | Not executed | Blocked | `actionlint` executable is not installed. |
| AWS `terraform plan` for bootstrap and infra | Not executed | Blocked | Terraform, AWS credentials, provider initialization, and network access are unavailable. |
| Editor diagnostics | Passed | 0 | No errors reported for changed Terraform, workflow, and Markdown files. |
| Repository static checks | Passed | 0 | 94 PNGs found; required workflows and references are present. |
| Git diff check | Not executed | 129 | Workspace copy has no Git metadata, so `git diff --check` cannot run. |

### Passed

- Editor diagnostics for current bootstrap Terraform files.
- Editor diagnostics for current infrastructure Terraform files.
- Editor diagnostics for both GitHub Actions workflows.
- Editor diagnostics for project documentation.
- Static search confirms no old `creature-sprites` naming remains in implementation files.
- Static search confirms the frontend workflow no longer runs Terraform plan or apply.
- CloudFront cache paths align with `assets/*`, `sprites/*`, and the default HTML behavior.
- The release marker is written only after invalidation, public checks, and state-integrity checks.
- Frontend deployment has no Terraform state-object write or lock permissions.

### Not Run

- `terraform fmt -check -recursive` because Terraform is unavailable.
- `terraform init` because Terraform is unavailable.
- `terraform validate` because Terraform is unavailable.
- `terraform plan` because Terraform and AWS access are unavailable.
- AWS IAM policy simulation.
- GitHub OIDC authentication.
- CloudFront public URL checks.
- Cross-repository artifact download.
- Concurrent deployment test.

Terraform and `actionlint` are not installed in the current environment. No AWS credentials, GitHub permissions, provider initialization, or real deployment evidence is available here. The command attempts from the outer workspace failed with path-not-found errors; rerunning from the actual repository root confirmed the tools themselves are missing.

## Remaining Decisions

- Add a CloudFront Function only if the frontend uses client-side SPA routes. It must rewrite application routes without rewriting missing images, JavaScript, CSS, or other real assets.
- Keep `production` restricted to `main` with required reviewers.
- Keep bootstrap state encrypted and backed up securely outside Git.
- Use hashed frontend asset names so one-year immutable caching is safe.

## Final Assessment

The architecture meets the stated Creatura objectives after bootstrap and GitHub configuration:

- Private encrypted S3 storage.
- HTTPS frontend and sprite delivery through CloudFront.
- OAC-protected S3 origin.
- Terraform remote state with S3 lockfile support.
- OIDC authentication without long-lived AWS keys.
- Separate least-privilege plan, apply, and frontend deployment roles.
- Independent frontend releases.
- Artifact verification, serialized deployment, cache checks, and rollback support.

It is architecturally deployable, but it is not proven deployable until the bootstrap and real AWS/GitHub validation steps above have completed successfully.
