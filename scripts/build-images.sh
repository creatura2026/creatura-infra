#!/usr/bin/env bash
# Construit les images creatura-backend et creatura-db dans AWS (CodeBuild, Linux x86_64)
# et les pousse dans ECR, sans Docker sur le poste : seulement la CLI AWS.
#
#   scripts/build-images.sh                 les deux images, étiquette tirée du commit
#   scripts/build-images.sh --only backend  une seule image (backend ou db)
#   scripts/build-images.sh --stage-only    prépare les archives, rien n'est envoyé à AWS
#
# Options : --app-path DIR (défaut : ../creatura-app), --tag TAG, --profile NOM,
#           --region REGION (défaut eu-north-1), --project NOM, --bucket NOM.
# Prérequis : stack eks/ appliquée avec create_ecr_repositories = true et
# create_image_builder = true (le projet et le bucket sont lus dans ses sorties).
#
# Contenu envoyé : fichiers suivis par git ou non ignorés, modifications non commitées
# comprises. .env, .env.rds, .venv et caches (ignorés par git) ne partent jamais.
# Affiche à la fin l'image épinglée par digest, à passer à scripts/render-backend.py.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$ROOT/../creatura-app"
REGION="eu-north-1"
TAG=""
ONLY=""
STAGE_ONLY="no"
PROJECT=""
BUCKET=""
STAGE_DIR="$ROOT/.deploy/images"

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'Erreur : %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --app-path) APP_PATH="${2:?}"; shift ;;
    --tag) TAG="${2:?}"; shift ;;
    --only) ONLY="${2:?}"; shift ;;
    --profile) export AWS_PROFILE="${2:?}"; shift ;;
    --region) REGION="${2:?}"; shift ;;
    --project) PROJECT="${2:?}"; shift ;;
    --bucket) BUCKET="${2:?}"; shift ;;
    --stage-only) STAGE_ONLY="yes" ;;
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "option inconnue : $1" ;;
  esac
  shift
done
export AWS_PAGER=""

case "$ONLY" in
  "") IMAGES="creatura-backend creatura-db" ;;
  backend|creatura-backend) IMAGES="creatura-backend" ;;
  db|creatura-db) IMAGES="creatura-db" ;;
  *) die "--only attend backend ou db." ;;
esac

source_dir() { # nom d'image -> dossier de creatura-app
  case "$1" in
    creatura-backend) echo "$APP_PATH/backend" ;;
    creatura-db) echo "$APP_PATH/db" ;;
  esac
}

command -v git >/dev/null || die "git est introuvable."
command -v zip >/dev/null || die "zip est introuvable."
git -C "$APP_PATH" rev-parse --git-dir >/dev/null 2>&1 || die "creatura-app introuvable dans $APP_PATH (option --app-path)."

# Étiquette par défaut : commit de creatura-app, suffixée si l'arbre contient des modifications.
if [ -z "$TAG" ]; then
  TAG="$(git -C "$APP_PATH" rev-parse --short=12 HEAD)"
  if [ -n "$(git -C "$APP_PATH" status --porcelain -- backend db)" ]; then
    TAG="$TAG-local-$(date +%Y%m%d%H%M%S)"
  fi
fi
case "$TAG" in
  *[!A-Za-z0-9._-]*|"") die "étiquette invalide : $TAG" ;;
esac

# --- Archives source -----------------------------------------------------------
rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
for image in $IMAGES; do
  dir="$(source_dir "$image")"
  [ -f "$dir/Dockerfile" ] || die "pas de Dockerfile dans $dir."
  list="$STAGE_DIR/$image.files"
  # Fichiers suivis ou nouveaux non ignorés, encore présents sur le disque.
  git -C "$dir" ls-files --cached --others --exclude-standard \
    | while IFS= read -r f; do [ -f "$dir/$f" ] && printf '%s\n' "$f"; done \
    | sort -u > "$list"
  # Garde-fou : aucun fichier d'environnement ni de clé ne doit partir.
  if grep -E '(^|/)\.env($|\.)|\.pem$|(^|/)id_rsa' "$list" | grep -v '\.env\.example$' >/dev/null; then
    die "fichier sensible dans l'archive de $image : $(grep -E '(^|/)\.env($|\.)|\.pem$' "$list" | grep -v '\.env\.example$' | tr '\n' ' ')"
  fi
  (cd "$dir" && zip -q -X "$STAGE_DIR/$image.zip" -@ < "$list")
  printf '  %-17s %4s fichiers  %s\n' "$image" "$(wc -l < "$list" | tr -d ' ')" "$(du -h "$STAGE_DIR/$image.zip" | cut -f1)"
done

if [ "$STAGE_ONLY" = "yes" ]; then
  say "--stage-only : archives dans $STAGE_DIR, rien n'a été envoyé à AWS (étiquette $TAG)."
  exit 0
fi

# --- Envoi et lancement des builds -----------------------------------------------
command -v aws >/dev/null || die "la CLI AWS est introuvable."
terraform_output() {
  terraform "-chdir=$ROOT/eks" output -raw "$1" 2>/dev/null || true
}
[ -n "$PROJECT" ] || PROJECT="$(terraform_output image_builder_project)"
[ -n "$BUCKET" ] || BUCKET="$(terraform_output image_source_bucket)"
[ -n "$PROJECT" ] && [ -n "$BUCKET" ] \
  || die "projet CodeBuild inconnu : appliquer eks/ avec create_image_builder = true, ou passer --project et --bucket."

BUILDS=""
for image in $IMAGES; do
  key="sources/$image-$TAG.zip"
  aws s3 cp --region "$REGION" --only-show-errors "$STAGE_DIR/$image.zip" "s3://$BUCKET/$key"
  id="$(aws codebuild start-build --region "$REGION" --project-name "$PROJECT" \
    --source-location-override "$BUCKET/$key" \
    --environment-variables-override \
      "name=IMAGE,value=$image,type=PLAINTEXT" \
      "name=TAG,value=$TAG,type=PLAINTEXT" \
    --query build.id --output text)"
  printf '  %-17s build %s\n' "$image" "$id"
  BUILDS="$BUILDS $id"
done

say "Construction dans CodeBuild (étiquette $TAG)"
while :; do
  statuses="$(aws codebuild batch-get-builds --region "$REGION" --ids $BUILDS \
    --query 'builds[].[environment.environmentVariables[?name==`IMAGE`]|[-1].value,buildStatus,currentPhase]' --output text)"
  printf '%s\n' "$statuses" | sed 's/^/  /'
  printf '%s\n' "$statuses" | grep -q 'IN_PROGRESS' || break
  sleep 15
done

failed="no"
for id in $BUILDS; do
  read -r image status group stream <<EOF
$(aws codebuild batch-get-builds --region "$REGION" --ids "$id" \
    --query 'builds[0].[environment.environmentVariables[?name==`IMAGE`]|[-1].value,buildStatus,logs.groupName,logs.streamName]' --output text)
EOF
  if [ "$status" != "SUCCEEDED" ]; then
    failed="yes"
    printf '\n--- %s : %s, fin du journal\n' "$image" "$status" >&2
    aws logs get-log-events --region "$REGION" --log-group-name "$group" --log-stream-name "$stream" \
      --limit 40 --query 'events[].message' --output text 2>/dev/null | tr '\t' '\n' >&2 || true
  fi
done
[ "$failed" = "no" ] || die "au moins un build a échoué (journal ci-dessus)."

say "Images dans ECR"
for image in $IMAGES; do
  uri="$(aws ecr describe-repositories --region "$REGION" --repository-names "$image" --query 'repositories[0].repositoryUri' --output text)"
  digest="$(aws ecr describe-images --region "$REGION" --repository-name "$image" --image-ids "imageTag=$TAG" --query 'imageDetails[0].imageDigest' --output text)"
  printf '  %s@%s\n' "$uri" "$digest"
done
