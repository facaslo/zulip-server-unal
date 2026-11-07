#!/usr/bin/env bash
# Deja el entorno listo para una corrida del GameDay.
#
# Uso: ./gameday-reset.sh
#
# Quita los toxics de Toxiproxy, asegura una réplica de RabbitMQ, espera
# a que Zulip responda e imprime enlaces a los dashboards desde este
# momento. No borra métricas ni logs: los paneles de 30 días siguen
# incluyendo las corridas anteriores.
#
# Ojo: si hay una falla inyectada a propósito, este script la revierte.
set -euo pipefail

PROJECT="${GCP_PROJECT:-proyecto-zulip-unal}"
CLUSTER="${GKE_CLUSTER:-zulip}"
LOCATION="${GKE_LOCATION:-us-east1-b}"
NAMESPACE="${ZULIP_NAMESPACE:-zulip}"
ZULIP_URL="${ZULIP_URL:-https://136.108.58.125}"
GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"
TOXIPROXY_PORT="${TOXIPROXY_LOCAL_PORT:-18474}"

command -v gcloud >/dev/null || PATH="$HOME/google-cloud-sdk/bin:$PATH"

gcloud container clusters get-credentials "$CLUSTER" \
    --location "$LOCATION" --project "$PROJECT" --quiet 2>/dev/null

context="gke_${PROJECT}_${LOCATION}_${CLUSTER}"
k() { kubectl --context "$context" -n "$NAMESPACE" "$@"; }

if ! kubectl --context "$context" --request-timeout=10s get --raw /healthz >/dev/null 2>&1; then
    echo "No se pudo conectar con el clúster. Si tu IP no está autorizada, ejecuta add-my-ip.sh." >&2
    exit 1
fi

reset_toxiproxy() {
    if ! k get svc toxiproxy >/dev/null 2>&1; then
        echo "Toxiproxy: no está desplegado; no hay nada que quitar."
        return
    fi

    kubectl --context "$context" -n "$NAMESPACE" port-forward \
        svc/toxiproxy "$TOXIPROXY_PORT:8474" >/dev/null 2>&1 &
    local port_forward=$!
    # shellcheck disable=SC2064
    trap "kill $port_forward 2>/dev/null || true" RETURN

    local attempt
    for attempt in $(seq 1 15); do
        if curl -fsS -m 2 -o /dev/null "http://127.0.0.1:$TOXIPROXY_PORT/version" 2>/dev/null; then
            break
        fi
        sleep 1
    done

    # /reset quita todos los toxics y vuelve a habilitar los proxies.
    curl -fsS -m 10 -o /dev/null -X POST "http://127.0.0.1:$TOXIPROXY_PORT/reset"
    echo "Toxiproxy: toxics quitados y proxies habilitados."
}

reset_toxiproxy

k scale deploy rabbitmq --replicas=1 >/dev/null
k rollout status deploy/rabbitmq --timeout=180s >/dev/null
echo "RabbitMQ: listo."

k rollout status deploy/zulip --timeout=300s >/dev/null
for attempt in $(seq 1 60); do
    code="$(curl -k -s -m 5 -o /dev/null -w '%{http_code}' "$ZULIP_URL/login/" || true)"
    [[ "$code" == "200" ]] && break
    if [[ "$attempt" == 60 ]]; then
        echo "Zulip no respondió 200 en $ZULIP_URL/login/ (último código: $code)." >&2
        exit 1
    fi
    sleep 5
done
echo "Zulip: responde en $ZULIP_URL/login/."

start_ms="$(($(date +%s) * 1000))"
echo
echo "Corrida iniciada a las $(date -u +%H:%M:%SZ). Dashboards desde este momento:"
echo "  $GRAFANA_URL/d/zulip-slo?from=$start_ms&to=now"
echo "  $GRAFANA_URL/d/zulip-saturation?from=$start_ms&to=now"
echo "En el SLO, usa la fila 'Rango seleccionado': los paneles de 30 días incluyen la historia."
echo "Las métricas tardan hasta un minuto en aparecer."
