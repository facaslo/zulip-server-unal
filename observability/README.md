# MANIFIESTO DE OBSERVABILIDAD

GRUPO A:
- Fabian Camilo Castro Lozano
- Jorge Orlando Celemin Rodriguez
- Kelly Johana Solano Calderón


---

Manifiestos de configuración de monitoreo del Entregable 3 (SLIs/SLOs/Error Budget/Alertamiento). Se
provisionan dentro del clúster vía Terraform (`terraform/modules/monitoring/main.tf`), que solo inyecta
estos archivos en ConfigMaps sin interpretarlos — la lectura/validación real la hace Grafana en tiempo de
arranque (provisioning nativo).

## Contenido

- `dashboards/zulip-slo.json` — dashboard de Grafana "Zulip · SLI y SLO de mensajería": disponibilidad de
  `POST /messages` (SLO 99%), presupuesto de error y burn rate, latencia de entrega p95 (SLO ≤2.5s), y
  estado de los exporters/componentes con estado (Postgres, Redis).
  Su última fila repite esos SLI sobre el rango seleccionado, para ver una corrida del GameDay sin la historia
  anterior. Es solo una vista: los SLO y las alertas siguen usando sus ventanas de siempre.
- `dashboards/zulip-saturation.json` — dashboard "Zulip · Saturación": qué tan cerca están los componentes de sus
  límites (conexiones, discos, CPU y memoria), el estado de RabbitMQ, y en una fila colapsada las trazas lentas, con
  error 500 o con fallos al publicar en RabbitMQ. Esa fila solo consulta Cloud Trace al abrirla.
- `alerting/rules/` — reglas de alerta de **Burn Rate Alerting** (formato de provisioning nativo de
  Grafana, `apiVersion: 1`), una por escenario de simulación cubierto:
  - `availability-burn-rate.yaml` — escenario de disponibilidad (caída de RabbitMQ → rompe el SLO de disponibilidad).
  - `latency-burn-rate.yaml` — escenario de latencia (degradación de RabbitMQ → rompe el SLO de latencia).
- `alerting/contactpoints.yaml` — contact point de email para las notificaciones.
- `alerting/notification-policies.yaml` — política de enrutamiento de las alertas hacia ese contact point.

## Trazas

Las trazas de Zulip se guardan en Cloud Trace y Grafana las consulta con el datasource **Cloud Trace**
(plugin `googlecloud-trace-datasource`, aprovisionado en `terraform/modules/monitoring/main.tf`). Para verlas,
se abre Grafana, se entra a **Explore**, se elige ese datasource y se usa una de estas consultas:

- **Filter**: lista las trazas de la ventana de tiempo. Se puede acotar con filtros aditivos como
  `MinLatency:500ms` o `/http/method:POST`.
- **Trace ID**: abre una traza por su identificador.

Grafana instala el plugin en segundo plano cada vez que arranca, porque el Pod no tiene disco, así que el
datasource puede tardar unos segundos en responder después de un reinicio. Si la descarga falla, Grafana y las
alertas siguen funcionando y solo falla el datasource de trazas; reiniciar el Pod vuelve a intentar la instalación.

## Logs

Grafana consulta Cloud Logging con el datasource **Cloud Logging** (plugin `googlecloud-logging-datasource`). Se
instala igual que el de trazas, así que también puede tardar unos segundos después de un reinicio. Para ver los
errores de Zulip, se abre **Explore**, se elige ese datasource y se usa esta consulta:

```
resource.type="k8s_container"
resource.labels.namespace_name="zulip"
resource.labels.container_name="zulip"
textPayload=~"\b(ERR|CRIT)\b|Traceback"
```

El contenedor escribe `/var/log/zulip/errors.log` en su salida estándar como texto plano. Por eso la consulta busca
en el texto y no usa `severity`, y busca `ERR` porque así abrevia Zulip ese nivel. Ese archivo también trae las líneas
`WARN`. Cada línea de un traceback es una entrada aparte; para leerlo completo, se quita el filtro de texto y se miran
las entradas de ese momento.

## Detección de caídas

Las alertas de burn rate dependen de que Zulip reporte métricas y de que Grafana esté en pie. Para cubrir una
caída completa, `terraform/modules/monitoring/uptime.tf` crea en Cloud Monitoring una sonda de `/login/` cada 5 minutos
desde varias regiones, una alerta cuando falla desde más de una región y un canal de correo propio, enviado a
`zulip_administrator`. Nada de esto corre dentro del clúster ni se ve en Grafana: se administra desde
**Monitoring** en la consola de Google Cloud.

## Alcance

Por ahora solo existen reglas de alerta para el escenario de **disponibilidad** y el de **latencia**
(ambos centrados en una caída/degradación de RabbitMQ) — otros escenarios de degradación (por ejemplo,
caída de la base de datos o saturación por volumen de tráfico) quedan fuera de alcance de esta entrega.

## Umbral de burn rate

Ambas reglas usan el mismo patrón: `(métrica observada en la ventana de 1h) / (margen del SLO) > 5`. El
multiplicador 5 corresponde a un horizonte de agotamiento del presupuesto de 30 días en ~6 días si la tasa
de fallos se sostiene.
