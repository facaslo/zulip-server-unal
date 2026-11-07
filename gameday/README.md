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
4. **Saturar la capa equivocada.** Con suficiente carga (`latency_load.py --threads` alto) sí se logra
   que `POST /messages` se demore varios segundos, pero eso es tiempo de cola esperando un *worker*
   libre de uWSGI — ocurre **antes** de que el mensaje se publique. `zulip_event_delivery_latency_seconds`
   arranca el reloj recién cuando el mensaje ya se publicó internamente (`send_event_rollback_unsafe` en
   `zerver/tornado/django_api.py`), así que ese tiempo de cola nunca entra a la métrica — se puede
   saturar Django por completo sin que el burn rate de la regla se mueva. Confirmado en vivo: con 120
   hilos el Pod sostuvo 3.2-3.3 núcleos de CPU y el script veía hasta 26 % de "entregas" ≥2.5 s, pero el
   burn rate real en Grafana se quedó en ~0.13 (umbral: 5). Es la razón por la que existe la estrategia 2
   (Toxiproxy) más abajo: retrasa la conexión a RabbitMQ *después* de publicar, justo donde el SLO mide.

## Scripts de operación

Cada uno tiene versión para Bash (`.sh`) y PowerShell (`.ps1`).

| Script | Qué hace |
| --- | --- |
| `add-my-ip` | Agrega la IP pública actual a las redes autorizadas del clúster, conservando las demás. Acepta `--dry-run` (`-DryRun` en PowerShell). El siguiente `terraform apply` la quita, porque restablece la lista de `AUTHORIZED_NETWORKS`. |
| `grafana-tunnel` | Abre Grafana en `http://localhost:3000`, se reconecta si se pierde la conexión y, en una terminal, muestra el usuario y la contraseña. Acepta otro puerto local como argumento. |
| `gameday-reset` | Quita los toxics de Toxiproxy, asegura una réplica de RabbitMQ, espera a que Zulip responda e imprime enlaces a los dashboards desde ese momento. Revierte cualquier falla inyectada a propósito y no borra métricas ni logs. |
| `rabbitmq-crash` | Provoca el incidente de caída de RabbitMQ con `crash`, que pide confirmación escrita, y lo revierte con `restore`, midiendo la recuperación. `status` muestra el estado sin cambiar nada. Zulip se cae de verdad para todos sus usuarios y los errores cuentan en la historia de los SLI, así que necesita tráfico de `latency_load.py` para generar errores y trazas. |

Después de `gameday-reset`, usa la fila **Rango seleccionado** del dashboard de SLO: los paneles de 30 días
siguen incluyendo las corridas anteriores.

Dos scripts de Python, que funcionan igual en Linux y Windows, preparan los datos de los dashboards:

| Script | Qué hace |
| --- | --- |
| `observability_wipe.py` | Borra los logs del proyecto de forma irreversible, y los descriptores de métricas de Managed Prometheus, aunque **su historia sigue consultable**: se comprobó una hora después del borrado de 2026-11-07, así que no limpia los paneles de 30 días. Sin `--execute` solo muestra qué borraría; con `--execute` pide escribir el nombre del proyecto. Conserva los logs de auditoría. **No borra las trazas**: la API de Cloud Trace no lo permite y expiran a los 30 días. |
| `normal_traffic.py` | Genera tráfico normal, sin fallas, para poblar los SLI y SLO. Requiere `requests` y los bots de `gameday/bots/`. Ejemplo: `py gameday/normal_traffic.py --bots-dir gameday/bots --rate 0.5 --duration 3600`. |

Antes de borrar, confirma que nadie esté corriendo un GameDay: el borrado también elimina la evidencia de esa
corrida. Para ver una corrida sin la historia anterior, usa la fila **Rango seleccionado** del
dashboard de SLO.

Después de `gameday-reset`, usa la fila **Rango seleccionado** del dashboard de SLO: los paneles de 30 días
siguen incluyendo las corridas anteriores.

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

## Estrategia 2: Toxiproxy (rama `gameday/toxiproxy`)

Alternativa a la estrategia 1. En vez de saturar clientes/servidor para generar cola, se inserta
[Toxiproxy](https://github.com/Shopify/toxiproxy) entre Zulip y RabbitMQ
(`terraform/modules/toxiproxy`) y se retrasa la conexión directamente, *después* de que Zulip ya publicó
el mensaje — justo el tramo que mide `zulip_event_delivery_latency_seconds` (ver punto 4 de arriba). No
requiere tocar el rate limiting ni generar un volumen enorme de tráfico: con un solo mensaje por segundo
ya sostenido debería bastar, porque el retraso es determinístico (en milisegundos exactos), no un efecto
secundario de saturación.

Zulip sigue conectándose al mismo nombre DNS de siempre (la variable `SETTING_RABBITMQ_HOST` ahora
apunta a `toxiproxy` en vez de `rabbitmq`); sin ningún retraso activo, Toxiproxy reenvía el tráfico sin
tocarlo, así que no cambia nada en operación normal.

### Prender/apagar el retraso en vivo

El puerto de administración (8474) no está expuesto a otros Pods a propósito — se opera vía
`kubectl port-forward`, que pasa por el apiserver y no necesita abrir nada nuevo:

```
kubectl port-forward svc/toxiproxy -n zulip 8474:8474
```

En otra terminal, con `latency_load.py` corriendo en paralelo para generar tráfico y colas receptoras:

```
py gameday/toxiproxy_toggle.py on --latency-ms 3000 --jitter-ms 500
py gameday/toxiproxy_toggle.py status
py gameday/toxiproxy_toggle.py off
```

Esta estrategia **sí requiere** correr `latency_load.py` igual que la estrategia 1 (con sus bots
receptores en long-poll) — Toxiproxy solo provoca el retraso, pero sin clientes esperando en `GET
/events` sigue sin haber muestras que medir (punto 1 de arriba). La diferencia es que, con esta
estrategia, **no hace falta** eximir a los bots del rate limiting: con un volumen de mensajes normal
(`--rate 1`, sin ráfaga) alcanza, porque la degradación la provoca el retraso de red, no el volumen.
