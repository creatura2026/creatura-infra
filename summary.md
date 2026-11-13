# Creatura Infrastructure Summary

## Project Purpose

This project contains the infrastructure and deployment foundation for Creatura, a frontend application that uses creature images and is delivered through an AWS CDN.

The infrastructure repository is:

```text
creatura2026/creatura-infra
```

The target AWS region is Paris:

```text
 eu-west-3
```

The project is designed for two repositories:

- The application repository owns the frontend source code and frontend build.
- The infrastructure repository owns Terraform, AWS resources, deployment policies, and the infrastructure GitHub Actions workflow.

## Architecture

```text
Application repository
  -> App CI builds the TypeScript frontend
  -> App CI uploads the dist/ directory as a GitHub Actions artifact
  -> App CI triggers the frontend deployment workflow

Infrastructure repository
  -> Terraform workflow manages AWS infrastructure
  -> Frontend deployment workflow downloads and verifies the app artifact
  -> Frontend deployment workflow uploads frontend files to private S3
  -> Frontend deployment workflow invalidates CloudFront

CloudFront
  -> Reads private S3 through Origin Access Control
  -> Serves the frontend and images to users
```

## Repository Structure

```text
creatura-infra/
├── bootstrap/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── versions.tf
│   ├── terraform.tfvars.example
│   ├── .gitignore
│   └── README.md
├── infra/
│   ├── main.tf
│   ├── cloudfront.tf
│   ├── policies.tf
│   ├── backend.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── versions.tf
│   ├── .gitignore
│   └── README.md
├── images/
│   └── *.png
├── .github/
│   └── workflows/
│       ├── terraform.yml
│       └── deploy-frontend.yml
├── sprites.py
└── summary.md
```

## Bootstrap Stack

The `bootstrap/` stack is executed once by an administrator before the normal CI workflow can run.

It creates:

- A private, encrypted, versioned S3 bucket for Terraform state.
- The GitHub Actions OIDC identity provider.
- An IAM role trusted by the `terraform-plan` and `production` GitHub Environments in `creatura2026/creatura-infra`.
- A separate read-only Terraform plan role for the `terraform-plan` Environment.
- A separate frontend deployment role trusted only by the `production` Environment.
- Permissions for the infrastructure workflow to manage the application S3 bucket and CloudFront.

Example bootstrap configuration:

```text
AWS region:        eu-west-3
GitHub owner:      creatura2026
GitHub repository: creatura-infra
Plan environment:  terraform-plan
Production env:    production
State bucket:      creatura-infra-tfstate-prod
```

The bootstrap state is intentionally kept local because it creates the remote state bucket used by the main infrastructure stack.

Run it once with an administrator-authenticated AWS session:

```powershell
cd bootstrap
Copy-Item terraform.tfvars.example terraform.tfvars
terraform init
terraform fmt -check
terraform validate
terraform plan -out=bootstrap.tfplan
terraform apply bootstrap.tfplan
```

The bootstrap outputs provide values for GitHub Actions variables:

```text
aws_role_arn       -> AWS_ROLE_ARN
state_bucket_name  -> TF_STATE_BUCKET
state_bucket_region -> TF_STATE_REGION
```

Use this state key for the main infrastructure stack:

```text
creatura-infra/terraform.tfstate
```

## Main Infrastructure

The `infra/` stack creates the application delivery platform.

### S3

The application bucket uses the project naming convention:

```text
creatura-assets-<generated-suffix>
```

The bucket is:

- Private.
- Encrypted with server-side AES256 encryption.
- Versioned.
- Protected by S3 public access blocks.
- Configured with bucket-owner-enforced object ownership.

The PNG files in `images/` are uploaded under the `sprites/` prefix.

Example image URL path through CloudFront:

```text
/sprites/amber_scorpion.png
```

### CloudFront

CloudFront is provisioned in front of the private S3 bucket.

The configuration includes:

- Origin Access Control using Signature Version 4.
- HTTPS redirection.
- IPv6 support.
- Compression.
- Zero-TTL cache policy for `index.html`.
- Managed long-lived caching policy for `assets/*` and `sprites/*`.
- Default CloudFront certificate.
- Read-only S3 access through a distribution-specific bucket policy.

The S3 bucket is not public. Users access files through the CloudFront hostname.

## CI/CD Workflow

The workflow is located at:

```text
.github/workflows/terraform.yml
```

The infrastructure workflow does not build the frontend. The application CI owns the frontend build. Frontend deployment is handled by a separate workflow so releases do not run Terraform apply.

### Pull Request

For infrastructure pull requests, the workflow runs:

```text
terraform fmt -check
terraform init
terraform validate
terraform plan
```

No production apply occurs for pull requests.

### Infrastructure Push

A push to `main` runs the Terraform plan and apply flow.

### Frontend Deployment

The app CI builds and uploads the frontend artifact. It then triggers `deploy-frontend.yml` with a `repository_dispatch` event named `frontend-updated`.

The event payload must identify the artifact produced by app CI:

```text
run_id
artifact_name
```

The frontend deployment workflow performs these steps:

```text
1. Download the frontend artifact from the app repository.
2. Verify that dist/index.html exists and the artifact is not empty.
3. Read the existing S3 bucket and CloudFront distribution outputs from Terraform state.
4. Upload the frontend build to S3.
5. Invalidate the CloudFront cache.
```

If the artifact is missing or invalid, the workflow stops before publishing anything.

The S3 sync excludes the `sprites/` prefix so publishing the frontend does not delete the image assets managed by Terraform.

Frontend deployment uses a production concurrency group, validates the source app workflow and artifact, rejects app runs older than the deployed release marker, verifies the public root, a PNG sprite, and a JavaScript/CSS asset, waits for CloudFront invalidation, and compares Terraform state checksums before and after publishing. Assets are uploaded before the release marker and `index.html` is promoted last. The root HTML uses a zero-TTL CloudFront policy and no-cache headers; hashed assets and sprites use one-year immutable cache headers.

## GitHub Configuration

Configure these repository or environment variables:

```text
AWS_REGION=eu-west-3
AWS_ROLE_ARN=<bootstrap output>
AWS_PLAN_ROLE_ARN=<bootstrap output>
AWS_FRONTEND_ROLE_ARN=<bootstrap output>
TF_STATE_BUCKET=<bootstrap output>
TF_STATE_REGION=eu-west-3
TF_STATE_KEY=creatura-infra/terraform.tfstate
APP_REPOSITORY=<owner>/<app-repository>
APP_PRODUCTION_BRANCH=main
APP_WORKFLOW_ID=<optional app workflow ID>
```

For a private app repository, configure this GitHub Actions secret:

```text
APP_REPO_TOKEN=<token with access to app workflow artifacts>
```

Protect the `production` GitHub Environment with required reviewers before enabling production apply.

No long-lived AWS access key should be stored in GitHub. The workflow uses GitHub OIDC to assume the AWS IAM role created by the bootstrap stack. Configure the `production` GitHub Environment to allow only the `main` branch and require reviewers; configure `terraform-plan` for pull requests. The IAM trust policy restricts access to these two environment subjects.

The frontend deployment role has no Terraform state write permissions. To roll back, dispatch the frontend deployment workflow with the run ID and artifact name of a previous successful app CI build, then repeat the public verification checks.

Client-side SPA routes are not rewritten by the current CloudFront configuration. Add a CloudFront Function only after confirming the frontend uses client-side routing; it must leave `/sprites/`, `/assets/`, JavaScript, CSS, and other real asset requests untouched.

## Asset and Container Registries

The current project uses:

- S3 for frontend files and PNG image assets.
- CloudFront for global frontend and image delivery.
- GitHub Actions artifacts for transferring the frontend build from app CI to infrastructure CI.

GHCR is not required for this frontend and image workflow. It would only be needed later if the application includes a containerized backend whose Docker image must be stored and deployed.

## Outputs

The main infrastructure stack exposes:

```text
bucket_name
bucket_arn
uploaded_object_keys
cloudfront_distribution_id
cloudfront_domain_name
```

The CloudFront hostname is the public CDN endpoint for the application:

```text
https://<cloudfront-domain-name>/
```

## Important Operational Notes

- Run `bootstrap/` before the first infrastructure CI run.
- The state bucket must exist before `infra/terraform init` can succeed.
- The S3 application bucket remains private.
- CloudFront is the public access layer.
- Frontend builds are produced by app CI, not infrastructure CI.
- Frontend artifact download occurs before frontend publishing.
- `sprites.py` remains an optional manual asset-preparation utility; it is not part of CI.
- Use immutable or hashed frontend asset names when possible.
- Keep Terraform state, plans, credentials, and real `.tfvars` files out of Git.
- Terraform CLI and AWS credentials are required to execute the stacks; editor diagnostics alone do not deploy AWS resources.
