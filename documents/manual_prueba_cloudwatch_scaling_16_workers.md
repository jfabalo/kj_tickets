# Manual de prueba CloudWatch - Autoscaling max 16 workers

Objetivo: preparar AWS Console/CloudWatch antes de lanzar la prueba, ejecutar una carga larga de unas 6000 requests y poder enseñar al profesor como el autoscaler cambia el numero de workers segun backlog y tasa de llegada.

Configuracion recomendada:

```text
max_workers = 16
requests aproximadas = 6000
perfil = Z(t)
modo = numbered
distribucion = uniform
workers iniciales = 1
scaler = 1
```

Usamos `min_workers=1` para evitar cold start fuerte al principio. Asi siempre hay un worker conectado a RabbitMQ y la demo empieza mas limpia.

## 1. Cargar credenciales AWS Academy

Desde PowerShell, en la raiz del proyecto:

```powershell
Set-ExecutionPolicy Bypass -Scope Process
. .\scripts\set-academy-env.ps1 -CredentialsFile .\aws-academy-credentials.txt
aws sts get-caller-identity
```

Comprueba que responde con la cuenta de AWS Academy.

## 2. Calcular IP publica del operador

```powershell
$ip = (Invoke-RestMethod https://checkip.amazonaws.com).Trim()
$cidr = "$ip/32"
$cidr
```

Este `$cidr` se usa para abrir acceso de mantenimiento a RabbitMQ/PostgreSQL solo desde tu IP.

## 3. Desplegar infraestructura con max_workers=16

Si has cambiado codigo Docker/Python:

```powershell
.\scripts\deploy.ps1 -OperatorCidr $cidr -WorkerDesiredCount 1 -ScalerDesiredCount 0 -MaxWorkers 16
```

Si no has cambiado codigo y las imagenes ya estan en ECR:

```powershell
.\scripts\deploy.ps1 -OperatorCidr $cidr -WorkerDesiredCount 1 -ScalerDesiredCount 0 -MaxWorkers 16 -SkipDockerBuild
```

Esto deja:

```text
worker service creado con 1 worker
scaler service creado pero apagado
RabbitMQ/PostgreSQL/ECR/SQS/CloudWatch creados
```

## 4. Abrir AWS Console antes de lanzar carga

Abre estas pestanas antes de ejecutar el loadgen.

### Pestana 1: ECS worker service

Ruta:

```text
AWS Console -> ECS -> Clusters -> ticket-service-academy-worker -> Services -> ticket-service-academy-worker
```

Aqui ensenas:

```text
Desired tasks
Running tasks
Pending tasks
Events
```

Esta es la vista mas clara para ver workers subiendo y bajando.

### Pestana 2: ECS scaler service

Ruta:

```text
AWS Console -> ECS -> Clusters -> ticket-service-academy-worker -> Services -> ticket-service-academy-scaler
```

Aqui ensenas que el autoscaler corre como servicio ECS/Fargate.

### Pestana 3: CloudWatch Logs del scaler

Ruta:

```text
CloudWatch -> Log groups -> /ecs/ticket-service-academy-scaler
```

Importante: cada vez que apagas/enciendes el scaler se crea un log stream nuevo. Entra siempre en el stream con `Last event time` mas reciente.

Lineas esperadas:

```text
scaler_started ...
scaling_decision reason=...
updated_ecs_service desired=...
```

### Pestana 4: CloudWatch Logs del worker

Ruta:

```text
CloudWatch -> Log groups -> /ecs/ticket-service-academy-worker
```

Lineas esperadas:

```text
processed request_id=... result=sold attempt=1
```

Si ves `ConnectionTimeout` contra PostgreSQL bajo carga, explicalo como fallo transitorio recuperado por retry. No implica overselling.

### Pestana 5: CloudWatch Logs del loadgen

Ruta:

```text
CloudWatch -> Log groups -> /ecs/ticket-service-academy-loadgen
```

Aqui se ve que la task temporal publica mensajes.

## 5. Preparar Logs Insights del scaler

Ruta:

```text
CloudWatch -> Logs Insights
```

Selecciona:

```text
/ecs/ticket-service-academy-scaler
```

Query simple para ver decisiones recientes:

```sql
fields @timestamp, @logStream, @message
| filter @message like /scaling_decision/
| sort @timestamp desc
| limit 100
```

Query parseada para explicar cada decision:

```sql
fields @timestamp, @logStream, @message
| filter @message like /scaling_decision/
| parse @message "scaling_decision reason=* current=* desired=* target=* lambda=* ready=* unacked=* total=* consumers=* by_lambda=* by_backlog=*" as reason, current, desired, target, lambda, ready, unacked, total, consumers, by_lambda, by_backlog
| display @timestamp, reason, current, desired, target, lambda, ready, unacked, total, consumers, by_lambda, by_backlog, @logStream
| sort @timestamp desc
| limit 100
```

Query agregada por ventanas de 30 segundos:

```sql
fields @timestamp, @message
| filter @message like /scaling_decision/
| parse @message "scaling_decision reason=* current=* desired=* target=* lambda=* ready=* unacked=* total=* consumers=* by_lambda=* by_backlog=*" as reason, current, desired, target, lambda, ready, unacked, total, consumers, by_lambda, by_backlog
| stats max(desired) as desired_workers,
        max(target) as target_workers,
        max(ready) as rabbitmq_ready,
        max(lambda) as arrival_rate
  by bin(30s)
```

Si CloudWatch no muestra grafica, usa la pestana `Table`. La grafica visual de workers se ve mejor en ECS.

## 6. Limpiar estado antes de la prueba

```powershell
.\scripts\clean-test-state.ps1
```

Esto limpia:

```text
RabbitMQ tickets.buy
PostgreSQL requests/sales/experiment_runs/seats/ticket_pools
SQS DLQ
```

## 7. Encender scaler y dejar 1 worker inicial

```powershell
.\scripts\set-workers-fast.ps1 -DesiredCount 1
.\scripts\set-scaler-fast.ps1 -DesiredCount 1
```

Espera 20-30 segundos y revisa CloudWatch Logs del scaler. Deberias ver algo parecido a:

```text
scaling_decision reason=steady current=1 desired=1 target=1 lambda=0.00 ready=0 ...
```

Eso es correcto: no hay carga, pero `min_workers=1`.

## 8. Preparar monitor local de scaling

Abre otra terminal PowerShell, carga credenciales si hace falta:

```powershell
Set-ExecutionPolicy Bypass -Scope Process
. .\scripts\set-academy-env.ps1 -CredentialsFile .\aws-academy-credentials.txt
```

No lo ejecutes todavia si quieres sincronizarlo con el inicio de la prueba. Lo lanzaremos justo antes del loadgen.

## 9. Lanzar prueba Z(t) de unas 6000 requests

Esta prueba genera aproximadamente 6000 mensajes:

```text
low:       10 req/s * 30s = 300
ramp-up:   60 req/s * 40s = 2400
spike:    140 req/s * 10s = 1400
high:      55 req/s * 30s = 1650
cooldown:  10 req/s * 30s = 300
total aproximado = 6050 requests
```

Primero prepara el `runId`:

```powershell
$runId = [guid]::NewGuid().ToString()
$runId
```

En la segunda terminal, empieza a monitorizar:

```powershell
.\scripts\monitor-scaling.ps1 `
  -RunId $runId `
  -RunName "profesor-scaling-16w-6k" `
  -DurationSeconds 420 `
  -PollSeconds 5
```

En la primera terminal, lanza el loadgen:

```powershell
.\scripts\run-loadgen-aws.ps1 `
  -Profile z `
  -Mode numbered `
  -Distribution uniform `
  -RunName "profesor-scaling-16w-6k" `
  -RunId $runId `
  -ZLowRate 10 `
  -ZRampRate 60 `
  -ZSpikeRate 140 `
  -ZHighRate 55 `
  -ZLowSeconds 30 `
  -ZRampSeconds 40 `
  -ZSpikeSeconds 10 `
  -ZHighSeconds 30 `
  -ZCooldownSeconds 30 `
  -ReportEvery 500
```

Durante la ejecucion, refresca:

```text
ECS worker service
CloudWatch Logs scaler
Logs Insights query parseada
CloudWatch Logs worker
```

## 10. Que deberia verse

En scaler logs:

```text
reason=scale_up
current=1 desired=...
lambda=...
ready=...
by_lambda=...
by_backlog=...
```

En ECS worker service:

```text
Desired tasks sube
Pending tasks aparece mientras Fargate arranca
Running tasks sube despues
```

Cuando baja la carga:

```text
reason=scale_down_cooldown
reason=scale_down
desired baja poco a poco
```

En worker logs:

```text
processed request_id=... result=sold attempt=1
```

Puede haber algun:

```text
transient processing error
ConnectionTimeout
republished retry attempt=2
```

Eso significa que PostgreSQL tardo demasiado o rechazo conexiones puntuales. El sistema lo trata como error transitorio y reintenta.

## 11. Esperar a que acaben las requests

Cuando el loadgen termine, los workers pueden seguir drenando RabbitMQ. Espera a PostgreSQL:

```powershell
.\scripts\wait-run-complete.ps1 `
  -RunId $runId `
  -ExpectedRequests 6050 `
  -TimeoutSeconds 1800 `
  -PollSeconds 10
```

Si por redondeo el numero real cambia, mira el JSON del loadgen:

```powershell
Get-ChildItem report\loadgen_runs -Filter "*$($runId.Substring(0,8))*" | Get-Content
```

Usa el campo:

```text
requested_messages
```

## 12. Recoger resultados

```powershell
.\scripts\collect-run-results.ps1 `
  -RunId $runId `
  -RunName "profesor-scaling-16w-6k"
```

Archivos esperados:

```text
report/results/summary-profesor-scaling-16w-6k-<id>.csv
report/results/latencies-profesor-scaling-16w-6k-<id>.csv
report/results/scaling-timeseries-profesor-scaling-16w-6k-<id>.csv
report/loadgen_runs/loadgen-profesor-scaling-16w-6k-uniform-n-<id>.json
```

## 13. Comprobacion rapida final

```powershell
.\scripts\observe.ps1 -LogLimit 30
```

Revisa:

```text
RabbitMQ ready = 0
RabbitMQ unacked = 0
PostgreSQL completed cerca de 6050
SQS DLQ = 0 o bajo
```

## 14. Apagar para ahorrar

Al terminar la demo:

```powershell
.\scripts\set-scaler-fast.ps1 -DesiredCount 0 -NoWait
.\scripts\set-workers-fast.ps1 -DesiredCount 0 -NoWait
```

Si ya no vas a seguir usando AWS:

```powershell
.\scripts\destroy.ps1 -OperatorCidr $cidr -MaxWorkers 16
```

## 15. Explicacion corta para el profesor

Frase recomendada:

```text
El autoscaler corre como un ECS Service. Cada pocos segundos consulta RabbitMQ
Management API para leer backlog y tasa de publicacion. Con esos datos calcula
workers_by_lambda = ceil(lambda / C) y workers_by_backlog = ceil(B / (Tr*C)).
Despues cambia desired_count del ECS Service de workers. ECS/Fargate arranca o
para tasks. CloudWatch muestra la decision del scaler y ECS muestra el numero
real de workers deseados, pendientes y corriendo.
```

Si pregunta por `min_workers=1`:

```text
Mantenemos 1 worker minimo para evitar cold start fuerte. Si fuese 0, ahorrariamos
mas en reposo, pero la primera carga esperaria a que el scaler detecte backlog y
Fargate arranque workers.
```

Si pregunta por errores transitorios:

```text
Un timeout contra PostgreSQL bajo carga no pierde mensajes. El worker no hace ack
hasta completar la transaccion. Si falla, republica el mensaje con x-attempt+1.
Como request_id es unico, PostgreSQL mantiene idempotencia y evita duplicar ventas.
Si se agotan los intentos, el mensaje va a SQS DLQ.
```
