#!/usr/bin/env bash
# Met l'environnement Creatura en pause sans rien détruire, pour payer moins entre deux séances :
#
#   scripts/aws-pause.sh     pause
#   scripts/aws-up.sh        reprise (relance nœuds, NAT et base, puis redéploie) : 5 à 10 min
#
# En pause :
#   - nœuds EKS ramenés à 0 (le back ne tourne plus : l'API répond 503, le front reste en ligne) ;
#   - NAT supprimé (Terraform, variable paused de eks/) ;
#   - base RDS arrêtée : données conservées, stockage seul facturé.
# Reste facturé : plan de contrôle EKS, ALB, stockage RDS, petits frais (clé KMS, secret,
# zone DNS) : environ 3 $ par jour, contre 7 en marche et presque rien après aws-down.sh.
#
# Limite AWS : une base arrêtée redémarre seule au bout de 7 jours. Au-delà d'une semaine de
# pause, relancer ce script, ou préférer scripts/aws-down.sh --snapshot.
#
# Options : --profile NOM.
set -euo pipefail
# Lu en entier avant exécution (bloc { … }) : modifier ce fichier pendant qu'il tourne ne
# casse pas l'exécution en cours (bash lit sinon un script au fur et à mesure).
{

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REGION="eu-north-1"
LOGS="$ROOT/.deploy/logs"
export AWS_PAGER=""

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) export AWS_PROFILE="${2:?}"; shift ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'Option inconnue : %s\n' "$1" >&2; exit 1 ;;
  esac
  shift
done

START=$(date +%s)
elapsed() { local s=$(( $(date +%s) - START )); printf '%02d:%02d' $((s / 60)) $((s % 60)); }
say() { printf '\n==> [%s] %s\n' "$(elapsed)" "$*"; }
die() { printf '\nErreur : %s\n' "$*" >&2; exit 1; }
tf() { terraform "-chdir=$ROOT/$1" "${@:2}"; }
tail_log() { printf -- '--- fin de %s\n' "$1" >&2; tail -25 "$1" >&2; }
mkdir -p "$LOGS"

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)" || die "identité AWS invalide."
STATE_BUCKET="creatura-tfstate-$ACCOUNT"
aws s3api head-bucket --bucket "$STATE_BUCKET" >/dev/null 2>&1 || die "aucun environnement à mettre en pause (bucket d'état absent)."
IP="$(curl -fsS -m 10 https://checkip.amazonaws.com | tr -d '[:space:]')"

tf eks init -input=false -reconfigure \
  -backend-config="bucket=$STATE_BUCKET" -backend-config="key=eks/terraform.tfstate" -backend-config="region=$REGION" \
  -backend-config="encrypt=true" -backend-config="use_lockfile=true" >"$LOGS/init-eks.log" 2>&1 \
  || { tail_log "$LOGS/init-eks.log"; die "init eks/"; }
CLUSTER="$(tf eks output -raw cluster_name 2>/dev/null)" || die "cluster absent de l'état : rien à mettre en pause."

# 1. Base : arrêt lancé tout de suite (quelques minutes), attendu à la fin.
DB="$(aws rds describe-db-instances --region "$REGION" \
  --query 'DBInstances[?starts_with(DBInstanceIdentifier, `creatura-db-`)].DBInstanceIdentifier | [0]' --output text)"
DB_STATUS="$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$DB" --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo absent)"
case "$DB_STATUS" in
  available)
    say "Arrêt de la base $DB (données conservées)"
    aws rds stop-db-instance --region "$REGION" --db-instance-identifier "$DB" >/dev/null ;;
  stopped|stopping) say "Base $DB déjà arrêtée" ;;
  *) say "Base $DB dans l'état « $DB_STATUS » : non arrêtée, relancer la pause plus tard" ;;
esac

# 2. Nœuds à 0. La taille souhaitée est ignorée par Terraform (module EKS) : réglée par la CLI.
NODEGROUP="$(aws eks list-nodegroups --region "$REGION" --cluster-name "$CLUSTER" --query 'nodegroups[0]' --output text)"
say "Nœuds du groupe $NODEGROUP ramenés à 0"
aws eks update-nodegroup-config --region "$REGION" --cluster-name "$CLUSTER" --nodegroup-name "$NODEGROUP" \
  --scaling-config minSize=0,maxSize=3,desiredSize=0 >/dev/null
aws eks wait nodegroup-active --region "$REGION" --cluster-name "$CLUSTER" --nodegroup-name "$NODEGROUP"

# 3. NAT supprimé ; minimum de nœuds à 0 dans Terraform, pour rester cohérent avec la CLI.
say "Suppression du NAT (Terraform, paused = true)"
tf eks apply -input=false -auto-approve \
  -var "endpoint_public_access_cidrs=[\"$IP/32\"]" -var "create_ecr_repositories=true" \
  -var "create_image_builder=true" -var "paused=true" >"$LOGS/pause.log" 2>&1 \
  || { tail_log "$LOGS/pause.log"; die "pause du réseau (journal ci-dessus)."; }

if [ "$DB_STATUS" = "available" ] || [ "$DB_STATUS" = "stopping" ]; then
  say "Attente de l'arrêt de la base"
  for _ in $(seq 1 60); do
    [ "$(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$DB" --query 'DBInstances[0].DBInstanceStatus' --output text)" = "stopped" ] && break
    sleep 15
  done
fi
restart="$(date -v+7d '+%d/%m à %H:%M' 2>/dev/null || date -d '+7 days' '+%d/%m à %H:%M')"

cat <<EOF

==> [$(elapsed)] Environnement en pause

  Nœuds EKS   0 (API indisponible, le front reste servi par CloudFront)
  NAT         supprimé
  Base        $(aws rds describe-db-instances --region "$REGION" --db-instance-identifier "$DB" --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo "?") (redémarrage automatique par AWS vers le $restart)
  Coût        environ 3 \$ par jour (plan de contrôle EKS, ALB, stockage)

  Reprendre : scripts/aws-up.sh        Tout détruire : scripts/aws-down.sh --snapshot
EOF
exit
}
