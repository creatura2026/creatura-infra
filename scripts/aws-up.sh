#!/usr/bin/env bash
# Crée tout l'environnement Creatura sur AWS en une commande, ou complète ce qui manque :
#
#   scripts/aws-up.sh
#
#   1. bucket d'état Terraform (bootstrap/)
#   2. dépôts ECR + projet CodeBuild, puis en parallèle :
#        images construites dans AWS (scripts/build-images.sh)
#        cluster EKS, base RDS, ALB (eks/)
#        CDN + publication du front (infra/, scripts/deploy-frontend.sh)
#   3. schéma de la base (Job k8s/db/schema-job.yaml), Secret et déploiement du back
#   4. route /api/* de CloudFront vers l'ALB, puis contrôle de santé de bout en bout
#
# Ré-exécutable : chaque étape ne crée que ce qui manque. Le Secret du back (clé JWT,
# mot de passe admin) est conservé d'une exécution à l'autre tant que le cluster existe.
# Durée : 20 à 25 minutes au premier lancement, surtout l'attente d'EKS et de RDS.
# Coût : environ 0,30 $ de l'heure tant que l'environnement existe, plus le pare-feu WAF
# (environ 10 $ par mois, au prorata). Tout détruire : scripts/aws-down.sh.
#
# Prérequis : identité AWS avec droits administrateur (variable AWS_PROFILE ou --profile),
# aws, terraform, kubectl, python3, git, zip, pnpm ; creatura-app à côté de ce dépôt ;
# eks/terraform.tfvars (voir eks/terraform.tfvars.example). L'IP publique du poste est
# relue à chaque lancement pour l'accès à l'API du cluster.
#
# Options : --profile NOM, --app-path DIR, --skip-images (réutilise les dernières images ECR),
#           --no-waf (pas de pare-feu WAF devant CloudFront ; il est actif et bloquant par défaut).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$ROOT/../creatura-app"
REGION="eu-north-1"
NAMESPACE="creatura"
SKIP_IMAGES="no"
WAF="yes"
WORK="$ROOT/.deploy"
LOGS="$WORK/logs"
export KUBECONFIG="$WORK/kubeconfig-eks"   # jamais le ~/.kube/config de l'utilisateur
export AWS_PAGER=""

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) export AWS_PROFILE="${2:?}"; shift ;;
    --app-path) APP_PATH="${2:?}"; shift ;;
    --skip-images) SKIP_IMAGES="yes" ;;
    --no-waf) WAF="no" ;;
    -h|--help) sed -n '2,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'Option inconnue : %s\n' "$1" >&2; exit 1 ;;
  esac
  shift
done

START=$(date +%s)
say() { printf '\n==> [%s] %s\n' "$(elapsed)" "$*"; }
elapsed() { local s=$(( $(date +%s) - START )); printf '%02d:%02d' $((s / 60)) $((s % 60)); }
die() { printf '\nErreur : %s\n' "$*" >&2; exit 1; }
tf() { terraform "-chdir=$ROOT/$1" "${@:2}"; }
tail_log() { printf -- '--- fin de %s\n' "$1" >&2; tail -25 "$1" >&2; }

for cmd in aws terraform kubectl python3 git zip pnpm curl; do
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd est introuvable."
done
[ -f "$ROOT/eks/terraform.tfvars" ] || die "eks/terraform.tfvars manquant : copier eks/terraform.tfvars.example et le remplir."
[ -d "$APP_PATH/backend" ] || die "creatura-app introuvable dans $APP_PATH (option --app-path)."
mkdir -p "$LOGS"

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)" || die "identité AWS invalide (profil, clés ou session SSO expirée)."
STATE_BUCKET="creatura-tfstate-$ACCOUNT"
IP="$(curl -fsS -m 10 https://checkip.amazonaws.com | tr -d '[:space:]')"
case "$IP" in *.*.*.*) ;; *) die "IP publique introuvable." ;; esac
# Variables imposées à eks/ en plus de terraform.tfvars.
EKS_VARS=(
  -var "endpoint_public_access_cidrs=[\"$IP/32\"]"
  -var "create_ecr_repositories=true"
  -var "create_image_builder=true"
)
say "Compte $ACCOUNT, région $REGION, accès au cluster depuis $IP"

# Pare-feu WAF devant CloudFront (infra/waf.tf), en mode bloquant sauf --no-waf.
WAF_VARS=(-var "waf_enabled=true" -var "waf_mode=block")
[ "$WAF" = "yes" ] || WAF_VARS=(-var "waf_enabled=false")

# Domaine personnalisé (stack permanente dns/, facultative) : utilisé dès que son certificat est validé.
DOMAIN_VARS=(-var "custom_domain=" -var "certificate_arn=" -var "route53_zone_id=")
DOMAIN=""
if [ -f "$ROOT/dns/terraform.tfstate" ]; then
  cert="$(tf dns output -raw certificate_arn 2>/dev/null || true)"
  status="$(aws acm describe-certificate --region us-east-1 --certificate-arn "$cert" --query Certificate.Status --output text 2>/dev/null || true)"
  if [ "$status" = "ISSUED" ]; then
    DOMAIN="$(tf dns output -raw domain_name)"
    DOMAIN_VARS=(-var "custom_domain=$DOMAIN" -var "certificate_arn=$cert" -var "route53_zone_id=$(tf dns output -raw zone_id)")
    say "Domaine $DOMAIN (certificat validé)"
  else
    say "Domaine de dns/ ignoré : certificat ${status:-introuvable} (délégation NS faite chez le registrar ?)"
  fi
fi

# --- 1. État Terraform -------------------------------------------------------------
say "Bucket d'état $STATE_BUCKET"
tf bootstrap init -input=false >"$LOGS/bootstrap.log" 2>&1 || { tail_log "$LOGS/bootstrap.log"; die "init bootstrap/"; }
tf bootstrap apply -input=false -auto-approve -var "aws_region=$REGION" -var "state_bucket_name=$STATE_BUCKET" \
  >>"$LOGS/bootstrap.log" 2>&1 || { tail_log "$LOGS/bootstrap.log"; die "bootstrap/"; }

for stack in eks infra; do
  key="eks/terraform.tfstate"; [ "$stack" = infra ] && key="creatura-infra/terraform.tfstate"
  tf "$stack" init -input=false -reconfigure \
    -backend-config="bucket=$STATE_BUCKET" -backend-config="key=$key" -backend-config="region=$REGION" \
    -backend-config="encrypt=true" -backend-config="use_lockfile=true" >"$LOGS/init-$stack.log" 2>&1 \
    || { tail_log "$LOGS/init-$stack.log"; die "init $stack/"; }
done

# --- 2. Images, cluster et CDN en parallèle -------------------------------------------
say "Dépôts ECR et projet CodeBuild"
tf eks apply -input=false -auto-approve "${EKS_VARS[@]}" -target=aws_codebuild_project.images \
  >"$LOGS/builder.log" 2>&1 || { tail_log "$LOGS/builder.log"; die "projet CodeBuild"; }

say "En parallèle : images (CodeBuild), cluster + base (eks/), CDN + front (infra/). Journaux : $LOGS"
pids=""
if [ "$SKIP_IMAGES" = "no" ]; then
  "$ROOT/scripts/build-images.sh" --app-path "$APP_PATH" --region "$REGION" >"$LOGS/images.log" 2>&1 &
  pid_images=$!; pids="$pids $pid_images"
fi
tf eks apply -input=false -auto-approve "${EKS_VARS[@]}" >"$LOGS/eks.log" 2>&1 &
pid_eks=$!
# La route /api/* est ajoutée à la fin (étape 4) ; ici le CDN garde celle qu'il a déjà.
API_ORIGIN_NOW="$(tf eks output -raw api_origin_domain_name 2>/dev/null || true)"
case "$API_ORIGIN_NOW" in *.elb.amazonaws.com) ;; *) API_ORIGIN_NOW="" ;; esac
{
  tf infra apply -input=false -auto-approve -var "aws_region=$REGION" -var "api_origin_domain_name=$API_ORIGIN_NOW" \
    "${DOMAIN_VARS[@]}" "${WAF_VARS[@]}" && "$ROOT/scripts/deploy-frontend.sh" --app-path "$APP_PATH"
} >"$LOGS/infra.log" 2>&1 &
pid_infra=$!

failed=""
if [ "$SKIP_IMAGES" = "no" ]; then wait "$pid_images" || failed="$failed images"; fi
wait "$pid_eks" || failed="$failed eks"
wait "$pid_infra" || failed="$failed infra"
for part in $failed; do tail_log "$LOGS/$part.log"; done
[ -z "$failed" ] || die "échec de :$failed (journaux ci-dessus et dans $LOGS)."
say "Images, cluster et CDN prêts"

# --- 3. Base et back -----------------------------------------------------------------
latest_digest() {
  aws ecr describe-images --region "$REGION" --repository-name "$1" \
    --query 'sort_by(imageDetails,&imagePushedAt)[-1].imageDigest' --output text
}
REGISTRY="$ACCOUNT.dkr.ecr.$REGION.amazonaws.com"
DB_IMAGE="$REGISTRY/creatura-db@$(latest_digest creatura-db)"
BACKEND_IMAGE="$REGISTRY/creatura-backend@$(latest_digest creatura-backend)"
case "$DB_IMAGE$BACKEND_IMAGE" in *None*) die "image absente d'ECR : relancer sans --skip-images." ;; esac

aws eks update-kubeconfig --region "$REGION" --name "$(tf eks output -raw cluster_name)" --alias creatura-eks >/dev/null
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE" >/dev/null

say "Schéma de la base (Job, image $DB_IMAGE)"
secret_arn="$(tf eks output -raw db_master_secret_arn)"
db_password="$(aws secretsmanager get-secret-value --region "$REGION" --secret-id "$secret_arn" --query SecretString --output text \
  | python3 -c 'import json, sys; print(json.load(sys.stdin)["password"])')"
kubectl -n "$NAMESPACE" delete secret creatura-db-admin --ignore-not-found >/dev/null
kubectl -n "$NAMESPACE" create secret generic creatura-db-admin \
  --from-literal=PGHOST="$(tf eks output -raw db_endpoint)" --from-literal=PGPORT=5432 \
  --from-literal=PGDATABASE="$(tf eks output -raw db_name)" --from-literal=PGUSER="$(tf eks output -raw db_master_username)" \
  --from-literal=PGSSLMODE=require --from-literal=PGPASSWORD="$db_password" >/dev/null
unset db_password
kubectl -n "$NAMESPACE" delete job creatura-db-schema --ignore-not-found >/dev/null
sed "s#image: ghcr.io/creatura2026/creatura-db:develop#image: $DB_IMAGE#" "$ROOT/k8s/db/schema-job.yaml" | kubectl apply -f - >/dev/null
if ! kubectl -n "$NAMESPACE" wait --for=condition=complete job/creatura-db-schema --timeout=300s >/dev/null; then
  kubectl -n "$NAMESPACE" logs job/creatura-db-schema --tail=30 >&2 || true
  kubectl -n "$NAMESPACE" delete secret creatura-db-admin --ignore-not-found >/dev/null
  die "le Job de schéma a échoué."
fi
kubectl -n "$NAMESPACE" logs job/creatura-db-schema | grep '\[creatura\]' | sed 's/^/  /'
kubectl -n "$NAMESPACE" delete secret creatura-db-admin >/dev/null   # le mot de passe principal ne reste pas dans le cluster

CDN_URL="$(tf infra output -raw site_url)"; CDN_URL="${CDN_URL%/}"   # domaine personnalisé s'il y en a un
if kubectl -n "$NAMESPACE" get secret creatura-backend >/dev/null 2>&1; then
  say "Secret du back existant conservé"
  # Le domaine CloudFront change à chaque re-création du CDN : on le remet à jour.
  kubectl -n "$NAMESPACE" patch secret creatura-backend --type merge -p \
    "{\"stringData\":{\"IMAGE_BASE_URL\":\"$CDN_URL\",\"CORS_ORIGINS\":\"$CDN_URL\",\"DATABASE_URL\":\"$(tf eks output -raw backend_database_url)\"}}" >/dev/null
else
  say "Secret du back (clé JWT et mot de passe admin générés)"
  kubectl -n "$NAMESPACE" create secret generic creatura-backend \
    --from-literal=DATABASE_URL="$(tf eks output -raw backend_database_url)" \
    --from-literal=DB_IAM_AUTH=true --from-literal=AWS_REGION="$REGION" \
    --from-literal=JWT_SECRET="$(python3 -c 'import secrets; print(secrets.token_urlsafe(48))')" \
    --from-literal=TIMEZONE=Europe/Paris \
    --from-literal=IMAGE_BASE_URL="$CDN_URL" --from-literal=CORS_ORIGINS="$CDN_URL" \
    --from-literal=ADMIN_LOGIN=admin \
    --from-literal=ADMIN_PASSWORD="$(python3 -c 'import secrets; print(secrets.token_urlsafe(18))')" >/dev/null
fi

say "Déploiement du back ($BACKEND_IMAGE)"
PY=python3
if ! python3 -c 'import yaml' 2>/dev/null; then
  [ -x "$WORK/venv/bin/python" ] || { python3 -m venv "$WORK/venv" && "$WORK/venv/bin/pip" -q --disable-pip-version-check install PyYAML==6.0.2; }
  PY="$WORK/venv/bin/python"
fi
"$PY" "$ROOT/scripts/render-backend.py" --image "$BACKEND_IMAGE" > "$WORK/backend-eks.yaml"
kubectl apply -f "$WORK/backend-eks.yaml" >/dev/null
# Même image qu'avant mais Secret modifié : redémarrer pour relire la configuration.
kubectl -n "$NAMESPACE" rollout restart deployment/creatura-backend >/dev/null
kubectl -n "$NAMESPACE" rollout status deployment/creatura-backend --timeout=300s \
  || { kubectl -n "$NAMESPACE" get pods >&2; kubectl -n "$NAMESPACE" logs deployment/creatura-backend --tail=30 >&2 || true; die "le back ne démarre pas."; }

# --- 4. Route /api/* ----------------------------------------------------------------------
say "Attente des cibles de l'ALB"
tg="$(aws elbv2 describe-target-groups --region "$REGION" --load-balancer-arn \
  "$(aws elbv2 describe-load-balancers --region "$REGION" --names "$(tf eks output -raw cluster_name)-api" --query 'LoadBalancers[0].LoadBalancerArn' --output text)" \
  --query 'TargetGroups[0].TargetGroupArn' --output text)"
for _ in $(seq 1 40); do
  healthy="$(aws elbv2 describe-target-health --region "$REGION" --target-group-arn "$tg" \
    --query 'length(TargetHealthDescriptions[?TargetHealth.State==`healthy`])' --output text)"
  [ "$healthy" -ge 1 ] && break
  sleep 10
done
[ "$healthy" -ge 1 ] || die "aucune cible saine derrière l'ALB."

API_ORIGIN="$(tf eks output -raw api_origin_domain_name)"
say "Route /api/* vers $API_ORIGIN"
tf infra apply -input=false -auto-approve -var "aws_region=$REGION" -var "api_origin_domain_name=$API_ORIGIN" \
  "${DOMAIN_VARS[@]}" "${WAF_VARS[@]}" >"$LOGS/api-route.log" 2>&1 || { tail_log "$LOGS/api-route.log"; die "route /api/*"; }

say "Contrôle de bout en bout via CloudFront"
# Par le nom CloudFront : toujours résolu, contrairement à un domaine personnalisé tout juste créé
# (le cache DNS du poste peut garder un « nom inconnu » quelques minutes).
CF_URL="https://$(tf infra output -raw cloudfront_domain_name)"
health=""
for _ in $(seq 1 30); do
  health="$(curl -fsS -m 10 "$CF_URL/api/v1/health" 2>/dev/null || true)"
  case "$health" in *'"database":"ok"'*) break ;; esac
  sleep 10
done
case "$health" in *'"database":"ok"'*) ;; *) die "l'API ne répond pas via CloudFront ($CF_URL/api/v1/health)." ;; esac
front="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$CF_URL/")"
if [ -n "$DOMAIN" ] && ! curl -fsS -m 10 -o /dev/null "$CDN_URL/api/v1/health" 2>/dev/null; then
  printf '\n  Attention : %s ne répond pas encore depuis ce poste (cache DNS). En attendant : %s\n' "$CDN_URL" "$CF_URL"
fi

cat <<EOF

==> [$(elapsed)] Environnement prêt

  Joueur      $CDN_URL/   (front : HTTP $front)
  Admin       $CDN_URL/admin/   identifiant admin
  API         $CDN_URL/api/v1   $health
  kubectl     KUBECONFIG=$KUBECONFIG kubectl -n $NAMESPACE get pods
  Mot de passe admin :
    KUBECONFIG=$KUBECONFIG kubectl -n $NAMESPACE get secret creatura-backend -o jsonpath='{.data.ADMIN_PASSWORD}' | base64 -d

  Coût : environ 0,30 \$ de l'heure (+ WAF). Tout détruire : scripts/aws-down.sh
EOF
