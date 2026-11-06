#!/usr/bin/env python3
"""Prender/apagar el retraso de red del escenario de latencia (Toxiproxy).

El proxy "rabbitmq" ya existe desde que arranca el Pod de Toxiproxy (ver
terraform/modules/toxiproxy); este script solo agrega o quita el *toxic* de
latencia sobre esa conexión, vía la API HTTP de administración (puerto 8474).

Requiere acceso al puerto admin, normalmente vía:
    kubectl port-forward svc/toxiproxy -n <namespace> 8474:8474

Ejemplo:
    py gameday/toxiproxy_toggle.py on --latency-ms 3000 --jitter-ms 500
    py gameday/toxiproxy_toggle.py status
    py gameday/toxiproxy_toggle.py off
"""

import argparse
import sys

import requests

PROXY_NAME = "rabbitmq"
TOXIC_NAME = "gameday-latency"


def toxic_url(base_url: str) -> str:
    return f"{base_url}/proxies/{PROXY_NAME}/toxics/{TOXIC_NAME}"


def cmd_on(base_url: str, latency_ms: int, jitter_ms: int) -> None:
    response = requests.post(
        f"{base_url}/proxies/{PROXY_NAME}/toxics",
        json={
            "name": TOXIC_NAME,
            "type": "latency",
            "stream": "downstream",
            "attributes": {"latency": latency_ms, "jitter": jitter_ms},
        },
        timeout=10,
    )
    if response.status_code == 409:
        sys.exit(f"El toxic '{TOXIC_NAME}' ya existe. Corre 'off' primero si quieres cambiar los valores.")
    response.raise_for_status()
    print(f"Retraso activo: {latency_ms}ms ± {jitter_ms}ms sobre la conexión a RabbitMQ.")


def cmd_off(base_url: str) -> None:
    response = requests.delete(toxic_url(base_url), timeout=10)
    if response.status_code == 404:
        print("No había ningún retraso activo.")
        return
    response.raise_for_status()
    print("Retraso desactivado; la conexión a RabbitMQ vuelve a la normalidad.")


def cmd_status(base_url: str) -> None:
    response = requests.get(f"{base_url}/proxies/{PROXY_NAME}", timeout=10)
    response.raise_for_status()
    proxy = response.json()
    toxics = proxy.get("toxics", [])
    if not toxics:
        print(f"Proxy '{PROXY_NAME}': sin retraso activo.")
        return
    for toxic in toxics:
        print(f"Proxy '{PROXY_NAME}': toxic '{toxic['name']}' activo -> {toxic['attributes']}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--toxiproxy-url", default="http://localhost:8474", help="URL de la API admin (default: port-forward local)"
    )
    subparsers = parser.add_subparsers(dest="action", required=True)

    on_parser = subparsers.add_parser("on", help="Activar el retraso")
    on_parser.add_argument("--latency-ms", type=int, default=3000)
    on_parser.add_argument("--jitter-ms", type=int, default=500)

    subparsers.add_parser("off", help="Desactivar el retraso")
    subparsers.add_parser("status", help="Ver si hay retraso activo")

    args = parser.parse_args()

    if args.action == "on":
        cmd_on(args.toxiproxy_url, args.latency_ms, args.jitter_ms)
    elif args.action == "off":
        cmd_off(args.toxiproxy_url)
    elif args.action == "status":
        cmd_status(args.toxiproxy_url)


if __name__ == "__main__":
    main()
