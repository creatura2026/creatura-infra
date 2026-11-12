# Sprite S3 upload

This Terraform configuration creates a private, encrypted S3 bucket, uploads every `*.png` file in the sibling `images/` directory under `sprites/`, and provisions a CloudFront distribution in front of the bucket.

The bucket remains private. CloudFront uses Origin Access Control (OAC) and the generated bucket policy grants read access only to this distribution. Use the `cloudfront_domain_name` Terraform output as the public CDN hostname.

## Use

Run the one-time `../bootstrap` stack first. It creates the S3 state bucket required by this stack (no IAM role: the AWS organization does not allow it).

From this directory, authenticate to AWS using the AWS CLI or another supported credential source, then run:

```powershell
terraform init `
	-backend-config='bucket=your-terraform-state-bucket' `
	-backend-config='key=creatura-infra/terraform.tfstate' `
	-backend-config='region=eu-north-1' `
	-backend-config='encrypt=true' `
	-backend-config='use_lockfile=true'
terraform fmt -check
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
```

Use a unique bucket name when applying if you need a predictable name:

```powershell
terraform apply -var='bucket_name=my-unique-creatura-assets'
```

## GitHub Actions

The workflow at `.github/workflows/terraform.yml` runs format, init, validate, plan, and apply for infrastructure changes. Frontend releases use `.github/workflows/deploy-frontend.yml` and do not run Terraform plan or apply.

Configure these repository or environment variables before enabling the workflow:

- `APP_REPOSITORY`: app repository in `owner/repository` format
- `APP_PRODUCTION_BRANCH`: app branch allowed for production artifacts, normally `main`
- `APP_WORKFLOW_ID`: optional numeric app workflow ID used to verify the artifact source
- `AWS_REGION`: AWS deployment region, `eu-north-1` (the organization SCP denies `eu-west-1` and `eu-west-3`)
- `TF_STATE_BUCKET`: pre-existing private S3 bucket for Terraform state
- `TF_STATE_KEY`: state object key, for example `creatura-infra/terraform.tfstate`
- `TF_STATE_REGION`: region of the Terraform state bucket (`eu-north-1`)

Configure these repository secrets (IAM roles and GitHub OIDC cannot be created in this AWS organization):

- `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`: access keys of a dedicated IAM user with only the S3 and CloudFront permissions this stack needs. Both workflows use them, for plans and applies.

The app CI owns `npm ci` and `npm run build`. It must upload the generated `dist/` directory as a GitHub Actions artifact and add an `APP_REPO_TOKEN` secret to this repository with read-only access to the app repository's workflow artifacts.

After the app repository publishes a frontend change, it triggers `deploy-frontend.yml` with a `frontend-updated` repository dispatch. The payload must identify the completed app workflow run and artifact:

```bash
gh api repos/ORG/INFRA_REPOSITORY/dispatches \
	--method POST \
	-f event_type=frontend-updated \
	-f 'client_payload[run_id]=123456789' \
	-f 'client_payload[artifact_name]=frontend-abc123'
```

The state bucket must exist before the first workflow run. Configure the `production` environment with an approval rule so infrastructure changes are reviewed before apply. The IAM user behind the access keys should be restricted to this Terraform stack and the S3 bucket/CloudFront resources it manages; rotate its keys regularly.

The Terraform workflow provisions the S3 bucket and CloudFront distribution and uploads the PNG assets currently in this repository. The frontend deployment workflow publishes the frontend build into the same S3 origin without changing infrastructure.

The frontend deployment workflow also:

- Serializes production releases so concurrent deployments do not publish at the same time.
- Rejects an app workflow run older than the release marker already deployed.
- Verifies the public root URL returns HTML.
- Verifies a PNG selected from the repository's `images/` directory returns `image/png` with immutable caching.
- Verifies one JavaScript or CSS asset returns the expected content type and immutable cache header.
- Compares Terraform state checksums before and after the frontend-only deployment.
- Waits for the specific CloudFront invalidation created by the deployment.

CloudFront uses a dedicated zero-TTL cache policy for `index.html`. Frontend assets and sprites are uploaded with `public, max-age=31536000, immutable`; production builds should use hashed filenames for assets that can change.

Frontend assets are uploaded before the release marker and `index.html` is promoted last. The deployment does not delete old frontend assets, which prevents a failed release from breaking the currently served HTML; stale hashed assets can be removed later by a dedicated cleanup job.

To roll back, manually run `deploy-frontend.yml` with the run ID and artifact name of a previous successful app CI build and set `allow_rollback` to `true`. The protected `production` Environment still requires its normal approval; verify the public checks before declaring the rollback complete.

Client-side SPA routes are not rewritten by the current CloudFront configuration. Add a CloudFront Function only after confirming the frontend uses client-side routing; the function must leave `/sprites/`, `/assets/`, JavaScript, CSS, and other real asset requests untouched.

The bucket remains private. Access the objects through AWS credentials, a presigned URL, or add a deliberate distribution/access layer such as CloudFront rather than making the bucket public.