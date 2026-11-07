#!/usr/bin/env bash
# Agrega la IP pública actual a la lista de redes autorizadas del clúster.
#
# Uso: ./add-my-ip.sh [--dry-run]
#
# La lista se reemplaza completa al actualizarla, así que primero se
# leen las entradas actuales para conservarlas. El cambio es temporal:
# el siguiente terraform apply restablece la lista del secreto
# AUTHORIZED_NETWORKS.
set -euo pipefail

PROJECT="${GCP_PROJECT:-proyecto-zulip-unal}"
CLUSTER="${GKE_CLUSTER:-zulip}"
LOCATION="${GKE_LOCATION:-us-east1-b}"

DRY_RUN=false
case "${1:-}" in
    "") ;;
    --dry-run) DRY_RUN=true ;;
    *)
        echo "Uso: $0 [--dry-run]" >&2
        exit 2
        ;;
esac

command -v gcloud >/dev/null || PATH="$HOME/google-cloud-sdk/bin:$PATH"

my_ip="$(curl -4 -fsS -m 10 https://api.ipify.org)"
if [[ ! "$my_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "No se pudo obtener una IPv4 pública válida: '$my_ip'" >&2
    exit 1
fi
my_cidr="$my_ip/32"

current="$(gcloud container clusters describe "$CLUSTER" \
    --location "$LOCATION" --project "$PROJECT" \
    --format='value(masterAuthorizedNetworksConfig.cidrBlocks[].cidrBlock.list())')"

# Una lectura vacía sobrescribiría las entradas de todo el equipo.
if [[ -z "$current" ]]; then
    echo "No se pudo leer la lista actual de redes autorizadas; no se cambió nada." >&2
    exit 1
fi

echo "IP actual:         $my_cidr"
echo "Lista autorizada:  $current"

if [[ ",$current," == *",$my_cidr,"* ]]; then
    echo "La IP ya está autorizada; no hay nada que cambiar."
    exit 0
fi

new_list="$current,$my_cidr"
if [[ "$DRY_RUN" == true ]]; then
    echo "Simulación; la lista quedaría así: $new_list"
    exit 0
fi

gcloud container clusters update "$CLUSTER" \
    --location "$LOCATION" --project "$PROJECT" \
    --enable-master-authorized-networks \
    --master-authorized-networks "$new_list" \
    --quiet

echo "Listo. Lista autorizada: $new_list"
