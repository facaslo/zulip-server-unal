#!/usr/bin/env python3
"""Carga para el escenario de latencia.

Genera las dos cosas que necesita el SLI de latencia de entrega
(zulip_event_delivery_latency_seconds):

* Receptores: colas de eventos haciendo long-polling en GET /events.
  Tornado solo registra una muestra cuando el cliente ya estaba
  esperando (ver process_message_event en
  zerver/tornado/event_queue.py); sin receptores no hay muestras.
* Emisores: hilos que envían mensajes con POST /messages a un stream.

Cada mensaje lleva la hora de envío, así que el script también mide la
latencia vista por el cliente, como evidencia independiente de Grafana.

Credenciales: un directorio con los archivos zuliprc descargados de
cada bot (Configuración personal > Bots > descargar zuliprc).  Los
primeros --senders bots (en orden alfabético de archivo) envían; el
resto recibe.

Ejemplo:
    py gameday/latency_load.py --bots-dir gameday/bots --senders 1 \
        --threads 2 --rate 1 --queues-per-receiver 1 --duration 1200
"""

import argparse
import configparser
import json
import random
import re
import statistics
import sys
import threading
import time
from collections import Counter
from pathlib import Path

import requests
import urllib3

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

SLO_SECONDS = 2.5
CONTENT_RE = re.compile(r"gameday-load t=(\d+\.\d+)")


class Bot:
    def __init__(self, path: Path) -> None:
        config = configparser.ConfigParser()
        config.read(path, encoding="utf-8")
        self.email = config["api"]["email"]
        self.key = config["api"]["key"]
        self.site = config["api"]["site"].rstrip("/")

    def session(self) -> requests.Session:
        session = requests.Session()
        session.auth = (self.email, self.key)
        # El clúster usa un certificado autofirmado (CERTIFICATES=self-signed).
        session.verify = False
        return session


class Stats:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.post_status: Counter[str] = Counter()
        self.post_latencies: list[float] = []
        self.delivery_latencies: list[float] = []
        self.poll_errors: Counter[str] = Counter()

    def record_post(self, status: str, seconds: float) -> None:
        with self.lock:
            self.post_status[status] += 1
            self.post_latencies.append(seconds)

    def record_delivery(self, seconds: float) -> None:
        with self.lock:
            self.delivery_latencies.append(seconds)

    def record_poll_error(self, status: str) -> None:
        with self.lock:
            self.poll_errors[status] += 1

    def take(self) -> tuple[Counter[str], list[float], list[float], Counter[str]]:
        with self.lock:
            snapshot = (
                self.post_status,
                self.post_latencies,
                self.delivery_latencies,
                self.poll_errors,
            )
            self.post_status = Counter()
            self.post_latencies = []
            self.delivery_latencies = []
            self.poll_errors = Counter()
        return snapshot


def percentile(values: list[float], q: float) -> float:
    if len(values) == 1:
        return values[0]
    return statistics.quantiles(values, n=100, method="inclusive")[q - 1]


def describe(values: list[float]) -> str:
    if not values:
        return "sin datos"
    return f"n={len(values)} p50={percentile(values, 50):.2f}s p95={percentile(values, 95):.2f}s"


def subscribe(bot: Bot, stream: str) -> None:
    response = bot.session().post(
        f"{bot.site}/api/v1/users/me/subscriptions",
        data={"subscriptions": json.dumps([{"name": stream}])},
        timeout=30,
    )
    if response.status_code != 200:
        sys.exit(f"No se pudo suscribir {bot.email} a #{stream}: {response.text}")


def sender(bot: Bot, args: argparse.Namespace, stats: Stats, stop: threading.Event) -> None:
    session = bot.session()
    interval = args.threads / args.rate if args.rate > 0 else 0
    while not stop.is_set():
        started = time.time()
        try:
            response = session.post(
                f"{bot.site}/api/v1/messages",
                data={
                    "type": "stream",
                    "to": args.stream,
                    "topic": args.topic,
                    "content": f"gameday-load t={started:.6f}",
                },
                timeout=60,
            )
            status = str(response.status_code)
        except requests.RequestException as e:
            status = type(e).__name__
        stats.record_post(status, time.time() - started)
        if interval:
            stop.wait(max(0.0, interval - (time.time() - started)))


def register(session: requests.Session, site: str) -> tuple[str, int]:
    response = session.post(
        f"{site}/api/v1/register",
        data={"event_types": '["message"]', "apply_markdown": "false"},
        timeout=60,
    )
    response.raise_for_status()
    data = response.json()
    return data["queue_id"], data["last_event_id"]


def receiver(bot: Bot, stats: Stats, stop: threading.Event) -> None:
    session = bot.session()
    queue_id, last_event_id = register(session, bot.site)
    try:
        while not stop.is_set():
            try:
                response = session.get(
                    f"{bot.site}/api/v1/events",
                    params={"queue_id": queue_id, "last_event_id": last_event_id},
                    timeout=120,
                )
            except requests.RequestException as e:
                stats.record_poll_error(type(e).__name__)
                stop.wait(1)
                continue
            received = time.time()
            if response.status_code != 200:
                stats.record_poll_error(str(response.status_code))
                if "BAD_EVENT_QUEUE_ID" in response.text:
                    queue_id, last_event_id = register(session, bot.site)
                else:
                    stop.wait(1)
                continue
            for event in response.json()["events"]:
                last_event_id = max(last_event_id, event["id"])
                if event["type"] != "message":
                    continue
                match = CONTENT_RE.search(event["message"]["content"])
                if match:
                    stats.record_delivery(received - float(match.group(1)))
    finally:
        try:
            session.delete(
                f"{bot.site}/api/v1/events", data={"queue_id": queue_id}, timeout=10
            )
        except requests.RequestException:
            pass


def report(stats: Stats, args: argparse.Namespace, stop: threading.Event) -> None:
    started = time.time()
    while not stop.wait(args.report_every):
        post_status, post_latencies, deliveries, poll_errors = stats.take()
        slow = sum(1 for d in deliveries if d >= SLO_SECONDS)
        slow_share = f"{100 * slow / len(deliveries):.0f}%" if deliveries else "-"
        print(
            f"[{time.strftime('%H:%M:%S')} +{time.time() - started:.0f}s] "
            f"POST {dict(post_status)} {describe(post_latencies)} | "
            f"entrega {describe(deliveries)} >= {SLO_SECONDS}s: {slow_share}"
            + (f" | errores GET /events {dict(poll_errors)}" if poll_errors else ""),
            flush=True,
        )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--bots-dir", type=Path, required=True, help="directorio con un zuliprc por bot")
    parser.add_argument("--senders", type=int, default=1, help="cuántos bots envían; el resto recibe")
    parser.add_argument("--threads", type=int, default=1, help="hilos de envío en total")
    parser.add_argument("--rate", type=float, default=1.0, help="mensajes/s en total; 0 = sin pausa")
    parser.add_argument("--queues-per-receiver", type=int, default=1, help="colas de eventos por bot receptor")
    parser.add_argument("--stream", default="gameday")
    parser.add_argument("--topic", default="carga")
    parser.add_argument("--duration", type=float, default=600, help="segundos")
    parser.add_argument("--report-every", type=float, default=10, help="segundos")
    args = parser.parse_args()

    bots = [Bot(path) for path in sorted(args.bots_dir.iterdir()) if path.is_file() and path.name != ".gitignore"]
    if len(bots) <= args.senders:
        sys.exit(f"Hay {len(bots)} bots; se necesita al menos uno receptor además de {args.senders} emisores.")
    senders, receivers = bots[: args.senders], bots[args.senders :]

    for bot in bots:
        subscribe(bot, args.stream)

    stats = Stats()
    stop = threading.Event()
    threads = [
        threading.Thread(target=receiver, args=(bot, stats, stop), daemon=True)
        for bot in receivers
        for _ in range(args.queues_per_receiver)
    ]
    for thread in threads:
        thread.start()
    # Que las colas estén registradas y esperando antes del primer envío.
    time.sleep(3)

    sender_threads = [
        threading.Thread(target=sender, args=(senders[i % len(senders)], args, stats, stop), daemon=True)
        for i in range(args.threads)
    ]
    for thread in sender_threads:
        thread.start()
        time.sleep(random.uniform(0, 0.2))
    threads += sender_threads

    print(
        f"{len(senders)} emisores en {args.threads} hilos a {args.rate or 'máx'} msg/s, "
        f"{len(receivers) * args.queues_per_receiver} colas receptoras, #{args.stream} > {args.topic}, "
        f"{args.duration:.0f}s. Ctrl+C para detener.",
        flush=True,
    )
    reporter = threading.Thread(target=report, args=(stats, args, stop), daemon=True)
    reporter.start()
    try:
        stop.wait(args.duration)
    except KeyboardInterrupt:
        pass
    stop.set()
    print("Deteniendo...", flush=True)
    for thread in sender_threads:
        thread.join(timeout=60)


if __name__ == "__main__":
    main()
