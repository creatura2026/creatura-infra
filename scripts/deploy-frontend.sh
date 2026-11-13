#!/usr/bin/env bash
# Construit les deux applications web Creatura et les publie dans le bucket S3 servi par
# CloudFront. Équivalent macOS / Linux de scripts/deploy-frontend.ps1 (mêmes règles).
#
#   /            PWA joueur        (apps/player, base /)
#   /admin/      dashboard admin   (apps/admin, construit avec la base /admin/)
#   /sprites/    géré par Terraform, jamais touché par ce script
#
# Les fichiers à nom haché (assets/, admin/assets/) partent en premier avec un cache d'un an.
# Le reste (index.html, service worker, manifeste, icônes) part en dernier en « no-cache ».
# Les anciens fichiers hachés ne sont pas supprimés : une publication ratée ne casse pas le site.
#
#   scripts/deploy-frontend.sh --stage-only     construit et vérifie, rien n'est envoyé à AWS
#   scripts/deploy-frontend.sh                  construit, envoie sur S3, invalide CloudFront
#
# Options :
#   --app-path DIR          dépôt creatura-app (par défaut : le dossier voisin)
#   --profile NOM           profil AWS CLI
#   --bucket NOM            bucket cible (par défaut : sortie Terraform bucket_name)
#   --distribution-id ID    distribution à invalider (par défaut : sortie cloudfront_distribution_id)
#   --mock                  API simulée dans le navigateur (VITE_API_MOCK=true) : à utiliser tant
#                           que /api/* n'est pas relié à un back sur CloudFront
#   --skip-build            réutilise le contenu déjà présent dans .deploy/site
#   --stage-only            s'arrête avant le premier appel AWS
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INFRA_DIR="$ROOT/infra"
STAGE_DIR="$ROOT/.deploy/site"
APP_PATH="$ROOT/../creatura-app"
BUCKET=""
DISTRIBUTION_ID=""
SKIP_BUILD="no"
STAGE_ONLY="no"
MOCK="no"

IMMUTABLE_CACHE="public, max-age=31536000, immutable"
REVALIDATE_CACHE="no-cache"

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'Erreur : %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --app-path) APP_PATH="${2:?}"; shift ;;
    --profile) export AWS_PROFILE="${2:?}"; shift ;;
    --bucket) BUCKET="${2:?}"; shift ;;
    --distribution-id) DISTRIBUTION_ID="${2:?}"; shift ;;
    --mock) MOCK="yes" ;;
    --skip-build) SKIP_BUILD="yes" ;;
    --stage-only) STAGE_ONLY="yes" ;;
    -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "option inconnue : $1" ;;
  esac
  shift
done

# Types explicites : celui que devine l'AWS CLI dépend du poste, et un module servi en
# text/plain est refusé par les navigateurs.
content_type() {
  case "$1" in
    html) echo "text/html; charset=utf-8" ;;
    js|mjs) echo "text/javascript; charset=utf-8" ;;
    css) echo "text/css; charset=utf-8" ;;
    json|map) echo "application/json" ;;
    webmanifest) echo "application/manifest+json" ;;
    txt) echo "text/plain; charset=utf-8" ;;
    xml) echo "application/xml" ;;
    svg) echo "image/svg+xml" ;;
    png) echo "image/png" ;;
    jpg|jpeg) echo "image/jpeg" ;;
    gif) echo "image/gif" ;;
    webp) echo "image/webp" ;;
    avif) echo "image/avif" ;;
    ico) echo "image/x-icon" ;;
    woff) echo "font/woff" ;;
    woff2) echo "font/woff2" ;;
    ttf) echo "font/ttf" ;;
    *) return 1 ;;
  esac
}

terraform_output() {
  terraform "-chdir=$INFRA_DIR" output -raw "$1" 2>/dev/null \
    || die "sortie Terraform « $1 » illisible. Appliquer la stack infra/, ou passer --bucket et --distribution-id."
}

# --- 1. Construire et rassembler -----------------------------------------------------

if [ "$SKIP_BUILD" = "no" ]; then
  [ -f "$APP_PATH/pnpm-workspace.yaml" ] || die "creatura-app introuvable dans $APP_PATH (option --app-path)."
  APP_PATH="$(cd "$APP_PATH" && pwd)"
  mode_args=()
  [ "$MOCK" = "yes" ] && mode_args=(--mode mock)

  rm -rf "$STAGE_DIR"
  mkdir -p "$STAGE_DIR"

  say "Installation des dépendances"
  (cd "$APP_PATH" && pnpm install --frozen-lockfile)

  say "Construction de la PWA joueur (base /)"
  (cd "$APP_PATH" && pnpm --filter player run build ${mode_args[@]+"${mode_args[@]}"})
  cp -R "$APP_PATH/apps/player/dist/." "$STAGE_DIR/"

  say "Construction du dashboard admin (base /admin/)"
  (cd "$APP_PATH" && pnpm --filter admin run type-check)
  (cd "$APP_PATH" && pnpm --filter admin exec vite build --base=/admin/ \
    --outDir "$STAGE_DIR/admin" --emptyOutDir ${mode_args[@]+"${mode_args[@]}"})
fi

for required in index.html admin/index.html; do
  [ -f "$STAGE_DIR/$required" ] || die "site incomplet : $required est absent de $STAGE_DIR."
done

# --- 2. Préparer l'envoi --------------------------------------------------------------

# Une ligne par fichier : rang (0 haché, 1 autre, 2 html), cache, extension, taille, clé.
plan_file="$(mktemp)"
trap 'rm -f "$plan_file"' EXIT

while IFS= read -r key; do
  case "$key" in
    .DS_Store|*/.DS_Store) continue ;;
    sprites/*|.creatura/*) die "« $key » écraserait un chemin qui n'appartient pas au front." ;;
  esac
  name="${key##*/}"
  case "$name" in
    *.*) extension="$(printf '%s' "${name##*.}" | tr '[:upper:]' '[:lower:]')" ;;
    *) extension="" ;;
  esac
  content_type "$extension" >/dev/null \
    || die "type de contenu inconnu pour « $key » : ajouter « $extension » à content_type() dans ce script."
  case "$key" in
    assets/*|admin/assets/*) rank=0; cache="immutable" ;;
    *) cache="no-cache"; if [ "$extension" = "html" ]; then rank=2; else rank=1; fi ;;
  esac
  bytes="$(wc -c < "$STAGE_DIR/$key" | tr -d ' ')"
  printf '%s\t%s\t%s\t%s\t%s\n' "$rank" "$cache" "$extension" "$bytes" "$key" >> "$plan_file"
done < <(cd "$STAGE_DIR" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)

groups="$(cut -f1-3 "$plan_file" | LC_ALL=C sort -u)"

echo
awk -F'\t' -v dir="$STAGE_DIR" '{ n++; total += $4 } END { printf "%d fichiers (%d Ko) dans %s\n", n, total / 1024, dir }' "$plan_file"
while IFS=$'\t' read -r rank cache extension; do
  count="$(awk -F'\t' -v r="$rank" -v e="$extension" '$1 == r && $3 == e' "$plan_file" | wc -l | tr -d ' ')"
  printf '  %-9s  .%-12s %3s fichier(s)  %s\n' "$cache" "$extension" "$count" "$(content_type "$extension")"
done <<< "$groups"
[ "$MOCK" = "yes" ] && echo "Mode simulé : ce build n'appelle aucun serveur."

if [ "$STAGE_ONLY" = "yes" ]; then
  printf '\n--stage-only : rien n a été envoyé à AWS.\n'
  exit 0
fi

# --- 3. Envoyer et invalider ----------------------------------------------------------

[ -n "$BUCKET" ] || BUCKET="$(terraform_output bucket_name)"
[ -n "$DISTRIBUTION_ID" ] || DISTRIBUTION_ID="$(terraform_output cloudfront_distribution_id)"

say "Envoi vers s3://$BUCKET"
while IFS=$'\t' read -r rank cache extension; do
  arguments=(s3 cp "$STAGE_DIR" "s3://$BUCKET" --recursive --only-show-errors --exclude "*")
  if [ "$cache" = "immutable" ]; then
    arguments+=(--include "assets/*.$extension" --include "admin/assets/*.$extension" --cache-control "$IMMUTABLE_CACHE")
  else
    arguments+=(--include "*.$extension" --exclude "assets/*" --exclude "admin/assets/*" --cache-control "$REVALIDATE_CACHE")
  fi
  arguments+=(--content-type "$(content_type "$extension")")
  aws "${arguments[@]}"
  echo "  envoyé : .$extension ($cache)"
done <<< "$groups"

say "Invalidation de la distribution CloudFront $DISTRIBUTION_ID"
aws cloudfront create-invalidation --distribution-id "$DISTRIBUTION_ID" --paths "/*" \
  --query "Invalidation.Id" --output text

domain="$(aws cloudfront get-distribution --id "$DISTRIBUTION_ID" --query "Distribution.DomainName" --output text)"
printf '\nTerminé. Joueur : https://%s/   Admin : https://%s/admin/\n' "$domain" "$domain"
