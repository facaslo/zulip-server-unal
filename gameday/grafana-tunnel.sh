#!/usr/bin/env bash
# Abre un túnel a Grafana en http://localhost:3000 (Ctrl+C para cerrarlo).
#
# Uso: ./grafana-tunnel.sh [puerto-local]
#
# Muestra el usuario y la contraseña de Grafana, leída de Secret Manager,
# solo si la salida es una terminal; así no queda en logs ni archivos.
set -euo pipefail

PROJECT="${GCP_PROJECT:-proyecto-zulip-unal}"
CLUSTER="${GKE_CLUSTER:-zulip}"
LOCATION="${GKE_LOCATION:-us-east1-b}"
GRAFANA_SECRET="${GRAFANA_SECRET:-zulip-grafana-admin-password}"
LOCAL_PORT="${1:-3000}"

command -v gcloud >/dev/null || PATH="$HOME/google-cloud-sdk/bin:$PATH"

gcloud container clusters get-credentials "$CLUSTER" \
    --location "$LOCATION" --project "$PROJECT" --quiet

context="gke_${PROJECT}_${LOCATION}_${CLUSTER}"

if ! kubectl --context "$context" --request-timeout=10s get --raw /healthz >/dev/null 2>&1; then
    echo "No se pudo conectar con el clúster. Si tu IP no está autorizada, ejecuta add-my-ip.sh." >&2
    exit 1
fi

trap 'exit 0' INT TERM

echo "Grafana: http://localhost:$LOCAL_PORT"
echo "Usuario: admin"
if [[ ! -t 1 ]]; then
    echo "Contraseña: no se muestra porque la salida no es una terminal."
elif password="$(gcloud secrets versions access latest \
    --secret "$GRAFANA_SECRET" --project "$PROJECT")"; then
    echo "Contraseña: $password"
else
    echo "No se pudo leer la contraseña del secreto $GRAFANA_SECRET; el túnel se abre igual." >&2
fi

# kubectl port-forward termina cuando se pierde la conexión con el Pod.
# Se reconecta, salvo que falle varias veces seguidas apenas arranca,
# como cuando el puerto local está ocupado.
quick_failures=0
while ((quick_failures < 5)); do
    started_at=$SECONDS
    kubectl --context "$context" -n monitoring port-forward \
        --address 127.0.0.1 svc/grafana "$LOCAL_PORT:3000" || true

    if ((SECONDS - started_at < 10)); then
        quick_failures=$((quick_failures + 1))
    else
        quick_failures=0
    fi
    echo "Túnel cerrado; reconectando..." >&2
    sleep 2
done

echo "El túnel falló $quick_failures veces seguidas; revisa el error de kubectl." >&2
exit 1
