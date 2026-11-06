# GameDay: escenario de latencia

Herramientas para inyectar y observar la degradación del SLI de latencia de entrega
(`zulip_event_delivery_latency_seconds`, SLO p95 ≤ 2.5 s) y disparar la alerta
`ZulipEventDeliveryLatencyBurnRateHigh` (`observability/alerting/rules/latency-burn-rate.yaml`).

## Por qué no se disparó la alerta en el Entregable 3

1. **Sin clientes esperando no hay muestras.** Tornado solo observa la métrica cuando el cliente ya
   estaba esperando en `GET /events` (`process_message_event` en `zerver/tornado/event_queue.py`).
   Un script que solo hace `POST /messages` no genera ninguna muestra de latencia.
2. **Rate limiting.** Zulip limita cada usuario a 200 peticiones/min (`api_by_user` en
   `zproject/default_settings.py`). Lo que pasa de ahí recibe 429: el mensaje no se envía, no hay
   latencia que medir, y el 429 cuenta como falla de *disponibilidad*, no de latencia.
3. **Ventana de evaluación.** La regla calculaba la proporción de entregas lentas en la última hora; un
   pico corto (SIGSTOP/SIGCONT) se diluía entre el tráfico normal de esa hora. Se corrigió a una ventana
   de 5 min (ver `observability/alerting/rules/latency-burn-rate.yaml`), la misma del SLI documentado
   originalmente — con los 10 min en vivo del GameDay no alcanza para que una ventana de 1h muestre
   Firing. Aun así hay que sostener la degradación varios minutos hasta superar el 25 % de entregas
   lentas (burn rate 5 × margen del 5 %).

## Preparación

1. En Zulip, crear el stream `gameday`.
2. Crear 6 bots genéricos (Configuración personal → Bots → Agregar bot → tipo *Genérico*) y
   descargar el `zuliprc` de cada uno en `gameday/bots/` con nombres distintos, por ejemplo
   `01-emisor.zuliprc`, `02-receptor.zuliprc`, … Ese directorio está en `.gitignore`.
   Usar varios bots receptores evita que el long-polling de un mismo usuario choque con el límite de
   200 peticiones/min.
3. Instalar dependencias: `py -m pip install requests`.

## Antes de correr la carga: eximir a los bots del rate limiting

Sin esto, el límite normal de 200 peticiones/min por usuario (`api_by_user`) corta la carga con `429`
antes de generar suficiente degradación de latencia — y el `429` cuenta como falla de *disponibilidad*,
no de latencia (ver punto 2 arriba). Ejecutar dentro del Pod de Zulip, repitiendo `--email` por cada bot
(emisores y receptores):

```
kubectl exec -it deploy/zulip -- python manage.py gameday_rate_limit_exempt \
    --realm zulip --enable \
    --email 01-emisor-bot@... --email 02-receptor-bot@... ...
```

Pide una confirmación escrita antes de aplicar el cambio (no es simulado, toca la base de datos real).
Al terminar el ejercicio, restaurar siempre el límite normal:

```
kubectl exec -it deploy/zulip -- python manage.py gameday_rate_limit_exempt \
    --realm zulip --disable \
    --email 01-emisor-bot@... --email 02-receptor-bot@... ...
```

## Uso

```
py gameday/latency_load.py --bots-dir gameday/bots --senders 1 --threads 2 --rate 1 --duration 1200
```

- Los primeros `--senders` archivos (orden alfabético) envían; el resto recibe con
  `--queues-per-receiver` colas cada uno.
- `--rate 0` envía sin pausa (modo ráfaga).
- Cada 10 s imprime los códigos HTTP de `POST /messages`, su latencia, y la latencia de entrega vista
  por el cliente (p50/p95 y % ≥ 2.5 s). Es evidencia independiente de Grafana.

## Consultas para Grafana Explore

Burn rate exacto de la regla (ventana 5 min, umbral 5):

```
(1 - (sum(rate(zulip_event_delivery_latency_seconds_bucket{event_type="message", le="2.5"}[5m]))
  / sum(rate(zulip_event_delivery_latency_seconds_count{event_type="message"}[5m])))) / 0.05
```

p95 de entrega en ventana corta, para ver el efecto en vivo:

```
histogram_quantile(0.95, sum(rate(zulip_event_delivery_latency_seconds_bucket{event_type="message"}[5m])) by (le))
```

Managed Prometheus raspa las métricas de Zulip cada 60 s; la regla se evalúa cada 5 min y exige
`for: 5m`. Desde que la degradación supera el umbral, Firing tarda entre 5 y 10 min.
