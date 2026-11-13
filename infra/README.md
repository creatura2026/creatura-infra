# Creatura web hosting (S3 + CloudFront)

This stack creates:

- a private, encrypted, versioned S3 bucket (`creatura-assets-<suffix>`);
- the PNG files of `../images/`, uploaded under `sprites/`;
- a CloudFront distribution in front of the bucket, using Origin Access Control;
- a CloudFront Function that serves the right `index.html` for client-side routes.

The bucket is never public. Users only reach it through the CloudFront hostname.

## Site layout

| URL | Content | Published by |
| --- | --- | --- |
| `/` | player PWA (`creatura-app/apps/player`) | `scripts/deploy-frontend.ps1` |
| `/admin/` | admin dashboard (`creatura-app/apps/admin`, built with `--base=/admin/`) | `scripts/deploy-frontend.ps1` |
| `/sprites/*.png` | creature sprites of this repository | Terraform |

Both apps share one domain so that they share cookies. `/api/*` goes to the backend on EKS once the `api_origin_domain_name` variable is set (see below); until then CloudFront has no API route.

## API route (`/api/*`)

The backend load balancer is created by the `eks/` stack. Pass its DNS name to this stack to add the route:

```powershell
terraform apply -var="api_origin_domain_name=<output api_origin_domain_name of eks/>"
```

The route is never cached, accepts every HTTP method and WebSocket upgrades, and is not rewritten by the SPA function. Viewers must use HTTPS; CloudFront reaches the load balancer over HTTP because no certificate exists for its name. The `api_url` output is the public API address. The load balancer name changes each time `eks/` is re-created: apply again with the new value, and apply without the variable before destroying `eks/`.

Caching: `assets/*`, `admin/assets/*` and `sprites/*` are cached for a long time (hashed or immutable files). Everything else (`index.html`, `sw.js`, `manifest.webmanifest`, icons) is never cached at the edge.

## Region

Use `eu-north-1`. The organization SCP `p-0vevikxq` explicitly denies `eu-west-1` and `eu-west-3`. CloudFront itself is a global service; only the bucket lives in `eu-north-1`.

## Required AWS permissions

The identity that runs Terraform and the deploy script needs:

- S3: create and configure buckets, read and write objects;
- CloudFront: distributions, origin access controls, functions and invalidations (the managed policy `CloudFrontFullAccess` covers it).

No IAM permission is needed: this stack creates no role, user or policy.

## Deploy the infrastructure

Run the one-time `../bootstrap` stack first (it creates the Terraform state bucket), then:

```powershell
cd infra
terraform init `
  -backend-config="bucket=<state bucket name>" `
  -backend-config="key=creatura-infra/terraform.tfstate" `
  -backend-config="region=eu-north-1" `
  -backend-config="encrypt=true" `
  -backend-config="use_lockfile=true"
terraform plan -out=tfplan
terraform apply tfplan
```

Creating the distribution takes a few minutes. The `site_url` output is the public address.

## Publish the web apps

From the repository root, with `creatura-app` cloned next to this repository:

```powershell
.\scripts\deploy-frontend.ps1 -StageOnly   # build and check locally, nothing is sent to AWS
.\scripts\deploy-frontend.ps1              # build, upload to S3, invalidate CloudFront
```

On macOS / Linux, use the equivalent `./scripts/deploy-frontend.sh --stage-only` and `./scripts/deploy-frontend.sh`.

The script reads the bucket name and the distribution ID from the Terraform outputs. Old hashed assets are kept in the bucket, so a failed release does not break the live site.

## Delete everything

```powershell
terraform -chdir=infra destroy       # from the repository root; takes several minutes on CloudFront
terraform -chdir=bootstrap destroy   # always last: this bucket holds the state of infra/
```

The application bucket has `force_destroy` enabled: the destroy empties it, old object versions included. A bucket created before that setting existed needs one `terraform apply` first. The CloudFront hostname and the bucket name change on the next creation.

## GitHub Actions

La CI/CD automatique depuis `develop` est décrite dans le [README principal](../README.md). Le workflow unifié `deploy-aws.yml` remplace les anciens workflows indépendants de Terraform, frontend et backend. Il utilise les builds testés du dépôt app, sans rebuild, et reçoit l'origine API directement de l'état EKS.
