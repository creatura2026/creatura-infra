#!/usr/bin/env bash
# Affiche le dernier snapshot manuel disponible de la base Creatura (creatura-db-*), ou rien
# s'il n'y en a aucun :
#
#   scripts/latest-db-snapshot.sh REGION
#
# Sert à la création de la base, par scripts/aws-up.sh et par la CI (scripts/ci/provision.sh),
# pour la restaurer plutôt que de repartir d'une base vide. Les snapshots finaux pris par
# Terraform à la destruction (creatura-db-final-*) sont des snapshots manuels : ils comptent.
# Échoue si la liste ne peut pas être lue : créer une base vide par erreur ferait perdre
# tous les comptes des joueurs.
set -euo pipefail

region="${1:?Usage : scripts/latest-db-snapshot.sh REGION}"
snapshot="$(aws rds describe-db-snapshots --region "$region" --snapshot-type manual \
  --query 'sort_by(DBSnapshots[?starts_with(DBSnapshotIdentifier, `creatura-db-`) && Status==`available`], &SnapshotCreateTime)[-1].DBSnapshotIdentifier' \
  --output text)"
[ -z "$snapshot" ] || [ "$snapshot" = "None" ] || printf '%s\n' "$snapshot"
