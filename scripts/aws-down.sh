#!/usr/bin/env bash
# Détruit tout l'environnement Creatura créé par scripts/aws-up.sh, en une commande :
#
#   scripts/aws-down.sh               tout, base comprise (données perdues)
#   scripts/aws-down.sh --snapshot    snapshot manuel de la base avant destruction
#
# Ordre : snapshot éventuel, puis CDN (infra/) et cluster (eks/) en parallèle, puis le
# bucket d'état (bootstrap/) en dernier. Un snapshot manuel survit à la destruction et
# coûte quelques centimes par mois ; le supprimer avec aws rds delete-db-snapshot.
# Durée : 15 à 20 minutes (CloudFront et EKS).
#
# Options : --profile NOM, --snapshot, --yes (pas de confirmation).
set -euo pipefail
# Lu en entier avant exécution (bloc { … }) : modifier ce fichier pendant qu'il tourne ne
# casse pas l'exécution en cours (bash lit sinon un script au fur et à mesure).
{

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REGION="eu-north-1"
SNAPSHOT="no"
CONFIRM="yes"
LOGS="$ROOT/.deploy/logs"
export AWS_PAGER=""

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) export AWS_PROFILE="${2:?}"; shift ;;
    --snapshot) SNAPSHOT="yes" ;;
    --yes) CONFIRM="no" ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

# Avancement des étapes en arrière-plan (sinon rien ne s'affiche pendant de longues minutes) :
# toutes les 30 s, ressources terminées et ressource en cours, lues dans chaque journal.
progress() {
  local pids="$1"; shift
  local alive pid log done_n current
  while :; do
    alive=""
    for pid in $pids; do kill -0 "$pid" 2>/dev/null && alive="yes"; done
    [ -n "$alive" ] || return 0
    sleep 30
    for log in "$@"; do
      [ -f "$log" ] || continue
      done_n="$(grep -cE '(Creation|Destruction|Modifications) complete' "$log" || true)"
      current="$(grep -E 'Still (creating|destroying|modifying)' "$log" | tail -1 \
        | sed -E 's/\x1b\[[0-9;]*m//g; s/: Still/ :/; s/\[id=[^]]*\], //; s/ elapsed\]/]/' || true)"  # rien en cours : pas d'erreur
      printf '    [%s] %-14s %3s terminées  %s\n' "$(elapsed)" "$(basename "$log" .log)" "$done_n" "$current"
    done
  done
}
mkdir -p "$LOGS"

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)" || die "identité AWS invalide."
STATE_BUCKET="${TF_STATE_BUCKET:-creatura-tfstate-$ACCOUNT}"
aws s3api head-bucket --bucket "$STATE_BUCKET" >/dev/null 2>&1 || die "bucket d'état $STATE_BUCKET absent : rien à détruire."

if [ "$CONFIRM" = "yes" ]; then
  printf 'Détruire tout Creatura dans le compte %s (base %s) ? Taper « oui » : ' "$ACCOUNT" \
    "$([ "$SNAPSHOT" = yes ] && echo 'sauvegardée par snapshot' || echo 'PERDUE')"
  read -r answer
  [ "$answer" = "oui" ] || die "annulé."
fi

for stack in eks infra; do
  key="eks/terraform.tfstate"; [ "$stack" = infra ] && key="creatura-infra/terraform.tfstate"
  tf "$stack" init -input=false -reconfigure \
    -backend-config="bucket=$STATE_BUCKET" -backend-config="key=$key" -backend-config="region=$REGION" \
    -backend-config="encrypt=true" -backend-config="use_lockfile=true" >"$LOGS/init-$stack.log" 2>&1 \
    || { tail_log "$LOGS/init-$stack.log"; die "init $stack/"; }
done

if [ "$SNAPSHOT" = "yes" ]; then
  db="$(tf eks state show -no-color aws_db_instance.creatura 2>/dev/null | awk -F'"' '/^ *identifier *=/ {print $2}')"
  if [ -n "$db" ]; then
    snap="creatura-db-$(date +%Y-%m-%d-%H%M)"
    say "Snapshot $snap de la base $db"
    aws rds create-db-snapshot --region "$REGION" --db-instance-identifier "$db" --db-snapshot-identifier "$snap" \
      --tags Key=Project,Value=Creatura >/dev/null
    aws rds wait db-snapshot-available --region "$REGION" --db-snapshot-identifier "$snap"
  else
    say "Pas de base dans l'état : aucun snapshot"
  fi
fi

# Les variables obligatoires de eks/ viennent de terraform.tfvars ; l'IP n'a pas d'effet sur une destruction.
say "Destruction en parallèle : CDN (infra/) et cluster + base + images (eks/). Journaux : $LOGS"
tf infra destroy -input=false -auto-approve -var "aws_region=$REGION" >"$LOGS/destroy-infra.log" 2>&1 &
pid_infra=$!
tf eks destroy -input=false -auto-approve -var "create_ecr_repositories=true" -var "create_image_builder=true" \
  >"$LOGS/destroy-eks.log" 2>&1 &
pid_eks=$!
progress "$pid_infra $pid_eks" "$LOGS/destroy-infra.log" "$LOGS/destroy-eks.log"
failed=""
wait "$pid_infra" || failed="$failed destroy-infra"
wait "$pid_eks" || failed="$failed destroy-eks"
for part in $failed; do tail_log "$LOGS/$part.log"; done
[ -z "$failed" ] || die "échec de :$failed ; relancer scripts/aws-down.sh (le bucket d'état est conservé)."

say "Protection de l'état DNS permanent"
aws s3api list-objects-v2 --bucket "$STATE_BUCKET" --prefix "${TF_DNS_STATE_KEY:-dns/terraform.tfstate}" --output json > "$LOGS/dns-state-objects.json"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$LOGS/dns-state-objects.json"
if python3 -c 'import json,os,sys; key=os.environ.get("TF_DNS_STATE_KEY","dns/terraform.tfstate"); sys.exit(0 if any(o["Key"] == key for o in json.load(open(sys.argv[1])).get("Contents",[])) else 1)' "$LOGS/dns-state-objects.json"; then
  say "Bucket bootstrap conservé : il contient l'état DNS permanent."
else
  say "Bucket d'état (aucun état DNS permanent)"
  tf bootstrap destroy -input=false -auto-approve -var "aws_region=$REGION" -var "state_bucket_name=$STATE_BUCKET" \
    >"$LOGS/destroy-bootstrap.log" 2>&1 || { tail_log "$LOGS/destroy-bootstrap.log"; die "bootstrap/"; }
fi
rm -f "$ROOT/.deploy/kubeconfig-eks"

say "Stacks applicatives détruites ; DNS conservé s’il était configuré"
aws rds describe-db-snapshots --region "$REGION" --snapshot-type manual \
  --query 'DBSnapshots[?starts_with(DBSnapshotIdentifier, `creatura-db-`)].[DBSnapshotIdentifier,SnapshotCreateTime]' --output text \
  | sed 's/^/  snapshot conservé : /'
exit
}
