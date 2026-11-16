#!/usr/bin/env bash
# Détruit tout l'environnement Creatura créé par scripts/aws-up.sh, en une commande :
#
#   scripts/aws-down.sh
#
# La base est toujours sauvegardée : snapshot final pris par Terraform à sa destruction
# (eks/rds.tf), ou snapshot manuel avant destruction si l'état a été appliqué avant ce
# réglage. aws-up.sh (et la CI) restaurent le dernier snapshot à la recréation : les comptes
# des joueurs sont conservés. Un snapshot survit à la destruction et coûte quelques centimes
# par mois ; supprimer les anciens avec aws rds delete-db-snapshot.
# Ordre : snapshot éventuel, puis CDN (infra/) et cluster (eks/) en parallèle, puis le
# bucket d'état (bootstrap/) en dernier. Durée : 15 à 20 minutes (CloudFront et EKS).
#
# Options : --profile NOM, --yes (pas de confirmation). --snapshot est accepté pour
# compatibilité : le snapshot est désormais systématique.
set -euo pipefail
# Lu en entier avant exécution (bloc { … }) : modifier ce fichier pendant qu'il tourne ne
# casse pas l'exécution en cours (bash lit sinon un script au fur et à mesure).
{

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REGION="eu-north-1"
CONFIRM="yes"
LOGS="$ROOT/.deploy/logs"
export AWS_PAGER=""

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) export AWS_PROFILE="${2:?}"; shift ;;
    --snapshot) ;;   # ancien nom de l'option : le snapshot est toujours pris
    --yes) CONFIRM="no" ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

for stack in eks infra; do
  key="eks/terraform.tfstate"; [ "$stack" = infra ] && key="creatura-infra/terraform.tfstate"
  tf "$stack" init -input=false -reconfigure \
    -backend-config="bucket=$STATE_BUCKET" -backend-config="key=$key" -backend-config="region=$REGION" \
    -backend-config="encrypt=true" -backend-config="use_lockfile=true" >"$LOGS/init-$stack.log" 2>&1 \
    || { tail_log "$LOGS/init-$stack.log"; die "init $stack/"; }
done

# Sauvegarde de la base, lue dans l'état eks/ : snapshot final de Terraform si l'état le prévoit
# (eks/rds.tf), sinon snapshot manuel (état appliqué avant ce réglage).
DB_STATE="$(tf eks state show -no-color aws_db_instance.creatura 2>/dev/null || true)"
DB="$(printf '%s\n' "$DB_STATE" | awk -F'"' '/^ *identifier *=/ {print $2}')"
FINAL_SNAPSHOT="$(printf '%s\n' "$DB_STATE" | awk -F'"' '/^ *final_snapshot_identifier *=/ {print $2}')"
SKIP_FINAL="$(printf '%s\n' "$DB_STATE" | awk '/^ *skip_final_snapshot *=/ {print $3}')"
MANUAL_SNAPSHOT=""
if [ -z "$DB" ]; then
  DB_FATE="absente de l'état : rien à sauvegarder"
elif [ "$SKIP_FINAL" = "false" ] && [ -n "$FINAL_SNAPSHOT" ]; then
  # Un snapshot du même nom ferait échouer la suppression de la base au milieu de la destruction.
  if aws rds describe-db-snapshots --region "$REGION" --db-snapshot-identifier "$FINAL_SNAPSHOT" >/dev/null 2>&1; then
    die "le snapshot $FINAL_SNAPSHOT existe déjà : la base a été remplacée depuis la création de l'environnement. Le renommer (aws rds copy-db-snapshot puis delete-db-snapshot) avant de relancer."
  fi
  DB_FATE="sauvegardée par le snapshot final $FINAL_SNAPSHOT"
else
  MANUAL_SNAPSHOT="creatura-db-$(date +%Y-%m-%d-%H%M)"
  DB_FATE="sauvegardée par le snapshot $MANUAL_SNAPSHOT"
fi

if [ "$CONFIRM" = "yes" ]; then
  printf 'Détruire tout Creatura dans le compte %s (base %s) ? Taper « oui » : ' "$ACCOUNT" "$DB_FATE"
  read -r answer
  [ "$answer" = "oui" ] || die "annulé."
fi

if [ -n "$MANUAL_SNAPSHOT" ]; then
  say "Snapshot $MANUAL_SNAPSHOT de la base $DB"
  aws rds create-db-snapshot --region "$REGION" --db-instance-identifier "$DB" --db-snapshot-identifier "$MANUAL_SNAPSHOT" \
    --tags Key=Project,Value=Creatura >/dev/null
  aws rds wait db-snapshot-available --region "$REGION" --db-snapshot-identifier "$MANUAL_SNAPSHOT"
else
  say "Base $DB_FATE"
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

if [ -n "$DB" ] && [ -z "$MANUAL_SNAPSHOT" ]; then
  aws rds wait db-snapshot-available --region "$REGION" --db-snapshot-identifier "$FINAL_SNAPSHOT" \
    || die "snapshot final $FINAL_SNAPSHOT introuvable : vérifier dans la console RDS avant de relancer aws-up.sh (sinon base vide)."
  say "Snapshot final $FINAL_SNAPSHOT disponible : aws-up.sh le restaurera"
fi

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
