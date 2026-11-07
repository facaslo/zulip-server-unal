#!/usr/bin/env bash
# Provoca y revierte el incidente de caída de RabbitMQ.
#
# Uso: ./rabbitmq-crash.sh status
#      ./rabbitmq-crash.sh crash [--yes]
#      ./rabbitmq-crash.sh restore
#
# crash deja RabbitMQ en 0 réplicas, y tumba Zulip de verdad: cerca de 50 s
# después, /health falla y el Pod sale del balanceador.  Sigue caído hasta
# ejecutar restore o hasta el siguiente terraform apply, que lo restablece.
# Sus errores cuentan en la historia de los SLI de 30 días.
set -euo pipefail

PROJECT="${GCP_PROJECT:-proyecto-zulip-unal}"
CLUSTER="${GKE_CLUSTER:-zulip}"
LOCATION="${GKE_LOCATION:-us-east1-b}"
NAMESPACE="${ZULIP_NAMESPACE:-zulip}"
ZULIP_URL="${ZULIP_URL:-https://136.108.58.125}"

usage() {
    echo "Uso: $0 status | crash [--yes] | restore" >&2
    exit 2
}

action="${1:-}"
assume_yes=false
case "$action:${2:-}" in
    status: | restore:) ;;
    crash:) ;;
    crash:--yes) assume_yes=true ;;
    *) usage ;;
esac

command -v gcloud >/dev/null || PATH="$HOME/google-cloud-sdk/bin:$PATH"

gcloud container clusters get-credentials "$CLUSTER" \
    --location "$LOCATION" --project "$PROJECT" --quiet 2>/dev/null

context="gke_${PROJECT}_${LOCATION}_${CLUSTER}"
k() { kubectl --context "$context" -n "$NAMESPACE" "$@"; }

if ! kubectl --context "$context" --request-timeout=10s get --raw /healthz >/dev/null 2>&1; then
    echo "No se pudo conectar con el clúster. Si tu IP no está autorizada, ejecuta add-my-ip.sh." >&2
    exit 1
fi

now() { date -u +%H:%M:%SZ; }
login_code() { curl -k -s -m 5 -o /dev/null -w '%{http_code}' "$ZULIP_URL/login/" || true; }

show_status() {
    local desired ready
    desired="$(k get deploy rabbitmq -o jsonpath='{.spec.replicas}')"
    ready="$(k get deploy rabbitmq -o jsonpath='{.status.readyReplicas}')"
    echo "RabbitMQ: ${ready:-0}/$desired réplicas listas"
    echo "Zulip:    $(k get deploy zulip -o jsonpath='{.status.availableReplicas}') réplicas disponibles"
    echo "Login:    HTTP $(login_code) en $ZULIP_URL/login/"
}

case "$action" in
    status)
        show_status
        ;;

    crash)
        if [[ "$(k get deploy rabbitmq -o jsonpath='{.spec.replicas}')" == "0" ]]; then
            echo "RabbitMQ ya está en 0 réplicas; no se cambió nada."
            exit 0
        fi
        if [[ "$assume_yes" != true ]]; then
            echo "Esto tumba Zulip para todos sus usuarios hasta ejecutar restore."
            read -r -p "Escribe 'rabbitmq' para continuar: " answer || answer=""
            if [[ "$answer" != "rabbitmq" ]]; then
                echo "Cancelado: no se cambió nada."
                exit 1
            fi
        fi

        k scale deploy rabbitmq --replicas=0 >/dev/null
        echo "RabbitMQ caído a las $(now)."
        echo
        echo "Qué observar:"
        echo "  - Saturación: el widget de RabbitMQ pasa a Caído."
        echo "  - Explore, Cloud Trace: HasLabel:error.type muestra las publicaciones fallidas."
        echo "  - La alerta de caídas de Cloud Monitoring tardó unos 4,5 min en el ensayo."
        echo "Sin tráfico de mensajes no habrá errores ni trazas que observar."
        echo "Para revertir: $0 restore"
        ;;

    restore)
        started=$SECONDS
        k scale deploy rabbitmq --replicas=1 >/dev/null
        k rollout status deploy/rabbitmq --timeout=180s >/dev/null
        echo "RabbitMQ listo a las $(now), tras $((SECONDS - started)) s."

        for attempt in $(seq 1 60); do
            code="$(login_code)"
            [[ "$code" == "200" ]] && break
            if [[ "$attempt" == 60 ]]; then
                echo "Zulip no respondió 200 en $ZULIP_URL/login/ (último código: $code)." >&2
                exit 1
            fi
            sleep 5
        done
        echo "Zulip responde a las $(now), tras $((SECONDS - started)) s."
        ;;
esac
