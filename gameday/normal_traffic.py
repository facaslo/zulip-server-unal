#!/usr/bin/env python3
"""Tráfico normal para poblar los SLI y SLO de mensajería.

Simula a usuarios enviando y leyendo mensajes, sin inyectar fallas:

* Emisor: envía mensajes con POST /messages a intervalos aleatorios
  alrededor de --rate, y hace una lectura después de cada envío.
  Alimenta el SLI de disponibilidad.
* Receptores: colas de eventos en GET /events, de las que sale el SLI
  de latencia de entrega.

El primer archivo de --bots-dir (en orden alfabético) envía y el resto
recibe.  Los mensajes quedan guardados en #gameday.

Ejemplo:
    py gameday/normal_traffic.py --bots-dir gameday/bots --rate 0.5 --duration 3600
"""

import argparse
import random
import sys
import threading
import time
from collections import Counter
from pathlib import Path

import requests
from latency_load import Bot, Stats, receiver, report, subscribe

# Zulip limita a 200 peticiones/min por usuario (api_by_user), y un 429
# cuenta como falla en el SLI de disponibilidad.  El margen absorbe los
# picos de los intervalos aleatorios.
MAX_REQUESTS_PER_MINUTE = 150
REQUESTS_PER_MESSAGE = 2

READ_REQUESTS = [
    ("messages", {"anchor": "newest", "num_before": "20", "num_after": "0"}),
    ("users/me", {}),
    ("users/me/subscriptions", {}),
]


def sender(
    bot: Bot, args: argparse.Namespace, stats: Stats, read_status: Counter[str], stop: threading.Event
) -> None:
    session = bot.session()
    while not stop.is_set():
        started = time.time()
        try:
            response = session.post(
                f"{bot.site}/api/v1/messages",
                data={
                    "type": "stream",
                    "to": args.stream,
                    "topic": args.topic,
                    # latency_load.receiver mide la entrega a partir de este formato.
                    "content": f"gameday-load t={started:.6f}",
                },
                timeout=60,
            )
            status = str(response.status_code)
        except requests.RequestException as e:
            status = type(e).__name__
        stats.record_post(status, time.time() - started)

        path, params = random.choice(READ_REQUESTS)
        try:
            read_status[str(session.get(f"{bot.site}/api/v1/{path}", params=params, timeout=60).status_code)] += 1
        except requests.RequestException as e:
            read_status[type(e).__name__] += 1

        stop.wait(random.expovariate(args.rate))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--bots-dir", type=Path, required=True, help="directorio con un zuliprc por bot")
    parser.add_argument("--rate", type=float, default=0.5, help="mensajes/s en promedio")
    parser.add_argument("--stream", default="gameday")
    parser.add_argument("--topic", default="trafico-normal")
    parser.add_argument("--duration", type=float, default=3600, help="segundos")
    parser.add_argument("--report-every", type=float, default=30, help="segundos")
    parser.add_argument("--dry-run", action="store_true", help="valida la configuración sin enviar nada")
    args = parser.parse_args()

    requests_per_minute = args.rate * 60 * REQUESTS_PER_MESSAGE
    if not 0 < requests_per_minute <= MAX_REQUESTS_PER_MINUTE:
        sys.exit(
            f"--rate {args.rate} genera {requests_per_minute:.0f} peticiones/min; debe ser mayor que 0 y "
            f"no pasar de {MAX_REQUESTS_PER_MINUTE} para no recibir 429, que gastan presupuesto de error."
        )

    bots = [Bot(path) for path in sorted(args.bots_dir.iterdir()) if path.is_file()]
    if len(bots) < 2:
        sys.exit(f"Hay {len(bots)} bots; se necesitan un emisor y al menos un receptor.")
    sending_bot, receiving_bots = bots[0], bots[1:]

    if args.dry_run:
        for bot in bots:
            response = bot.session().get(f"{bot.site}/api/v1/users/me", timeout=30)
            role = "emisor" if bot is sending_bot else "receptor"
            print(f"{role}: {bot.email} -> GET /users/me {response.status_code}")
        print(
            f"Simulación: enviaría unos {args.rate * args.duration:.0f} mensajes a #{args.stream} > {args.topic} "
            f"en {args.duration:.0f}s ({requests_per_minute:.0f} peticiones/min del emisor). No se envió nada."
        )
        return

    for bot in bots:
        subscribe(bot, args.stream)

    stats = Stats()
    read_status: Counter[str] = Counter()
    stop = threading.Event()
    for bot in receiving_bots:
        threading.Thread(target=receiver, args=(bot, stats, stop), daemon=True).start()
    # Que las colas estén registradas y esperando antes del primer envío.
    time.sleep(3)

    sender_thread = threading.Thread(
        target=sender, args=(sending_bot, args, stats, read_status, stop), daemon=True
    )
    sender_thread.start()
    threading.Thread(target=report, args=(stats, args, stop), daemon=True).start()

    print(
        f"{args.rate} msg/s a #{args.stream} > {args.topic} con {len(receiving_bots)} receptores, "
        f"{args.duration:.0f}s. Ctrl+C para detener.",
        flush=True,
    )
    try:
        stop.wait(args.duration)
    except KeyboardInterrupt:
        pass
    stop.set()
    print("Deteniendo...", flush=True)
    sender_thread.join(timeout=60)
    print(f"Lecturas por código de respuesta: {dict(read_status)}", flush=True)


if __name__ == "__main__":
    main()
