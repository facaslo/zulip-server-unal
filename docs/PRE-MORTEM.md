# Informe Pre-Mortem

## GD-01: Indisponibilidad de mensajería por caída de RabbitMQ

Escenario: Caída de RabbitMQ

Incidente relacionados: INC-001 - Fallas en el envió de mensajes

SLO afectado: Disponibilidad del SLO 99%

### 1. Descripción del escenario

Se plantea un escenario en el que RabbitMQ, componente utilizado por Zulip para el procesamiento de eventos de mensajería, deja de estar disponible, generando fallas en el envío de mensajes y afectando la comunicación entre los usuarios.

Actualmente, RabbitMQ cuenta con una sola réplica dentro del clúster de Kubernetes, por lo que se identifica un riesgo para la continuidad del servicio al no disponer de otra instancia que permita asumir su operación ante una falla. Esta situación podría ocasionar errores en las solicitudes de envío, afectar el cumplimiento de SLO de disponibilidad del 99% y generar un consumo acelerado del presupuesto de errores.

Con base en lo anterior, se realiza el análisis de las posibles causas que podrían ocasionar este incidente, su impacto sobre la operación y las medidas preventivas, detectivas y correctivas que permitirán reducir el riesgo.

### 2. Análisis de causas - Técnicas de los cinco Porqué

1.  **¿Por qué los usuarios no pueden enviar mensajes?**

Rta: Porque Zulip presenta errores al procesar operaciones que requieren la disponibilidad de RabbitMQ.

2.  **¿Por qué RabbitMQ no puede atender las solicitudes?**

Porque su instancia se encuentra indisponible, impidiendo el procesamiento de las operaciones que dependen de este componente

3.  **¿Por qué la falla de una instancia afecta a todo el servicio?**

Porque RabbitMQ se encuentra desplegado con una sola réplica. sin otra instancia que pueda asumir su operación.

4.  **¿Por qué no se implementó una configuración redundante?**

Porque la arquitectura se diseñó con base al alcance del proyecto, priorizando el despliegue automático, la observabilidad y los recursos disponibles

5.  **¿Por qué esta condición podría convertirse en una falla crítica en producción ?**

Porque mantener una dependencia crítica sin mecanismos de redundancia incrementa el riesgo de interrupción y puede requerir intervención operativa para recuperar el servicio.

**Causa raíz hipotética identificada**

Se identifica como principal vulnerabilidad la dependencia de una única instancia de RabbitMQ para el procesamiento de operaciones de mensajería, sin contar con un mecanismo de alta disponibilidad que permita mantener la continuidad del servicio ante su indisponibilidad.

Esta condición corresponde a un riesgo de arquitectura y no a una causa raíz comprobada de una incidencia real en producción.

### 3. Impacto sobre SLI, SLO y Error Budget

Para el servicio de mensajería de Zulip se tiene definido un SLO de disponibilidad del 99%, evaluado durante 30 días, con un margen permitido de errores del 1%. Adicionalmente se cuenta con una alerta Burn Rate superior a 5x, que permite identificar un consumo acelerado del presupuesto de errores.

Para dimensionar el impacto potencial, se plantea el siguiente escenario hipotético durante una hora de operación.

| **Indicador**                | **Valor** |
|------------------------------|-----------|
| Solicitudes totales de envío | 200       |
| Solicitudes exitosas         | 180       |
| Solicitudes fallidas         | 20        |
| SLO de disponibilidad        | 99%       |
| Margen permitido de errores  | 1%        |

**Cálculo del SLI de disponibilidad**

Permite conocer el porcentaje de solicitudes exitosas.

$$
\mathrm{SLI} = \frac{\text{Solicitudes exitosas}}{\text{Solicitudes totales}}\times100
$$

$$
\mathrm{SLI} = \frac{180}{200}\times100 = 90\%
$$

El SLI sería del 90%, mientras que el objetivo establecido es del 99%

La diferencia frente al objetivo sería:

$$
99\%-90\%=9\ \text{puntos porcentuales}
$$

**Cálculo de la tasa de errores**

Permite identificar qué porcentaje de las solicitudes presentaron fallas

$$
\text{Tasa de errores} = \frac{\text{Solicitudes fallidas}}{\text{Solicitudes totales}}\times100
$$

$$
\text{Tasa de errores} = \frac{20}{200}\times100 = 10\%
$$

Esto significa que 10 de cada 100 solicitudes estarían fallando.

**Cálculo del Burn Rate**

Permite determinar qué tan rápido se está consumiendo el presupuesto de errores frente al margen permitido por el SLO.

$$
\text{Burn Rate} = \frac{\text{Tasa de errores observada}}{\text{Margen de error permitido}}
$$

$$
\text{Burn Rate} = \frac{10\%}{1\%} = 10\mathrm{x}
$$

El resultado indica que los errores se presentan a una velocidad diez veces superior a la permitida. Esto supera el umbral de alerta de 5x definido para la plataforma.

**Cálculo de solicitudes mensuales**

Se considera un tráfico de 200 solicitudes por hora durante 30 días.

$$
\text{Solicitudes mensuales} = 200\times24\times30
$$

$$
\text{Solicitudes mensuales} = 144\,000
$$

**Estimado del Error Budget**

Para un SLO del 99%, el margen permitido de errores es del 1%.

$$
\text{Error Budget} = 144\,000\times\frac{1}{100}
$$

$$
\text{Error Budget} = 1\,440\ \text{solicitudes fallidas}
$$

**Cálculo del consumo del Error Budget**

Permite conocer qué porcentaje del presupuesto mensual consumirá 20 solicitudes fallidas.

$$
\text{Consumo} = \frac{\text{Errores del incidente}}{\text{Errores permitidos al mes}}\times100
$$

$$
\text{Consumo} = \frac{20}{1440}\times100 \approx 1{,}39\%
$$

las 20 solicitudes fallidas representan aproximadamente el 1,39% del presupuesto mensual.

### 4. Plan de contingencia y mitigación

Para atender este incidente se tomará como referencia el procedimiento establecido en el Runbook INC-001 - Fallas en el envío de mensajes

| **Etapa**    | **Acción propuesta**                                                                                                                 |
|--------------|--------------------------------------------------------------------------------------------------------------------------------------|
| Detección    | Identificar errores HTTP 500, diseminación de la tasa de éxito e incremento del Burn Rate mediante Grafana.                          |
| Diagnóstico  | Validar el estado de RabbitMQ, sus réplicas, los eventos de kubernetes y los logs de Zulip                                           |
| Mitigación   | Restablecer RabbitMQ de acuerdo con la causa identificada, verificando su configuración y la cantidad de réplicas definidas.         |
| Recuperación | Confirmar la disponibilidad de RabbitMQ y el correcto envío y recepción de mensajes.                                                 |
| Validación   | Comprobar que los mensajes registrados previamente continúen disponibles y que los indicadores recientes evidencien la recuperación. |

Se tiene en cuenta que las alertas basadas en ventanas de tiempo pueden continuar reflejando errores anteriores, aun cuando el servicio ya se encuentre recuperado. Por esta razón, se requiere validar tanto los indicadores como el funcionamiento de la plataforma.

### 5. Controles y acciones de mejora

Con base en el análisis realizado, se proponen las siguiente medidas para reducir la probabilidad de ocurrencia del incidente, facilitar su identificación y mejorar la capacidad de recuperación.

#### a) Medidas preventivas

Buscan reducir el riesgo de que RabbitMQ deje de estar disponible y afecte la operación de Zulip.

| **Acción propuesta**                                                         | **Estado** |
|------------------------------------------------------------------------------|------------|
| Evaluar mecanismos de alta disponibilidad para RabbitMQ                      | Propuesto  |
| Fortalecer los controles sobre cambios de configuración cantidad de réplicas | Propuesto  |
| Realizar pruebas periódicas de recuperación del servicio.                    | Propuesto  |

#### b) Medidas detectivas

Permiten identificar oportunamente la indisponibilidad de RabbitMQ conocer el impacto generado sobre el servicio de mensajería.

| **Acción**                                            | **Mecanismo de detección**                                     | **Estado**   |
|-------------------------------------------------------|----------------------------------------------------------------|--------------|
| Monitorear la disponibilidad del envío de mensajes    | SLI de tasa de éxito mediante Prometheus Grafana               | Implementado |
| Identificar el consumo acelerado del Error Buget      | Alerta de burn Rater superior a 5x                             | Implementado |
| Identificar errores asociados al envío de mensajes    | Métricas HTTP revisión de logs de Zulip                        | Disponible   |
| Detectar directamente la indisponibilidad de RabbitMQ | Alerta por ausencia de réplicas disponibles o falla del broker | propuesto    |

Se identifica que actualmente la plataforma cuenta con mecanismos para detectar la afectación del envío de mensajes. Sin embargo, se propone complementar estas capacidades con una alerta específica de disponibilidad de RabbitMQ, que permita identificar la falla del componente de manera más directa.

#### c) Medidas correctivas y de recuperación

Estas medidas buscan reducir el tiempo de indisponibilidad de RabbitMQ, restablecer el funcionamiento de Zulip y evitar que una falla similar se presente nuevamente.

Con base en el escenario identificado, se propone las siguientes acciones

| **Acción propuesta**                                               | **Objetivo**                                                                                                                                                |
|--------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------|
| Establecer un procedimiento de recuperación controlada de RabbitMQ | Permitir el restablecimiento del componente según la causa identificada, evitando reinicios o modificaciones innecesarias sobre otros servicios.            |
| Definir mecanismos de recuperación ante fallas de la instancia.    | Evaluar alternativas que permitan recuperar RabbitMQ cuando se presenten problemas de ejecución, recursos o indisponibilidad del Pod.                       |
| Validar el estado de las colas, después de la recuperación.        | Identificar mensajes pendientes de procesamiento y comprobar que el servicio retome su funcionamiento.                                                      |
| Establecer criterios de recuperación del servicio.                 | Confirmar que RabbitMQ se encuentre disponible, que Zulip permite enviar y recibir mensajes y que la información almacenada previamente continúe accesible. |
| Analizar las causas del incidente y aplicar acciones de mejora.    | Identificar las condiciones que ocasionaron la falla y establecer ajustes que permitan reducir su probabilidad de repetición,                               |

Se considera importante que la recuperación no se limite únicamente a restablecer la instancia de RabbitMQ, dado que también se requiere comprobar el funcionamiento de los servicios que dependen de este componente.

## GD-02: Degradación de latencia en la entrega de eventos por saturación en la conexión a RabbitMQ

Escenario: Degradación de latencia de la entrega de eventos (mensajes) por una saturación de la conexión a RabbitMQ.

Incidente relacionados: GD-02

SLO afectado: Latencia de entrega $P95 \leq 2.5\ s$.

### 1. Descripción del escenario

Se define un escenario donde la entrega de los eventos en Zulip, que son los que permiten la llegada de los mensajes y que se ejecutan a través de un long-polling con petición a GET /events, presentan una latencia en su recepción. El proceso del envío de mensajes lo realiza el componente de Tornado, que consume los mensajes de RabbitMQ publicados por Django.

A diferencia del escenario anterior de disponibilidad, en este caso, el Broker (el mediador de comunicaciones) sigue disponible, pero la conexión hacia él se degrada parcialmente, sin llegar a una indisponibilidad.

Para realizar la simulación controlada y repetible, se utiliza la herramienta de Toxiproxy, un proxy TCP que permite simular condiciones de red entre el componente de Zulip y el de RabbitMQ, al inyectar un retraso configurable (para este escenario, se define un retraso de $3000\ ms \pm 500\ ms$ en variación del retraso) sobre esa condición específica.

### 2. Análisis de causas - Técnica de los 5 Porqués

1.  **¿Por qué los usuarios no pueden enviar mensajes?**

Rta: Porque la latencia en la entrega de eventos, como el de los mensajes (GET /events) ha aumentado, superando el umbral definido de 2.5 s (el SLO) de forma sostenida.

2.  **¿Por qué sube la latencia de entrega si RabbitMQ está disponible?**

Rta: Porque la conexión entre Zulip (el productor de los eventos de mensaje) y RabbitMQ (el receptor de ese evento y encargado de la cola que consume Tornado) está degradada. Se descarta que exista una saturación de cómputo (por ejemplo, un aumento en el consumo de CPU/memoria en los Pods), o que sea por un error de disponibilidad, porque las tasa de error de POST /messages se mantienen normales, por eso se define que el suceso está aislado a esa conexión.

3.  **¿Por qué una sola conexión degradada afecta a todos los usuarios?**

Rta: Porque la conexión afecta es la única que usa el servicio de Zulip para publicar y consumir los eventos de mensajería. Actualmente el sistema no tiene implementada una ruta alterna para aplicar redundancia de red, por eso se depende completamente de la conexión entre Zulip con RabbitMQ para ello.

4.  **¿Por qué no existe una ruta alterna?**

Porque la arquitectura actual no cuenta con mecanismos de resiliencia de red (failover o múltiples rutas) que le permitan redirigir la conexión y el flujo de mensajes.

5.  **¿Por qué esto podría ser crítico en producción?**

Rta: Resulta crítico en producción porque una degradación real en la red, por una congestión entre zonas, una saturación del Broker, un enlace físico degradado o similares, tendría el mismo efecto que este escenario. Bajo el estado actual del proyecto, no hay forma automática de detectarlo o de recuperarlo sin requerir intervención manual.

**Causa raíz hipotética identificada:** Se identifica que la afectación se debe a la dependencia de una única ruta de red hacía el componente de RabbitMQ, el cual no tiene un mecanismo de detección de fallas ni failover ante una degradación de la conexión.

### 3. Impacto sobre SLI, SLO y Error Budget

Nuevamente relacionando el servicio de mensajería, en este se define un SLI sobre la proporción de entrega de eventos (GET /events) con latencia $< 2.5\ s$, lo que es equivalente a decir que el 95% de las entregas de mensajes mantienen una latencia $\leq 2.5\ s$.

A diferencia del SLI de disponibilidad, este SLI se mide por la entrega individual, como la diferencia entre el momento en el que el evento se publica y el momento en el que el cliente lo recibe:

**Cálculo del SLI de latencia:**

$$
\mathrm{SLI}_{\mathrm{Latencia}} = \text{tiempo de entrega} - \text{timestamp del evento}
$$

Para el caso del SLO, se define como la latencia de entrega de eventos $P95 \leq 2.5\ s$, evaluada sobre una ventana de 30 días, sobre las muestras individuales de entrega, con un margen de error permitido del 5%. Se cuenta con una alerta Burn Rate de 5x ($(1 - proporción\ entregas < 2.5\ s)/0.05$), que daría un agotamiento del presupuesto en 6 días, si el incidente se sostiene.

La ventana de evaluación para este escenario se define de 5 minutos, por fines demostrativos.

Para dimensionar el impacto, se presenta el siguiente escenario: si la degradación de la conexión de red hacia RabbitMQ eleva la latencia de entrega por encima del umbral del SLO (2.5 s) para una parte de las entregas, de forma sostenida durante la ventana de evaluación de la regla (5 minutos), se estima el siguiente comportamiento.

| **Muestra**                                      | $\Delta$ **(Latencia de entrega)** |
|--------------------------------------------------|------------------------------------|
| Entregas totales estimadas en la ventana (5 min) | 20                                 |
| Entregas totales estimadas en la ventana (5 min) | 20                                 |
| Proporción de entregas lentas                    | 100%                               |
| SLO de latencia (p95)                            | $\leq 2.5\ s$                      |
| Margen permitido de errores                      | 50%                                |

\*La anterior tabla muestra los primeros resultados vistos durante la simulación

**Cálculo del Burn Rate**

Para cuantificar la severidad del incumplimento, se calculó el Burn Rate:

- Entregas totales de la ventana: Se observan 20 entregas de eventos.

- Entregas con latencia $\geq 2.5\ s$: Dentro del escenario catastrófico, se midió que todas las entregas de la ventana llegan tardías (100%).

- Margen del SLO: 5%.

Nota: Este escenario corresponde al de máxima severidad.

$$
\text{Burn Rate} = \frac{\text{Proporción de entregas lentas}}{\text{Margen del SLO}}
$$

$$
= \frac{20/20}{0{,}05} = \frac{1}{0{,}05} = 20
$$

\*La anterior estimación del impacto para este escenario se calcula directamente sobre datos medidos en un ensayo real de inyección de fallas, extrapolando el ritmo de quema observado al período completo de evaluación del SLO (30 días).

**Estimado del Error Budget**

Teniendo en cuenta el Burn Rate medido (20x), el presupuesto de error mensual (30 días)

$$
\text{Error Budget (\%)} = 100\% - \mathrm{SLO}_{\mathrm{Latencia}} = 100\% - 95\% = 5\%
$$

$$
\text{Error Budget (tiempo)} = \text{Error Budget (\%)} \times \text{Duración ventana SLO}
$$

$$
= 0{,}05 \times 30\ \text{días}\ (43\,200\ \text{min}) = 2\,160\ \text{min} \approx 1{,}5\ \text{días}
$$

Es decir que, en 30 días se permite un día y 12 horas de entregas incumpliendo el umbral de 2.5 s, antes de agotar por completo el presupuesto.

### 4. Plan de contingencia y mitigación

Para atender este incidente se tomará como referencia el procedimiento establecido en el Runbook INC-002 - Degradación de la latencia de entrega, incorporando nuevas consideraciones para el diagnóstico de una degradación de red hacia RabbitMQ.

| Etapa | Acción |
|---|---|
| Detección | Alerta `ZulipEventDeliveryLatencyBurnRateHigh` en estado Firing; burn rate confirmado en 20× vía Grafana/Prometheus (pasos 1-2 del Runbook). |
| Diagnóstico | Verificación de consumo de recursos y estado de colas (pasos 3-4 del Runbook): CPU/memoria normales, colas de RabbitMQ sin backlog → se descarta saturación. Se hace un diagnóstico de la conexión de red hacia RabbitMQ, aislando la causa al tramo degradado. |
| Mitigación | Reconectar la conexión del tramo de red degradado — `kubectl set env deployment/zulip SETTING_RABBITMQ_HOST=rabbitmq`. |
| Recuperación | Pod vuelve a Ready en 1 minuto 39 segundos (medido); latencia de entrega regresa a ~0,1–0,2 s. |
| Validación | Burn rate vuelve a bajar de 5× en Grafana; estado de la alerta pasa de Firing a Normal (pasos 5-6 del Runbook). |

Se tiene en cuenta que las alertas basadas en ventanas de tiempo pueden continuar reflejando la degradación anterior aun cuando el servicio ya se haya recuperado, por lo tanto, es importante validar el indicador de Burn Rate, como el funcionamiento real observado (latencia medida).

### 5. Controles y acciones de mejora

Con base en el análisis, se proponen las siguientes medidas para reducir la probabilidad de ocurrencia del incidente, facilitar su identificación y mejorar la capacidad de recuperación.

#### a) Medidas preventivas

Se busca reducir el riesgo de que la conexión de red hacia RabbitMQ se degrade y afecte la operación de Zulip.

| **Acción propuesta**                                                                                                                | **Estado** |
|-------------------------------------------------------------------------------------------------------------------------------------|------------|
| Evaluar afinidad de Pods (podAffinity) entre Zulip y RabbitMQ, para reducir saltos de red.                                          | Propuesto  |
| Habilitar rutas de red redundantes con failover automático hacia RabbitMQ                                                           | Propuesto  |
| Realizar pruebas periódicas de degradación de red (no solo de caída total), como parte de un programa continuo de chaos engineering | Propuesto  |

#### b) Medidas detectivas

Permiten identificar oportunamente la degradación de la conexión de red y conocer el impacto generado sobre la entrega de eventos.

| **Acción**                                                           | **Mecanismo de detección**                                                     | **Estado**   |
|----------------------------------------------------------------------|--------------------------------------------------------------------------------|--------------|
| Monitorear la latencia de entrega de eventos                         | SLI de P95 mediante Prometheus y Grafana                                       | Implementado |
| Identificar el consumo acelerado del Error Budget                    | Alerta de Burn Rate de latencia $<5x$                                         | Implementado |
| Detectar saturación de cómputo (CPU/memoria) por componente          | Panel dedicado en el dashboard                                                 | Implementado |
| Detectar degradación específica de la conexión de red hacia RabbitMQ | Métrica dedicada de latencia de conexión AMQP[^1], separada del procesamiento. | Propuesto    |

#### c) Medidas correctivas y de recuperación

Buscan reducir el tiempo de degradación, restablecer el funcionamiento de Zulip y evitar que una falla similar se presente nuevamente.

| **Acción propuesta**                                                                                                                                             | **Objetivo**                                                                                                                 |
|------------------------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------|
| Actualizar el Runbook INC-002 a medida de que se identifiquen más escenarios de posibles fallos de red (a partir de los diagnósticos y mitigaciones realizadas). | Que el procedimiento de respuesta esté completo ante un modo de falla similar, no sólo ante casos de saturación de recursos. |
| Automatizar la verificación de la NetworkPolicy antes de cada ejercicio de despliegue.                                                                           | Evitar que la mitigación de reconexión directa falle por una política de red desactualizada.                                 |
| Evaluar timeouts y reintentos del cliente AMQP (Pika) ante conexiones degradadas.                                                                                | Evitar que la degradación se agrave por reconexiones agresivas durante el incidente.                                         |


