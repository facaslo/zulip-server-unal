#!/usr/bin/env python3
"""Borra los logs del proyecto y los descriptores de métricas de Prometheus.

Sin --execute solo muestra qué borraría.  El borrado es irreversible.

* Métricas: borra cada descriptor prometheus.googleapis.com/*.  La historia
  sigue consultable: en el borrado de 2026-11-07, una hora después PromQL
  devolvía los mismos totales a 30 días, así que esto no limpia los paneles
  de SLO.  Las que se sigan raspando reaparecen en el siguiente scrape.
* Logs: borra las entradas de cada log del bucket _Default.  No toca
  cloudaudit.googleapis.com/*: deja intacto el registro de auditoría,
  y parte de él está en _Required, que no se puede borrar.
* Trazas: no se pueden borrar.  La API de Cloud Trace no tiene ningún
  método para eso y los spans expiran solos a los 30 días.  Por eso el
  script imprime enlaces a los dashboards desde el momento del borrado.

Ejemplo:
    py gameday/observability_wipe.py
    py gameday/observability_wipe.py --execute
"""

import argparse
import os
import shutil
import subprocess
import sys
import time
from collections.abc import Callable, Iterator
from pathlib import Path
from typing import Any
from urllib.parse import quote

import requests

MONITORING_API = "https://monitoring.googleapis.com/v3"
LOGGING_API = "https://logging.googleapis.com/v2"
METRIC_PREFIX = "prometheus.googleapis.com/"
AUDIT_LOG_PREFIX = "cloudaudit.googleapis.com"
RETRYABLE_STATUS = {429, 500, 503}
MAX_ATTEMPTS = 8


def api_session() -> requests.Session:
    gcloud = shutil.which("gcloud") or shutil.which(
        "gcloud", path=str(Path.home() / "google-cloud-sdk" / "bin")
    )
    if gcloud is None:
        sys.exit("No se encontró gcloud.")
    token = subprocess.run(
        [gcloud, "auth", "print-access-token"], capture_output=True, text=True, check=True
    ).stdout.strip()
    session = requests.Session()
    session.headers["Authorization"] = f"Bearer {token}"
    return session


def paginate(
    session: requests.Session, url: str, key: str, params: dict[str, str]
) -> Iterator[Any]:
    # Any: cada API devuelve elementos JSON con su propia forma.
    params = dict(params)
    while True:
        response = session.get(url, params=params, timeout=60)
        response.raise_for_status()
        data = response.json()
        yield from data.get(key, [])
        if not data.get("nextPageToken"):
            return
        params["pageToken"] = data["nextPageToken"]


def list_metrics(session: requests.Session, project: str) -> list[str]:
    descriptors = paginate(
        session,
        f"{MONITORING_API}/projects/{project}/metricDescriptors",
        "metricDescriptors",
        {
            "filter": f'metric.type = starts_with("{METRIC_PREFIX}")',
            "fields": "metricDescriptors/type,nextPageToken",
        },
    )
    return [descriptor["type"] for descriptor in descriptors]


def list_logs(session: requests.Session, project: str) -> list[str]:
    """Nombres codificados tal como los devuelve la API, sin los de auditoría."""
    logs = paginate(session, f"{LOGGING_API}/projects/{project}/logs", "logNames", {})
    names = [name.rsplit("/logs/", 1)[1] for name in logs]
    return [name for name in names if not name.startswith(AUDIT_LOG_PREFIX)]


def delete_with_retry(session: requests.Session, url: str) -> str | None:
    """Devuelve None si quedó borrado, o el motivo si no se pudo."""
    for attempt in range(MAX_ATTEMPTS):
        response = session.delete(url, timeout=60)
        if response.ok:
            return None
        if response.status_code not in RETRYABLE_STATUS:
            return f"HTTP {response.status_code}: {response.text[:200]}"
        time.sleep(min(2**attempt, 60))
    return f"HTTP {response.status_code} tras {MAX_ATTEMPTS} intentos"


def delete_metric(session: requests.Session, project: str, metric_type: str) -> str | None:
    return delete_with_retry(
        session,
        f"{MONITORING_API}/projects/{project}/metricDescriptors/{quote(metric_type, safe='/:')}",
    )


def delete_log(session: requests.Session, project: str, encoded_log_name: str) -> str | None:
    return delete_with_retry(session, f"{LOGGING_API}/projects/{project}/logs/{encoded_log_name}")


def delete_all(label: str, names: list[str], delete_one: Callable[[str], str | None]) -> int:
    failures = 0
    for done, name in enumerate(names, start=1):
        error = delete_one(name)
        if error is not None:
            failures += 1
            print(f"  ERROR {name}: {error}", file=sys.stderr, flush=True)
        if done % 50 == 0 or done == len(names):
            print(f"  {label}: {done}/{len(names)}", flush=True)
    return failures


def main() -> None:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--project", default=os.environ.get("GCP_PROJECT", "proyecto-zulip-unal"))
    parser.add_argument(
        "--execute", action="store_true", help="borra de verdad; sin esto solo lista"
    )
    args = parser.parse_args()

    session = api_session()
    metrics = list_metrics(session, args.project)
    logs = list_logs(session, args.project)

    print(f"Proyecto: {args.project}")
    print(f"Métricas de Prometheus a borrar: {len(metrics)}")
    print(f"Logs a borrar: {len(logs)} (se conserva {AUDIT_LOG_PREFIX}/*)")
    print(
        "Trazas: no se pueden borrar; la API de Cloud Trace no lo permite y expiran a los 30 días."
    )

    if not args.execute:
        print("\nSimulación: no se borró nada. Usa --execute para borrar.")
        return

    print("\nEsto es irreversible para los logs. La historia de los SLI puede seguir consultable.")
    if (
        input(f"Escribe el nombre del proyecto para confirmar ({args.project}): ").strip()
        != args.project
    ):
        sys.exit("Cancelado: no se borró nada.")

    start_ms = int(time.time() * 1000)
    failures = delete_all(
        "métricas", metrics, lambda name: delete_metric(session, args.project, name)
    )
    failures += delete_all("logs", logs, lambda name: delete_log(session, args.project, name))

    grafana = os.environ.get("GRAFANA_URL", "http://localhost:3000")
    print("\nDashboards desde este borrado (las trazas anteriores siguen en Cloud Trace):")
    print(f"  {grafana}/d/zulip-slo?from={start_ms}&to=now")
    print(f"  {grafana}/d/zulip-saturation?from={start_ms}&to=now")
    if failures:
        sys.exit(f"{failures} borrados fallaron; vuelve a ejecutar el script para reintentarlos.")


if __name__ == "__main__":
    main()
