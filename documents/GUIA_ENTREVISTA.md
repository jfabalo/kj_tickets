# Guia manual para despliegue y pruebas en entrevista

Esta guia es para demostrar la practica en directo sin depender de Codex. La idea es desplegar, ejecutar una prueba pequena, ensenar observabilidad, probar autoscaling si hace falta y destruir todo al terminar.

## 1. Requisitos locales

Antes de empezar, comprueba que existen estas herramientas:

```powershell
aws --version
terraform version
docker version
py --version
```

Tambien debe estar Docker Desktop encendido, porque `deploy.ps1` construye y sube las imagenes Docker a ECR.

## 2. Credenciales AWS Academy

Crea un archivo local llamado `aws-academy-credentials.txt` en la raiz del proyecto. No se entrega y esta ignorado por `.gitignore`.

Formato valido:

```text
AWS_ACCESS_KEY_ID=
AWS_SECRET_ACCESS_KEY=
AWS_SESSION_TOKEN=
```

Carga las credenciales en la terminal actual:

```powershell
Set-ExecutionPolicy Bypass -Scope Process
. .\scripts\set-academy-env.ps1 -CredentialsFile .\aws-academy-credentials.txt
aws sts get-caller-identity
```

Si `aws sts get-caller-identity` devuelve el ARN de `voclabs`, la sesion esta bien.

## 3. Obtener tu IP publica

Terraform limita el acceso externo a RabbitMQ/PostgreSQL a tu IP. Calcula el CIDR asi:

```powershell
$ip = (Invoke-RestMethod https://checkip.amazonaws.com).Trim()
$cidr = "$ip/32"
$cidr
```

Usa `$cidr` en los comandos de despliegue y destruccion.

## 4. Preparar entorno Python local

Solo hace falta para scripts que consultan PostgreSQL y generan CSV/graficas.

```powershell
py -3 -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r app\loadgen\requirements.txt -r report\requirements.txt
```

## 5. Desplegar en AWS

Despliegue completo con workers y scaler apagados inicialmente:

```powershell
.\scripts\deploy.ps1 -OperatorCidr $cidr -WorkerDesiredCount 0 -ScalerDesiredCount 0 -MaxWorkers 8
```

Que crea:

- EC2 RabbitMQ.
- EC2 PostgreSQL.
- ECR para imagenes.
- ECS cluster.
- ECS service de workers.
- ECS service del autoscaler.
- ECS task definition del loadgen.
- SQS DLQ.
- CloudWatch Logs.

Si ya has desplegado antes y no has cambiado codigo Python/Docker, puedes ahorrar tiempo:

```powershell
.\scripts\deploy.ps1 -OperatorCidr $cidr -WorkerDesiredCount 0 -ScalerDesiredCount 0 -MaxWorkers 8 -SkipDockerBuild
```

## 6. Prueba minima de funcionamiento

Arranca un worker:

```powershell
.\scripts\set-workers-fast.ps1 -DesiredCount 1
```

Lanza un loadgen pequeno desde AWS/ECS:

```powershell
.\scripts\run-loadgen-aws.ps1 -Profile constant -Mode numbered -Distribution uniform -Requests 5 -Rate 2 -ReportEvery 1 -RunName "entrevista-smoke"
```

El script imprimira un `RunId`. Guardalo en una variable:

```powershell
$runId = "<pega-aqui-el-run-id>"
```

Espera a que PostgreSQL marque las 5 requests como terminadas:

```powershell
.\scripts\wait-run-complete.ps1 -RunId $runId -ExpectedRequests 5 -TimeoutSeconds 180 -PollSeconds 5
```

Observa estado general:

```powershell
.\scripts\observe.ps1 -LogLimit 20
```

Resultado esperado:

- `requests=5`.
- `completed=5`.
- `errored=0`.
- RabbitMQ con `messages=0`.
- SQS DLQ con `0` mensajes.
- Logs del worker con `result=sold`.

## 7. Prueba corta de autoscaling

Para demostrar autoscaling, deja el worker service en 0 y enciende el scaler:

```powershell
.\scripts\set-workers-fast.ps1 -DesiredCount 0 -NoWait
.\scripts\set-scaler-fast.ps1 -DesiredCount 1
```

Ejecuta un perfil Z(t) pequeno, que sube y baja la carga:

```powershell
.\scripts\run-loadgen-aws.ps1 `
  -Profile z `
  -Mode numbered `
  -Distribution uniform `
  -ZLowRate 5 `
  -ZRampRate 20 `
  -ZSpikeRate 50 `
  -ZHighRate 25 `
  -ZLowSeconds 10 `
  -ZRampSeconds 20 `
  -ZSpikeSeconds 8 `
  -ZHighSeconds 20 `
  -ZCooldownSeconds 10 `
  -RunName "entrevista-scaling"
```

Mientras corre, monitoriza backlog y workers:

```powershell
.\scripts\monitor-scaling.ps1 -RunName "entrevista-scaling" -DurationSeconds 120 -PollSeconds 5
```

Explicacion para la entrevista:

- RabbitMQ acumula backlog cuando entran mas compras de las que los workers procesan.
- El autoscaler lee backlog y tasas de RabbitMQ.
- El autoscaler modifica `desired_count` del servicio ECS de workers.
- ECS/Fargate arranca mas workers.
- PostgreSQL mantiene la consistencia de ventas con transacciones.

## 8. Recoger resultados si el profesor los pide

Si quieres guardar CSV de la prueba:

```powershell
.\scripts\collect-run-results.ps1 -RunId $runId -RunName "entrevista-smoke"
```

Archivos generados:

- `report/results/summary-...csv`
- `report/results/latencies-...csv`

Para regenerar graficas del informe:

```powershell
.\.venv\Scripts\python.exe report\generate_figures.py
.\.venv\Scripts\python.exe report\generate_figures_max32.py
.\.venv\Scripts\python.exe report\generate_completion_comparison.py
```

## 9. Limpieza entre pruebas

Antes de comparar experimentos, limpia estado:

```powershell
.\scripts\clean-test-state.ps1
```

Esto limpia:

- Cola `tickets.buy` de RabbitMQ.
- Tablas de estado de PostgreSQL.
- SQS DLQ.

## 10. Parar servicios sin destruir todo

Si quieres pausar gasto de Fargate pero dejar EC2 RabbitMQ/PostgreSQL vivos:

```powershell
.\scripts\set-scaler-fast.ps1 -DesiredCount 0 -NoWait
.\scripts\set-workers-fast.ps1 -DesiredCount 0 -NoWait
```

Comprueba:

```powershell
aws ecs describe-services `
  --cluster ticket-service-academy-worker `
  --services ticket-service-academy-worker ticket-service-academy-scaler `
  --query "services[].{name:serviceName,desired:desiredCount,running:runningCount,pending:pendingCount,status:status}" `
  --output table
```

Debe salir `desired=0` y `running=0` en worker y scaler.

## 11. Destruir todo al terminar

Al acabar la entrevista, destruye la infraestructura completa:

```powershell
.\scripts\destroy.ps1 -OperatorCidr $cidr -MaxWorkers 8
```

Verificacion rapida:

```powershell
aws ec2 describe-instances `
  --filters "Name=tag:Project,Values=ticket-service" "Name=instance-state-name,Values=pending,running,stopping,stopped" `
  --query "Reservations[].Instances[].{id:InstanceId,state:State.Name,name:Tags[?Key=='Name']|[0].Value}" `
  --output table

aws ecs list-clusters --query "clusterArns[?contains(@, 'ticket-service')]" --output table
aws ecr describe-repositories --query "repositories[?starts_with(repositoryName, 'ticket-service')].repositoryName" --output table
aws sqs list-queues --queue-name-prefix ticket-service --query "QueueUrls" --output table
```

Si no imprime recursos del proyecto, esta limpio.

## 12. Limpieza local antes de entregar

No entregues secretos ni artefactos locales:

```powershell
Remove-Item .\aws-academy-credentials.txt -Force -ErrorAction SilentlyContinue
Remove-Item .\.venv -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item .\infra\terraform\.terraform -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item .\infra\terraform\terraform.tfstate -Force -ErrorAction SilentlyContinue
Remove-Item .\infra\terraform\terraform.tfstate.backup -Force -ErrorAction SilentlyContinue
```

## 13. Frases clave para defenderlo

- El loadgen no corre en local: se ejecuta como task ECS/Fargate dentro de AWS para evitar medir latencias de la red domestica.
- RabbitMQ desacopla entrada de compras y procesamiento, y permite medir backlog.
- PostgreSQL es la fuente de verdad y evita overselling mediante transacciones.
- Los workers son stateless: se pueden escalar horizontalmente sin coordinar estado local.
- El autoscaler mira RabbitMQ y ajusta `desired_count` de ECS.
- La DLQ de SQS recoge fallos definitivos para no perderlos silenciosamente.
- El sistema prioriza consistencia de ventas sobre vender mas rapido a cualquier coste.
