#!/usr/bin/env bash
# Lance le back Creatura sur un cluster Kubernetes local (kind), avec les mêmes manifests
# que sur EKS (k8s/backend) et des réglages locaux (k8s/local).
#
#   scripts/k8s-local.sh up            back + PostgreSQL dans le cluster (données de démo)
#   scripts/k8s-local.sh status        pods, services et santé de l'API
#   scripts/k8s-local.sh logs          suit les logs du back
#   scripts/k8s-local.sh down          supprime le cluster kind (ou le namespace)
#
# L'API répond sur http://localhost:30080/api/v1 (Swagger : /docs). Pour le front :
#   API_PROXY_TARGET=http://localhost:30080 pnpm dev:player
#
# Prérequis : Docker lancé, kubectl, kind (brew install kind).
# Variables : APP_PATH (dépôt creatura-app, par défaut le dossier voisin),
#             KUBE_CONTEXT (par défaut kind-creatura ; docker-desktop pour le Kubernetes
#             de Docker Desktop, sans kind).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${APP_PATH:-$ROOT/../creatura-app}"
CLUSTER="creatura"
CONTEXT="${KUBE_CONTEXT:-kind-$CLUSTER}"
NAMESPACE="creatura"
API_URL="http://localhost:30080"

# Toujours un contexte explicite : jamais d'apply sur un autre cluster (EKS) par erreur.
k() { kubectl --context "$CONTEXT" "$@"; }
say() { printf '\n==> %s\n' "$*"; }
die() { printf 'Erreur : %s\n' "$*" >&2; exit 1; }
uses_kind() { [ "$CONTEXT" = "kind-$CLUSTER" ]; }

case "$CONTEXT" in
  kind-*|docker-desktop|minikube|rancher-desktop|orbstack) ;;
  *) die "KUBE_CONTEXT=$CONTEXT ne ressemble pas à un cluster local." ;;
esac

require() {
  command -v "$1" >/dev/null 2>&1 || die "$1 est introuvable. $2"
}

diagnose() {
  echo
  echo "--- Pods"
  k -n "$NAMESPACE" get pods -o wide || true
  echo "--- Derniers événements"
  k -n "$NAMESPACE" get events --sort-by=.lastTimestamp 2>/dev/null | tail -15 || true
  echo "--- Logs du back"
  k -n "$NAMESPACE" logs deployment/creatura-backend --tail=30 2>/dev/null || true
}

up() {
  local build="yes"
  while [ $# -gt 0 ]; do
    case "$1" in
      --skip-build) build="no" ;;
      *) die "option inconnue : $1" ;;
    esac
    shift
  done

  require docker "Lancer Docker Desktop."
  require kubectl "brew install kubectl"
  docker info >/dev/null 2>&1 || die "Docker ne répond pas : lancer Docker Desktop."
  [ -f "$APP_PATH/backend/Dockerfile" ] || die "creatura-app introuvable dans $APP_PATH (variable APP_PATH)."

  if uses_kind; then
    require kind "brew install kind"
    if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
      say "Création du cluster kind « $CLUSTER »"
      kind create cluster --config "$ROOT/k8s/local/kind-cluster.yaml" --wait 120s
    fi
  fi
  k cluster-info >/dev/null 2>&1 || die "le cluster du contexte $CONTEXT ne répond pas."

  if [ "$build" = "yes" ]; then
    say "Construction de l'image du back"
    docker build -t creatura-backend:local "$APP_PATH/backend"
    say "Construction de l'image de la base"
    docker build -t creatura-db:local "$APP_PATH/db"
  fi
  if uses_kind; then
    say "Chargement des images dans le cluster"
    kind load docker-image creatura-backend:local creatura-db:local --name "$CLUSTER"
  fi

  local existed
  existed="$(k -n "$NAMESPACE" get deployment creatura-backend -o name 2>/dev/null || true)"

  say "Déploiement (base : PostgreSQL dans le cluster)"
  k apply -k "$ROOT/k8s/local"
  k -n "$NAMESPACE" rollout status statefulset/creatura-db --timeout=180s || { diagnose; exit 1; }

  # Même tag d'image d'une fois sur l'autre : il faut recréer les pods pour prendre la nouvelle.
  if [ -n "$existed" ]; then
    k -n "$NAMESPACE" rollout restart deployment/creatura-backend >/dev/null
  fi
  say "Attente du back"
  k -n "$NAMESPACE" rollout status deployment/creatura-backend --timeout=240s || { diagnose; exit 1; }

  status
  cat <<EOF

API      : $API_URL/api/v1   (Swagger : $API_URL/docs)
Front    : cd $APP_PATH && API_PROXY_TARGET=$API_URL pnpm dev:player
Arrêter  : scripts/k8s-local.sh down
EOF
}

status() {
  k -n "$NAMESPACE" get pods,services
  printf '\nSanté de l API : '
  curl -fsS -m 5 "$API_URL/api/v1/health" || echo "pas de réponse sur $API_URL"
  echo
}

down() {
  if uses_kind; then
    kind delete cluster --name "$CLUSTER"
  else
    k delete namespace "$NAMESPACE" --ignore-not-found
  fi
}

command="${1:-}"
[ $# -gt 0 ] && shift
case "$command" in
  up) up "$@" ;;
  status) status ;;
  logs) k -n "$NAMESPACE" logs deployment/creatura-backend -f --tail=100 ;;
  down) down ;;
  *) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
