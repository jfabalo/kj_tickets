# Diario de Pitagoras - Practica Ticket Service

Fecha de inicio: 2026-06-07
Entorno objetivo: AWS Academy, cuenta `065586234233`, region `us-east-1`

Este diario documenta que se hace, como se implementa, por que se toma cada decision y con que conecta cada paso. La idea es poder usarlo despues para explicar la practica en una entrevista o defensa tecnica.

## 2026-06-07 - Lectura del enunciado y plan inicial

### Que se hizo

- Se leyo `documents/enunciado.txt`.
- Se reviso la informacion disponible sobre AWS Academy.
- Se extrajeron ideas utiles de la teoria de Sistemas Distribuidos: comunicacion indirecta, asincronia, stateless services, consistencia, transacciones ACID, tolerancia a fallos y escalabilidad.
- Se creo el plan detallado en `documents/plan_practica_terraform_aws_academy.md`.

### Por que

El enunciado pide cumplir requisitos bastante concretos:

- Procesamiento asincrono obligatorio.
- RabbitMQ en EC2 como cola principal.
- Workers stateless con Lambda o Fargate.
- PostgreSQL o MySQL en EC2.
- Correccion bajo concurrencia.
- Escalado dinamico.
- Medicion real por transacciones completadas.
- Fault tolerance con idempotencia, retries, at-least-once y SQS DLQ.

La decision fue orientar todo a Terraform y AWS Academy desde el principio para evitar desviarse hacia soluciones que luego no podamos desplegar por permisos o presupuesto.

### Decision tecnica

Arquitectura elegida:

```text
Load generator -> RabbitMQ EC2 -> ECS Fargate workers -> PostgreSQL EC2
                                      |
                                      v
                                  SQS DLQ
```

### Como conecta

- `Load generator` publica mensajes de compra.
- `RabbitMQ` desacopla productores y consumidores y suaviza picos de carga.
- `Fargate workers` consumen mensajes, aplican el retardo artificial de 100 ms y ejecutan la transaccion de compra.
- `PostgreSQL` actua como fuente de verdad para impedir overselling.
- `SQS DLQ` recibe mensajes fallidos de forma definitiva.
- `Terraform` crea y destruye la infraestructura de forma reproducible.

### Punto defendible en entrevista

La cola no garantiza exactly-once. Por eso el diseno combina entrega at-least-once con idempotencia por `request_id` y constraints/transacciones en PostgreSQL. La correccion no depende de que RabbitMQ entregue una sola vez.

## 2026-06-07 - Preparacion local y credenciales AWS Academy

### Que se hizo

- Se comprobo que estaban disponibles AWS CLI, Docker, Git y Python en `.venv`.
- Se detecto que Terraform no estaba inicialmente en PATH, pero despues quedo instalado como `Terraform v1.15.5`.
- Se creo `scripts/set-academy-env.ps1`.
- Se creo `aws-academy-credentials.txt` como plantilla local para credenciales temporales.
- Se creo `.gitignore` para no versionar credenciales, estados Terraform ni entornos locales.

### Como se implemento

El script `scripts/set-academy-env.ps1` acepta credenciales de AWS Academy en varios formatos:

```bash
export AWS_ACCESS_KEY_ID=...
export AWS_SECRET_ACCESS_KEY=...
export AWS_SESSION_TOKEN=...
```

Y las carga en la sesion actual de PowerShell como variables de entorno:

```powershell
Set-ExecutionPolicy Bypass -Scope Process; . .\scripts\set-academy-env.ps1 -CredentialsFile .\aws-academy-credentials.txt
```

Tambien valida con:

```powershell
aws sts get-caller-identity
```

### Por que

AWS Academy usa credenciales temporales. No conviene guardarlas en perfiles globales ni versionarlas. El script reduce errores al renovar credenciales y nos permite ejecutar AWS CLI, Terraform y Docker/ECR desde la misma terminal.

### Resultado

La identidad validada fue:

```text
Account: 065586234233
Arn: arn:aws:sts::065586234233:assumed-role/voclabs/user5144451=jfuentes
Region: us-east-1
```

### Como conecta

Este paso es prerequisito de todos los demas:

- Terraform necesita credenciales para crear infraestructura.
- Docker necesita autenticarse contra ECR.
- AWS CLI se usa para verificar recursos y limpiar si algo falla.

### Punto defendible en entrevista

Las credenciales se tratan como secreto local y temporal. El repositorio contiene una plantilla vacia, no credenciales reales.

## 2026-06-07 - Estructura base del repositorio

### Que se hizo

Se creo la estructura inicial:

```text
infra/terraform/
app/worker/
app/loadgen/
app/scaler/
app/common/
app/smoke-worker/
scripts/
report/
documents/
```

Archivos principales creados:

- `README.md`
- `.env.example`
- `infra/terraform/versions.tf`
- `infra/terraform/providers.tf`
- `infra/terraform/variables.tf`
- `infra/terraform/main.tf`
- `infra/terraform/outputs.tf`
- `infra/terraform/terraform.tfvars.example`
- `report/final_report.md`
- `scripts/deploy.ps1`
- `scripts/destroy.ps1`

### Como se implemento

Terraform se dejo inicialmente con:

- Provider AWS en `us-east-1`.
- Lectura de cuenta actual.
- Lectura de region actual.
- Lectura de VPC default.
- Lectura de subnets default.

No se crearon recursos reales en este paso.

### Por que

La estructura separa responsabilidades:

- `infra/terraform`: infraestructura.
- `app/worker`: consumidor real de RabbitMQ.
- `app/loadgen`: generador de carga para experimentos.
- `app/scaler`: logica de escalado dinamico.
- `report`: informe final y graficas.
- `scripts`: automatizacion de despliegue, limpieza y credenciales.

### Validacion

Se ejecuto:

```powershell
terraform init
terraform validate
```

Resultado:

```text
Terraform initialized successfully
Success! The configuration is valid.
```

### Como conecta

Esta base permite evolucionar por hitos sin mezclar codigo de aplicacion con infraestructura. Tambien deja preparado el reporte desde el inicio para no reconstruir decisiones al final.

### Punto defendible en entrevista

Se trabajo incrementalmente: primero estructura y validacion sintactica, antes de crear recursos cloud. Esto reduce coste y riesgo en una cuenta con presupuesto limitado.

## 2026-06-07 - Smoke test Terraform + SQS

### Que se hizo

Se probo que Terraform puede crear y destruir un recurso barato en AWS Academy.

Recurso temporal:

- Cola SQS `ticket-service-academy-smoke-065586234233`.

### Como se implemento

Se creo `infra/terraform/smoke.tf` con una cola SQS condicional:

```hcl
resource "aws_sqs_queue" "smoke_test" {
  count = var.enable_smoke_test ? 1 : 0

  name                      = "${var.project_name}-${var.environment}-smoke-${data.aws_caller_identity.current.account_id}"
  message_retention_seconds = 3600
  sqs_managed_sse_enabled   = true
}
```

Se anadio la variable:

```hcl
variable "enable_smoke_test" {
  type    = bool
  default = false
}
```

### Por que

SQS es barato y rapido de crear. Es una buena prueba para validar:

- Credenciales.
- Provider AWS.
- Permisos Terraform.
- Creacion/destruccion de recursos.
- Lectura de VPC/subnets default.

### Resultado

Terraform pudo leer:

```text
Account: 065586234233
Region: us-east-1
Default VPC: vpc-0b379683405b06ceb
Default subnets: 6 subnets
```

Terraform creo la cola, AWS CLI la listo correctamente y despues se destruyo.

### Limpieza

Se ejecuto `terraform destroy` y se verifico:

- La cola ya no aparecia con `aws sqs list-queues`.
- `terraform state list` quedo vacio.

### Como conecta

SQS sera necesario mas adelante como DLQ. Este smoke test valida que podremos crear esa parte obligatoria del enunciado.

### Punto defendible en entrevista

Se desactivo por defecto con `enable_smoke_test=false` para evitar que una ejecucion normal de Terraform cree recursos temporales sin querer.

## 2026-06-07 - Smoke test ECR + ECS Fargate

### Que se hizo

Se valido el punto con mas riesgo de permisos en AWS Academy: contenedores en ECS Fargate usando imagen en ECR.

Recursos temporales creados:

- ECR repository `ticket-service-academy-fargate-smoke`.
- ECS cluster `ticket-service-academy-fargate-smoke`.
- ECS task definition Fargate.
- ECS service con `desired_count = 1`.
- Security group sin inbound y egress abierto.
- CloudWatch log group `/ecs/ticket-service-academy-fargate-smoke`.

### Como se implemento

Se creo `infra/terraform/fargate_smoke.tf` con recursos condicionales:

```hcl
variable "enable_fargate_smoke_test" {
  type    = bool
  default = false
}

variable "enable_fargate_smoke_service" {
  type    = bool
  default = false
}
```

Se uso `LabRole` como `execution_role_arn` y `task_role_arn`:

```hcl
data "aws_iam_role" "lab_role" {
  name = "LabRole"
}
```

Se creo una imagen minima en `app/smoke-worker`:

- `Dockerfile`
- `smoke_worker.py`

El contenedor imprime logs cada 15 segundos para comprobar que realmente arranca.

### Por que

El proyecto final depende de Fargate para workers stateless. Antes de implementar RabbitMQ/PostgreSQL era necesario comprobar:

- Terraform puede crear ECS cluster/service.
- Fargate puede arrancar tasks.
- `LabRole` sirve para execution role.
- ECR acepta push/pull.
- CloudWatch Logs recibe logs.
- Subnets publicas con `assign_public_ip = true` funcionan sin NAT Gateway.

Esto evita construir toda la aplicacion y descubrir tarde que Fargate no esta permitido.

### Problema encontrado

El login Docker con pipe fallo en PowerShell:

```powershell
aws ecr get-login-password | docker login --username AWS --password-stdin ...
```

Errores observados:

```text
login failed with status: 400 Bad Request
403 Forbidden en push inicial
```

### Solucion

Se uso password en variable:

```powershell
$pass = aws ecr get-login-password --region us-east-1
docker login --username AWS --password $pass 065586234233.dkr.ecr.us-east-1.amazonaws.com
```

Con eso el login y push funcionaron.

### Resultado

El service alcanzo steady state:

```text
desired: 1
running: 1
pending: 0
status: ACTIVE
```

La task quedo:

```text
lastStatus: RUNNING
desiredStatus: RUNNING
container: smoke-worker RUNNING
```

Logs comprobados:

```text
smoke-worker started env=academy
smoke-worker heartbeat
```

### Limpieza

Se ejecuto `terraform destroy` con las variables del smoke test activas y se destruyeron 6 recursos.

Despues se verifico con AWS CLI:

- No queda cluster ECS de smoke.
- No queda repo ECR de smoke.
- No queda log group de smoke.
- No queda security group de smoke.
- No queda task definition activa.
- La task definition inactiva fue borrada con `aws ecs delete-task-definitions`.

### Como conecta

Este paso desbloquea la arquitectura final:

- Los workers reales podran ir en ECS Fargate.
- Las imagenes reales podran subirse a ECR.
- Los logs de workers podran verse en CloudWatch.
- La red con VPC default/subnets publicas es viable sin NAT Gateway.

### Punto defendible en entrevista

Se valido el componente mas incierto antes de desarrollar la aplicacion. La prueba fue barata, acotada y destruida inmediatamente para respetar el budget de AWS Academy.

## Estado actual de la practica

### Validado

- Credenciales AWS Academy cargadas y validadas.
- Terraform instalado y funcional.
- Docker funcional.
- AWS CLI funcional.
- Terraform puede crear/destruir SQS.
- Terraform puede crear/destruir ECR.
- Docker puede subir imagen a ECR.
- Terraform puede crear/destruir ECS Fargate.
- Fargate puede ejecutar una task usando `LabRole`.
- CloudWatch Logs funciona para containers.

### Recursos cloud activos del proyecto

No deberia quedar ningun recurso activo creado por las pruebas.

### Siguiente paso tecnico

Construir infraestructura base real:

1. Modulo de red/security groups.
2. EC2 RabbitMQ.
3. EC2 PostgreSQL.
4. SQS DLQ real.
5. ECR real del worker.
6. ECS worker service real.

### Decision pendiente

Definir si reutilizamos el ECR existente `ticket-worker` o si Terraform gestiona un repositorio nuevo para el worker real. Recomendacion provisional: usar Terraform para gestionar un repo propio del proyecto, con `force_delete` durante desarrollo y limpieza controlada.

## 2026-06-07 - Infraestructura base real: RabbitMQ, PostgreSQL, SQS DLQ y ECR

### Que se hizo

Se implemento la infraestructura base real en Terraform, controlada por `enable_core_infra=false` para que no se cree coste por accidente.

Archivo principal creado:

- `infra/terraform/core_infra.tf`

Recursos definidos:

- EC2 RabbitMQ con Docker.
- EC2 PostgreSQL con Docker.
- Security group de workers.
- Security group de RabbitMQ.
- Security group de PostgreSQL.
- SQS DLQ `ticket-service-academy-ticket-failures-dlq`.
- ECR repo `ticket-service-worker`.
- Passwords aleatorias para RabbitMQ y PostgreSQL usando Terraform `random_password`.

### Como se implemento

RabbitMQ se levanta en Amazon Linux 2023 con Docker y la imagen `rabbitmq:3-management`.

Puertos:

```text
5672  -> AMQP
15672 -> RabbitMQ Management UI
```

PostgreSQL se levanta con Docker y la imagen `postgres:16-alpine`.

Puerto:

```text
5432 -> PostgreSQL
```

La base de datos se inicializa con tablas para:

- `experiment_runs`
- `ticket_pools`
- `seats`
- `requests`
- `sales`

Tambien se insertan:

```text
100000 seats
1 ticket pool principal con 100000 tickets
```

RabbitMQ queda preparado para la aplicacion con:

```text
exchange: tickets.exchange
type: direct
queue: tickets.buy
routing_key: ticket.buy
```

### Por que

El enunciado exige RabbitMQ en EC2 y PostgreSQL/MySQL en EC2. Se eligio PostgreSQL por sus transacciones ACID, constraints y row-level locking, que son la base para impedir overselling bajo concurrencia.

Docker dentro de EC2 simplifica la instalacion:

- Evita instalar RabbitMQ/PostgreSQL manualmente paquete a paquete.
- Hace reproducible la version del servicio.
- Permite destruir y recrear rapido durante pruebas.

### Seguridad y red

Se uso la VPC default de AWS Academy para reducir complejidad y coste.

Security groups:

- Workers: sin inbound, egress abierto.
- RabbitMQ: AMQP desde workers y desde la IP del operador para load generator; UI solo desde la IP del operador.
- PostgreSQL: puerto 5432 desde workers y desde la IP del operador para depuracion/export de metricas.

La IP del operador usada en la prueba fue:

```text
86.127.229.77/32
```

No se habilito SSH por defecto. La validacion se hizo por puertos y APIs, no entrando en las maquinas.

### Prueba realizada

Se aplico Terraform con:

```powershell
terraform apply -auto-approve core.tfplan
```

Terraform creo 9 recursos:

```text
2 EC2 t3.micro
3 security groups
1 SQS DLQ
1 ECR repository
2 random_password
```

Outputs relevantes durante la prueba:

```text
RabbitMQ public IP: 52.207.252.215
RabbitMQ private IP: 172.31.83.242
PostgreSQL public IP: 184.72.121.184
PostgreSQL private IP: 172.31.88.152
DLQ URL: https://sqs.us-east-1.amazonaws.com/065586234233/ticket-service-academy-ticket-failures-dlq
Worker ECR: 065586234233.dkr.ecr.us-east-1.amazonaws.com/ticket-service-worker
```

### Validaciones

Puertos comprobados:

```text
RabbitMQ AMQP 5672: OK
RabbitMQ UI 15672: OK
PostgreSQL 5432: OK
```

RabbitMQ API:

```text
rabbitmq_version=3.13.7
```

PostgreSQL:

```sql
select (select count(*) from seats) as seats,
       (select count(*) from ticket_pools) as pools;
```

Resultado:

```text
seats = 100000
pools = 1
```

SQS DLQ:

```text
retention = 1209600 segundos
SSE = true
visible messages = 0
```

ECR:

```text
ticket-service-worker creado correctamente
```

### Limpieza

Como era una prueba de validacion y las EC2 consumen presupuesto, se destruyo todo al terminar:

```powershell
terraform destroy -auto-approve -var enable_core_infra=true -var operator_cidr=86.127.229.77/32
```

Se verifico despues:

- No quedan EC2 activas/paradas del proyecto.
- No quedan volumenes EBS sueltos del proyecto.
- No quedan security groups `ticket-service-academy-*`.
- No queda ECR `ticket-service-worker`.
- No queda SQS DLQ del proyecto.
- `terraform state list` queda vacio.

### Como conecta

Este hito deja lista la base donde se conectara el worker real:

- El worker consumira mensajes de RabbitMQ `tickets.buy`.
- El worker escribira transacciones en PostgreSQL.
- Los mensajes fallidos definitivos iran a SQS DLQ.
- La imagen del worker se subira al ECR `ticket-service-worker`.
- ECS Fargate usara el security group de workers para hablar con RabbitMQ y PostgreSQL por IP privada.

### Punto defendible en entrevista

La infraestructura valida el patron central del sistema: cola asincrona + workers stateless + base de datos transaccional. La correccion se delega a PostgreSQL, no a la cola. La cola permite elasticidad y desacoplamiento; la base de datos preserva los invariantes de negocio.

### Nota tecnica

Se modifico el user data de RabbitMQ para que en futuros despliegues cree automaticamente `tickets.exchange`, `tickets.buy` y el binding `ticket.buy`. En esta prueba concreta, el broker ya estaba levantado antes de ese ajuste, asi que la cola se creo tambien manualmente por API para validar el modelo.

## 2026-06-07 - Worker real: RabbitMQ -> PostgreSQL -> SQS DLQ

### Que se hizo

Se implemento el worker real en Python.

Archivos creados/modificados:

- `app/worker/src/worker.py`
- `app/worker/src/__init__.py`
- `app/worker/Dockerfile`
- `app/worker/requirements.txt`
- `.env.example`
- `documents/infraestructura_arquitectura.md`

### Como funciona

El worker consume mensajes desde RabbitMQ usando AMQP y manual ack.

Flujo:

1. Lee un mensaje de `tickets.buy`.
2. Decodifica JSON.
3. Valida `request_id`, `run_id`, `mode`, `seat_id` y `enqueued_at`.
4. Abre transaccion en PostgreSQL.
5. Crea el `experiment_run` si no existe.
6. Crea la fila `requests` si no existe.
7. Bloquea la request con `SELECT ... FOR UPDATE`.
8. Si ya esta completada, devuelve el resultado sin vender otra vez.
9. Marca `worker_started_at` e incrementa `attempts`.
10. Aplica el delay artificial de `100 ms`.
11. Ejecuta la venta numerada o no numerada.
12. Hace commit.
13. Solo despues del commit hace `ack` en RabbitMQ.

### Por que se hizo asi

RabbitMQ ofrece entrega at-least-once, no exactly-once. Por tanto, el worker asume que puede recibir duplicados. La seguridad se implementa con:

- `request_id` como clave idempotente.
- `SELECT ... FOR UPDATE` para serializar duplicados del mismo request.
- Transacciones ACID de PostgreSQL.
- Constraints en `sales`, `seats` y `ticket_pools`.

### Tickets no numerados

La operacion principal es:

```sql
UPDATE ticket_pools
SET sold_count = sold_count + 1
WHERE pool_id = 'main'
  AND sold_count < total_tickets
RETURNING sold_count;
```

Si no devuelve fila, el resultado es `sold_out`. No se reintenta porque no es fallo tecnico, es resultado de negocio.

### Tickets numerados

La operacion principal es:

```sql
UPDATE seats
SET status = 'sold', request_id = :request_id, sold_at = now()
WHERE seat_id = :seat_id
  AND status = 'available'
RETURNING seat_id;
```

Si no devuelve fila, el resultado es `seat_unavailable`. No se reintenta porque probablemente otro comprador ya vendio ese asiento.

### Retries y DLQ

El worker usa el header RabbitMQ `x-attempt`.

- Si ocurre un error transitorio y `attempt < MAX_ATTEMPTS`, republica el mensaje con `x-attempt + 1` y hace `ack` del original.
- Si no puede republicar, hace `nack(requeue=True)` para no perder el mensaje.
- Si `attempt >= MAX_ATTEMPTS`, envia el mensaje a SQS DLQ y hace `ack`.
- Si el mensaje esta mal formado, va directamente a SQS DLQ.

### Como conecta

- Entrada: RabbitMQ `tickets.exchange` -> `tickets.buy`.
- Persistencia: PostgreSQL `tickets`.
- Fallos definitivos: SQS DLQ.
- Logs: stdout del contenedor, que en Fargate ira a CloudWatch Logs.
- Imagen: Dockerfile preparado para subir a ECR.

### Validacion local

Se ejecuto compilacion Python:

```powershell
python -m py_compile app/worker/src/worker.py app/worker/src/__init__.py
```

Resultado: correcto.

Se construyo imagen Docker:

```powershell
docker build -t ticket-service-worker:local app/worker
```

Resultado: correcto. Se instalaron dependencias `pika`, `psycopg`, `boto3` y `python-dotenv`.

### Punto defendible en entrevista

El worker no intenta convertir RabbitMQ en exactly-once. Acepta at-least-once y hace que el procesamiento sea idempotente. Esta es la forma correcta de combinar colas con transacciones cuando hay reintentos y posibles caidas de workers.

## 2026-06-07 - Documento de arquitectura de infraestructura

### Que se hizo

Se creo `documents/infraestructura_arquitectura.md`.

### Contenido

El documento explica:

- Objetivo de la arquitectura.
- Diagrama general.
- Componentes: Terraform, VPC, RabbitMQ, PostgreSQL, ECS Fargate, ECR, SQS DLQ y CloudWatch.
- Security groups y puertos.
- Flujo de compra.
- Correctness bajo concurrencia.
- Fault tolerance.
- Escalabilidad.
- Estado actual y pendientes.

### Por que

Servira para explicar la practica en la entrevista o defensa tecnica sin tener que reconstruir decisiones desde el codigo. Tambien ayuda a mantener coherencia entre infraestructura, worker y reporte final.

## 2026-06-07 - Observabilidad inicial y prueba end-to-end real

### Que se comprobo

La consola de EC2 indicaba que las comprobaciones de sistema, instancia y EBS estaban correctas para RabbitMQ. Eso valida la salud de la maquina virtual, pero no valida por si solo que RabbitMQ este aceptando conexiones, que la cola exista o que haya consumidores procesando mensajes.

Se ejecuto una comprobacion de servicio completa con `scripts/observe.ps1`:

- ECS service `ticket-service-academy-worker`: `ACTIVE`, desired `1`, running `1`, pending `0`.
- ECS task: contenedor `ticket-worker` en estado `RUNNING`.
- RabbitMQ queue `tickets.buy`: `messages=0`, `ready=0`, `unacked=0`, `consumers=1`.
- PostgreSQL: requests completadas y ventas persistidas.
- SQS DLQ: `ApproximateNumberOfMessages=0`.
- CloudWatch Logs: el worker conecto a RabbitMQ y proceso mensajes.

### Prueba funcional

Se publico un mensaje real en RabbitMQ Management API hacia `tickets.exchange` con routing key `ticket.buy`.

Resultado inicial:

- El mensaje fue enrutado correctamente.
- El worker lo consumio desde ECS Fargate.
- PostgreSQL registro la request como completada.
- PostgreSQL registro una venta.
- La cola quedo vacia.
- La DLQ quedo vacia.

Tambien se republico el mismo `request_id` para validar idempotencia. El worker recibio el duplicado, pero PostgreSQL no creo una segunda venta. La garantia viene de `requests.request_id PRIMARY KEY`, `sales.request_id UNIQUE`, bloqueo `FOR UPDATE` y ack solo despues del commit.

### Correccion de metricas de tiempo

La primera version de metricas mostro una latencia end-to-end negativa. La causa no era un fallo de negocio, sino una mala definicion de medicion:

- `enqueued_at` venia del reloj local del productor.
- `completed_at` venia del reloj de PostgreSQL en AWS.
- Habia pequeno desfase entre relojes.
- Ademas `now()` en PostgreSQL devuelve el timestamp de inicio de transaccion, por lo que `completed_at - worker_started_at` podia salir 0 aunque el worker durmiera 100 ms simulando pago.

Se corrigio `app/worker/src/worker.py` para usar `clock_timestamp()` en:

- `worker_started_at`.
- `completed_at`.
- `sales.sold_at`.
- `seats.sold_at`.

Esto mide tiempo real dentro de la transaccion.

### Validacion despues del fix

Se reconstruyo la imagen Docker del worker, se subio a ECR y se forzo un nuevo deployment de ECS.

Se publico una nueva compra numerada:

- `request_id`: `9390bf8c-ef09-464a-bf83-2e3af2742ce3`.
- Resultado: `sold`.
- Intentos: `1`.
- Ventas para esa request: `1`.
- `processing_seconds`: `0.105`.

Ese valor encaja con `PAYMENT_DELAY_MS=100`, por lo que la metrica ya representa feedback real de procesamiento del worker.

### Que aporta esta observabilidad

Ahora podemos responder estas preguntas sin mirar manualmente cada servicio:

- Esta vivo ECS y cuantos workers hay?
- Hay tasks pendientes o caidas?
- RabbitMQ tiene backlog?
- Hay mensajes no reconocidos por workers?
- Cuantos consumidores tiene la cola?
- El worker esta escribiendo logs?
- Cuantas requests han completado?
- Cuantas ventas se han persistido?
- Hay errores de negocio o tecnicos?
- Hay mensajes muertos en la DLQ?
- Cuanto tarda el worker en procesar una request?

### Pendiente de observabilidad avanzada

Para la practica final aun falta:

- Load generator con `run_id` controlado.
- Export de resultados por experimento.
- Metricas por ventana temporal: throughput, p50, p95, p99, backlog medio y backlog maximo.
- Posible CloudWatch dashboard o script de recogida automatica.
- Logs estructurados JSON para parsear mejor por request.
- Distinguir en logs entre venta nueva e idempotencia por duplicado.

## 2026-06-07 - Destruccion del stack tras la prueba

### Que se hizo

Tras validar RabbitMQ, PostgreSQL, ECS worker, CloudWatch, SQS DLQ y metricas, se ejecuto:

```powershell
terraform destroy -auto-approve -var enable_core_infra=true -var enable_worker_service=true -var operator_cidr=86.127.229.77/32 -var worker_desired_count=1
```

Terraform destruyo 13 recursos:

- ECS service.
- ECS cluster.
- ECS task definition.
- CloudWatch log group.
- ECR repository.
- SQS DLQ.
- EC2 RabbitMQ.
- EC2 PostgreSQL.
- Security groups de RabbitMQ, PostgreSQL y workers.
- Passwords aleatorias de RabbitMQ y PostgreSQL.

### Verificacion posterior

Se verifico:

- `terraform state list` no devuelve recursos.
- EC2 solo muestra instancias `terminated` del proyecto.
- `aws ecs list-clusters` no muestra clusters `ticket-service`.
- `aws ecr describe-repositories` para `ticket-service-worker` devuelve `RepositoryNotFoundException`.
- `aws sqs list-queues` no devuelve colas `ticket-service-academy`.
- `aws logs describe-log-groups` no devuelve log groups `/ecs/ticket-service-academy`.

### Por que

La cuenta AWS Academy tiene presupuesto limitado. La practica debe crear recursos para probar y destruirlos al terminar cada validacion, dejando el codigo y los documentos como fuente de verdad para recrear el entorno cuando toque continuar.

## 2026-06-07 - Load generator y recogida de resultados

### Que se implemento

Se implemento `app/loadgen/src/loadgen.py`, un generador de carga que publica mensajes de compra en RabbitMQ con un `run_id` comun para todo el experimento.

Tambien se crearon dos scripts operativos:

- `scripts/run-loadgen.ps1`: lee los outputs de Terraform, obtiene RabbitMQ public IP, usuario y password, y ejecuta el generador.
- `scripts/collect-run-results.ps1`: consulta PostgreSQL por `run_id` y exporta resultados CSV a `report/results`.

### Por que

El enunciado exige no medir solo desde el cliente. El cliente sirve para inyectar carga, pero la metrica oficial debe salir de transacciones completadas. Por eso el load generator solo publica mensajes y PostgreSQL queda como fuente de verdad para:

- Requests completadas.
- Ventas reales.
- Resultados de negocio: `sold`, `sold_out`, `seat_unavailable`.
- Intentos por request.
- Latencias `processing` y `end_to_end`.
- Throughput de completados por ventana temporal de servidor.

### Que tipos de carga soporta

El generador soporta:

- `profile=constant`: carga estable para stress tests y capacidad por worker.
- `profile=z`: carga elastica con fases low, ramp-up, spike, high y cool-down.
- `mode=unnumbered`: tickets no numerados contra el pool global.
- `mode=numbered`: tickets numerados 1..100000.
- `distribution=uniform`: asientos repartidos uniformemente.
- `distribution=hotspot`: 80% de requests contra 5% de asientos por defecto.

### Formato de mensaje publicado

Cada mensaje contiene:

```json
{
  "request_id": "uuid",
  "run_id": "uuid",
  "workload_name": "manual-loadgen",
  "sequence": 1,
  "mode": "numbered",
  "seat_id": 1234,
  "enqueued_at": "2026-06-07T18:11:40.840093+00:00"
}
```

`request_id` permite idempotencia. `run_id` agrupa el experimento. `sequence` ayuda a depurar orden de publicacion. `enqueued_at` permite estimar latencia end-to-end, aunque se sigue considerando que la metrica mas robusta para procesamiento es `completed_at - worker_started_at` en PostgreSQL.

### Ajuste en el worker

Se modifico `app/worker/src/worker.py` para preservar `workload_name` en `experiment_runs`. Antes el worker siempre guardaba `auto-created-by-worker`; ahora la tabla sabe que experimento genero la carga.

### Validacion local

Se valido sintaxis con:

```powershell
.\.venv\Scripts\python.exe -m py_compile app\worker\src\worker.py app\loadgen\src\loadgen.py app\loadgen\src\__init__.py
```

Se valido el modo seco del load generator sin tocar AWS:

```powershell
.\.venv\Scripts\python.exe -m app.loadgen.src.loadgen --rabbitmq-host localhost --rabbitmq-password dummy --profile constant --requests 3 --rate 2 --mode numbered --distribution hotspot --seed 7 --dry-run
```

Resultado: genero 3 payloads con `seat_id` dentro del hotspot.

Tambien se valido perfil elastico:

```powershell
.\.venv\Scripts\python.exe -m app.loadgen.src.loadgen --rabbitmq-host localhost --rabbitmq-password dummy --profile z --mode unnumbered --distribution uniform --dry-run --dry-run-limit 2
```

Resultado: planifico 2040 mensajes con fases low, ramp-up, spike, high y cool-down.

### Uso cuando el stack este desplegado

Carga constante:

```powershell
.\scripts\run-loadgen.ps1 -Requests 500 -Rate 50 -Mode numbered -Distribution uniform
```

Hotspot:

```powershell
.\scripts\run-loadgen.ps1 -Requests 500 -Rate 50 -Mode numbered -Distribution hotspot
```

Perfil elastico Z(t):

```powershell
.\scripts\run-loadgen.ps1 -Profile z -Mode numbered -Distribution hotspot
```

Recogida de resultados:

```powershell
.\scripts\collect-run-results.ps1 -RunId <run_id>
```

### Estado de AWS

No se desplego infraestructura en este paso. El stack seguia destruido para no gastar presupuesto. La validacion fue local y de sintaxis/comportamiento del generador.

## 2026-06-07 - Smoke test real del load generator

### Objetivo

Validar de extremo a extremo que el load generator publica en RabbitMQ y que el worker procesa las compras hasta PostgreSQL, midiendo resultados desde la base de datos y no solo desde el cliente.

### Despliegue usado

Se recreo temporalmente el stack en AWS Academy:

- RabbitMQ en EC2.
- PostgreSQL en EC2.
- ECR para imagen del worker.
- ECS Fargate con `worker_desired_count=1`.
- CloudWatch Logs.
- SQS DLQ.

La IP publica del operador usada en security groups fue `86.127.229.77/32`.

Endpoints durante la prueba:

- RabbitMQ public IP: `50.19.161.203`.
- PostgreSQL public IP: `3.87.183.94`.
- RabbitMQ private IP: `172.31.82.205`.
- PostgreSQL private IP: `172.31.93.0`.

### Validaciones previas

RabbitMQ respondio por Management API.

PostgreSQL tardo unos segundos mas en aceptar conexiones porque el contenedor inicializaba schema y 100000 asientos. Despues devolvio:

```text
seats = 100000
pools = 1
```

La imagen del worker se construyo y subio a ECR con tag `latest`.

ECS quedo estable:

```text
status=ACTIVE
desired=1
running=1
pending=0
```

### Carga ejecutada

Se ejecuto una carga pequena para smoke test:

```powershell
.\scripts\run-loadgen.ps1 -Requests 10 -Rate 5 -Mode numbered -Distribution uniform -ReportEvery 5 -RunId ec070f5b-0941-49ce-9628-ff2d0bbecc8c
```

Resumen del productor:

```text
run_id = ec070f5b-0941-49ce-9628-ff2d0bbecc8c
requested_messages = 10
published_messages = 10
average_publish_rate = 4.951 req/s
profile = constant
mode = numbered
distribution = uniform
```

### Resultados en PostgreSQL

CSV generado:

- `report/results/summary-smoke-uniform-n-ec070f5b.csv`.
- `report/results/latencies-smoke-uniform-n-ec070f5b.csv`.

Resumen de base de datos:

```text
requests = 10
completed = 10
sold = 10
sold_out = 0
seat_unavailable = 0
errored = 0
sales = 10
server_processing_window_seconds = 1.904872
completed_per_second_server_window = 5.2497
processing_p50_seconds = 0.10633
processing_p95_seconds = 0.1112582
processing_p99_seconds = 0.11298764
```

Interpretacion:

- El circuito loadgen -> RabbitMQ -> ECS worker -> PostgreSQL funciona.
- No hubo overselling.
- No hubo errores.
- No hubo DLQ.
- El retardo artificial de 100 ms se refleja en la metrica de procesamiento.
- Con un worker y una carga de 5 req/s el sistema dreno todo sin backlog residual.

### Observabilidad durante la prueba

`scripts/observe.ps1` mostro:

```text
ECS desired=1 running=1 pending=0
RabbitMQ messages=0 ready=0 unacked=0 consumers=1
PostgreSQL requests=10 completed=10 sold=10
SQS DLQ visible=0 not_visible=0
```

CloudWatch Logs mostro 10 lineas `processed request_id=... result=sold attempt=1`.

### Nota sobre latencia end-to-end

`end_to_end_seconds` salio negativo de forma consistente por desfase entre el reloj local del cliente y el reloj de AWS/PostgreSQL. No se considera metrica fiable en esta configuracion.

La metrica defendible para procesamiento es:

```text
processing_seconds = completed_at - worker_started_at
```

Ambos timestamps los genera PostgreSQL con `clock_timestamp()`, por lo que son comparables.

### Limpieza

Tras la prueba se ejecuto `terraform destroy` y se destruyeron 13 recursos.

Verificacion posterior:

- `terraform state list` vacio.
- EC2 solo muestra instancias `terminated` del proyecto.
- No hay cluster ECS `ticket-service`.
- No hay cola SQS `ticket-service-academy`.
- No hay log groups `/ecs/ticket-service-academy`.
- ECR `ticket-service-worker` devuelve `RepositoryNotFoundException`, esperado tras destruirlo.

### Conclusion

Smoke test superado. El siguiente paso ya no es comprobar conectividad basica, sino ejecutar pruebas de capacidad con varias tasas y varios `worker_desired_count` para estimar `C`, la capacidad real por worker.

## 2026-06-08 - Estrategia para no redeployar todo en cada prueba

### Problema detectado

Recrear RabbitMQ EC2, PostgreSQL EC2, ECR, ECS, CloudWatch y SQS para cada smoke test consume demasiado tiempo. Para experimentos consecutivos es mejor mantener el entorno vivo durante la sesion.

### Decision

A partir de ahora, durante una sesion activa de pruebas:

- No destruir todo despues de cada carga pequena.
- Mantener RabbitMQ/PostgreSQL/ECR/SQS/ECS creados.
- Escalar workers Fargate a `0` cuando estemos preparando cosas.
- Escalar workers Fargate a `1..N` para ejecutar experimentos.
- Destruir todo al final del bloque de trabajo para proteger el presupuesto.

### Implementacion

Se creo `scripts/set-workers.ps1`.

Uso:

```powershell
.\scripts\set-workers.ps1 -DesiredCount 0
.\scripts\set-workers.ps1 -DesiredCount 1
.\scripts\set-workers.ps1 -DesiredCount 4
```

Se creo tambien `documents/estrategia_pruebas_aws_academy.md` con la politica operativa y la ubicacion de resultados.

### Ubicacion de los CSV del smoke test

Los ficheros generados por el smoke test estan en:

```text
report/results/summary-smoke-uniform-n-ec070f5b.csv
report/results/latencies-smoke-uniform-n-ec070f5b.csv
report/loadgen_runs/loadgen-smoke-uniform-n-ec070f5b.json
```


## 2026-06-08 - Nombres cortos automaticos para resultados

### Problema

Los resultados se estaban guardando con el UUID completo en el nombre del archivo. Eso hacia dificil encontrar el `summary.csv`, el `latencies.csv` y el JSON del load generator.

### Cambio

Se actualizo `scripts/run-loadgen.ps1` para generar automaticamente un nombre corto basado en:

- tipo de prueba o `RunName`, si se pasa;
- modo (`numbered`/`unnumbered`);
- distribucion (`uniform`/`hotspot`);
- numero de requests y rate para pruebas constantes;
- primeros 8 caracteres del `run_id`.

Ejemplo automatico para carga constante:

```text
numbered-uniform-500req-50rps-ec070f5b.json
```

Ejemplo pasando nombre explicito:

```powershell
.\scripts\run-loadgen.ps1 -RunName smoke-numbered-uniform -Requests 10 -Rate 5 -Mode numbered -Distribution uniform
```

Genera:

```text
report/loadgen_runs/loadgen-smoke-uniform-n-ec070f5b.json
```

Se actualizo `scripts/collect-run-results.ps1` para reutilizar automaticamente el nombre del JSON del loadgen y generar:

```text
report/results/summary-smoke-uniform-n-ec070f5b.csv
report/results/latencies-smoke-uniform-n-ec070f5b.csv
```

### Migracion del smoke test anterior

Los artefactos del smoke test anterior se renombraron con la nueva convencion:

```text
report/results/summary-smoke-uniform-n-ec070f5b.csv
report/results/latencies-smoke-uniform-n-ec070f5b.csv
report/loadgen_runs/loadgen-smoke-uniform-n-ec070f5b.json
```


## 2026-06-08 - Convencion corta de nombres y comandos rapidos

### Cambio de nombres

Se cambio la convencion automatica de resultados para que los ficheros empiecen por lo que son:

```text
summary-smoke-uniform-n-ec070f5b.csv
latencies-smoke-uniform-n-ec070f5b.csv
loadgen-smoke-uniform-n-ec070f5b.json
```

Formato:

```text
summary-<test>-<distribution>-<mode>-<id8>.csv
latencies-<test>-<distribution>-<mode>-<id8>.csv
loadgen-<test>-<distribution>-<mode>-<id8>.json
```

`n` significa numbered y `un` significa unnumbered.

### Implementacion

- `scripts/run-loadgen.ps1` genera `loadgen-...json`.
- `scripts/collect-run-results.ps1` busca el JSON y genera `summary-...csv` y `latencies-...csv`.
- Los artefactos antiguos se renombraron a la nueva convencion.

### Documento de emergencia

Se creo `documents/comandos_rapidos_aws_academy.md` con los comandos minimos para seguir si se acaba el credito de Codex.

## 2026-06-08 - Smoke test con stack caliente y nombres legibles

### Que se hizo

Se continuo con el stack base vivo en AWS Academy en vez de destruir/recrear todo:

- RabbitMQ EC2 vivo.
- PostgreSQL EC2 vivo.
- ECR vivo.
- SQS DLQ viva.
- ECS creado para workers.

Docker Desktop ya estaba arrancado, por lo que se pudo construir y subir la imagen del worker a ECR.

### Endpoints del stack caliente

- RabbitMQ public IP: `35.175.235.85`.
- RabbitMQ private IP: `172.31.90.181`.
- PostgreSQL public IP: `3.86.214.236`.
- PostgreSQL private IP: `172.31.83.121`.
- ECS service: `ticket-service-academy-worker`.

### Smoke test ejecutado

Comando equivalente:

```powershell
$runId = "ba063552-70c4-4c7e-a54d-a00ed709891f"
.\scripts\run-loadgen.ps1 -RunName smoke -Requests 10 -Rate 5 -Mode numbered -Distribution uniform -ReportEvery 5 -RunId $runId
.\scripts\collect-run-results.ps1 -RunId $runId
.\scripts\observe.ps1 -LogLimit 25
```

### Resultados

El load generator publico 10 mensajes a unos 5 req/s.

PostgreSQL registro:

```text
requests = 10
completed = 10
sold = 10
sold_out = 0
seat_unavailable = 0
errored = 0
sales = 10
processing_p50_seconds = 0.1047235
processing_p95_seconds = 0.1050954
processing_p99_seconds = 0.10527828
```

RabbitMQ quedo sin backlog:

```text
messages = 0
ready = 0
unacked = 0
consumers = 1 durante la prueba
```

SQS DLQ quedo a 0.

### Archivos generados

La nueva convencion legible funciona:

```text
report/results/summary-smoke-uniform-n-ba063552.csv
report/results/latencies-smoke-uniform-n-ba063552.csv
report/loadgen_runs/loadgen-smoke-uniform-n-ba063552.json
```

### Estado final tras la prueba

No se destruyo el stack.

Se pauso Fargate con:

```powershell
.\scripts\set-workers.ps1 -DesiredCount 0
```

ECS quedo:

```text
desired = 0
running = 0
pending = 0
status = ACTIVE
```

Interpretacion: no hay workers Fargate corriendo, pero RabbitMQ/PostgreSQL/ECR/SQS/ECS siguen vivos para reutilizar el entorno en la siguiente prueba sin esperar el redeploy completo.

### Advertencia de coste

Aunque Fargate esta pausado, EC2 RabbitMQ, EC2 PostgreSQL, EBS y recursos asociados siguen vivos. Hay que destruir el stack al final del bloque de trabajo.

## 2026-06-08 - PRIORIDAD ALTA: corregir medicion end-to-end

### Por que es prioritario

Se reviso el enunciado y la seccion `Throughput & Metrics Measurement (IMPORTANT)` exige explicitamente:

- Throughput = completed requests / total time.
- Latency distribution p50, p95, p99.
- End-to-end processing time.
- No depender solo de timing del cliente.
- Las medidas deben reflejar transacciones completadas.

Por tanto, `end_to_end_seconds` no puede quedar descartado. Debe corregirse.

### Problema actual

En el smoke test `ba063552`, `end_to_end_seconds` salio negativo porque:

- `enqueued_at` lo genera el portatil/local loadgen.
- `worker_started_at` y `completed_at` los genera PostgreSQL/AWS.
- Hay desfase de reloj entre local y AWS.

Esto invalida `completed_at - enqueued_at` como end-to-end real.

### Decision tecnica

Prioridad alta antes de stress tests, graficas o escalado:

- Hacer que el timestamp de entrada usado para end-to-end venga del mismo dominio de reloj que `completed_at`.
- Opcion preferida: al recibir el mensaje, el worker registra `received_at = clock_timestamp()` en PostgreSQL antes del delay y del procesamiento.
- Para end-to-end defendible de sistema asincrono: usar `completed_at - received_at` como latencia server-side desde recepcion por worker hasta commit.
- Si queremos incluir espera en RabbitMQ, necesitamos un timestamp generado por AWS antes de publicar o una medicion de backlog/tiempo en cola no basada en reloj local.

### Regla a partir de ahora

Antes de cada paso nuevo se revisa el enunciado y se comprueba si el cambio contribuye directamente a un requisito. No se avanzara a pruebas de capacidad hasta arreglar la metrica end-to-end exigida.

## 2026-06-08 - Correccion inicial de end-to-end con reloj PostgreSQL

### Requisito del enunciado revisado

Se reviso `documents/enunciado.txt`, seccion `Throughput & Metrics Measurement (IMPORTANT)`:

- Hay que calcular throughput con requests completadas.
- Hay que calcular distribucion de latencia p50/p95/p99.
- Hay que calcular end-to-end processing time.
- No se debe depender solo del timing del cliente.
- Las mediciones deben reflejar transacciones completadas.

### Cambio implementado

Se modifico `app/loadgen/src/loadgen.py` para registrar cada request en PostgreSQL antes de publicarla a RabbitMQ.

Nuevo flujo:

```text
loadgen -> INSERT request en PostgreSQL con enqueued_at = clock_timestamp()
loadgen -> publish a RabbitMQ
worker  -> consume RabbitMQ
worker  -> completed_at = clock_timestamp()
```

Ahora `end_to_end_seconds = completed_at - enqueued_at` usa timestamps generados por PostgreSQL, por lo que no mezcla reloj local con reloj AWS.

### Scripts actualizados

`app/loadgen/requirements.txt` ahora incluye:

```text
psycopg[binary]>=3.1,<4
```

`scripts/run-loadgen.ps1` ahora lee automaticamente estos outputs de Terraform y se los pasa al loadgen:

- `postgres_public_ip`
- `postgres_database`
- `postgres_username`
- `postgres_password`

### Smoke test de validacion

Run:

```text
run_id = 63dc3b6e-f677-4325-bab4-0f9525444afc
artifact = e2e-uniform-n-63dc3b6e
```

Archivos:

```text
report/results/summary-e2e-uniform-n-63dc3b6e.csv
report/results/latencies-e2e-uniform-n-63dc3b6e.csv
report/loadgen_runs/loadgen-e2e-uniform-n-63dc3b6e.json
```

Resultados por run:

```text
requests = 10
completed = 10
sold = 10
errored = 0
processing_p50_seconds = 0.105709
processing_p95_seconds = 0.1071682
processing_p99_seconds = 0.10760164
end_to_end_p50_seconds = 0.355314
end_to_end_p95_seconds = 0.3658314
end_to_end_p99_seconds = 0.36738948
```

Conclusion: `end_to_end_seconds` ya no sale negativo en el run nuevo.

### Observacion importante

El loadgen local bajo de la tasa objetivo de 5 req/s a ~1.9 req/s porque ahora cada mensaje hace una escritura a PostgreSQL usando la IP publica desde el portatil.

Esto no invalida la correccion de end-to-end, pero muestra que para experimentos de capacidad la siguiente mejora deberia ser ejecutar el loadgen dentro de AWS/Fargate, usando la IP privada de PostgreSQL y RabbitMQ. Asi reducimos latencia local y hacemos la carga mas representativa.

### Estado final

No se destruyo el stack.

Workers Fargate pausados:

```text
desired = 0
running = 0
pending = 0
```

RabbitMQ/PostgreSQL/ECR/SQS/ECS siguen vivos para la siguiente prueba.

## 2026-06-08 - Load generator en AWS y limpieza previa de estado

### Revision del enunciado

Puntos revisados antes de tocar nada:

- Punto 9: las metricas deben salir de transacciones completadas, no solo del cliente.
- Punto 10: hay que contemplar reintentos, idempotencia y DLQ.
- Punto 7: los tests de capacidad deben partir de un estado limpio para no mezclar runs.

### Que se implementa

Se consolida el load generator como una tarea one-shot de ECS/Fargate.

Antes, el cliente de pruebas se ejecutaba desde el portatil con `scripts/run-loadgen.ps1`. Eso funcionaba para validar, pero metia dos problemas:

- La red local podia limitar la tasa real de publicacion.
- Era menos representativo de un sistema desplegado en AWS.

Ahora el flujo recomendado usa `scripts/run-loadgen-aws.ps1`, que lanza una task Fargate temporal dentro del cluster ECS. Esa task ejecuta el contenedor `ticket-service-loadgen` y se conecta por IP privada a:

```text
loadgen Fargate -> PostgreSQL EC2: registra request_id y enqueued_at con clock_timestamp()
loadgen Fargate -> RabbitMQ EC2: publica mensaje tickets.buy
worker Fargate  -> RabbitMQ EC2: consume mensaje
worker Fargate  -> PostgreSQL EC2: procesa venta y marca completed_at
worker Fargate  -> SQS DLQ: envia fallos no recuperables
```

### Limpieza antes de pruebas

Se crea `scripts/clean-test-state.ps1` para evitar metricas contaminadas entre runs.

Limpia:

- RabbitMQ: purga `tickets.buy`.
- PostgreSQL: trunca `sales`, `requests`, `experiment_runs`; resetea `seats`; resetea `ticket_pools`.
- SQS: purga la DLQ `ticket-service-academy-ticket-failures-dlq`.

Esto se ejecuta antes de empezar un test para que `summary.csv` y `latencies.csv` midan solo el run actual.

### Chuleta actualizada

Se actualiza `documents/comandos_rapidos_aws_academy.md` con:

- Comandos para limpiar todo.
- Comandos para limpiar solo RabbitMQ, solo PostgreSQL o solo SQS.
- Smoke test recomendado desde AWS.
- Build/push del loadgen si cambia su codigo.
- Fallback local solo si hace falta.

### Ajuste de coste

Se ajusta `scripts/set-workers.ps1` para que espere estabilidad de ECS tambien cuando se baja a `DesiredCount 0`.

Motivo: antes Terraform cambiaba `desired=0`, pero el comando podia terminar mientras ECS todavia mostraba `running=1` durante unos segundos. Ahora el script espera a que el servicio quede estable, que es mas seguro para controlar coste.

### Smoke test validado desde AWS

Run ejecutado:

```text
run_id = 683ea50c-b292-4deb-acb1-36cfef922f9b
artifact = smoke-uniform-n-683ea50c
source = ecs-fargate
```

Archivos generados:

```text
report/loadgen_runs/loadgen-smoke-uniform-n-683ea50c.json
report/results/summary-smoke-uniform-n-683ea50c.csv
report/results/latencies-smoke-uniform-n-683ea50c.csv
```

Resultado:

```text
requests = 10
completed = 10
sold = 10
sold_out = 0
seat_unavailable = 0
errored = 0
DLQ messages = 0
```

Latencias del run:

```text
processing_p50_seconds = 0.1051155
processing_p95_seconds = 0.10610905
processing_p99_seconds = 0.10628581
end_to_end_p50_seconds = 0.127903
end_to_end_p95_seconds = 0.13480325
end_to_end_p99_seconds = 0.13601105
```

Conclusion tecnica: el end-to-end ya es positivo y coherente porque `enqueued_at` y `completed_at` salen del reloj de PostgreSQL. El procesamiento sigue alrededor de 100 ms, como exige el enunciado por el delay artificial de pago dentro del worker.

### Estado final

Stack vivo para no perder tiempo redeployando.

Workers pausados:

```text
desired = 0
running = 0
pending = 0
```

RabbitMQ, PostgreSQL, ECS, ECR, CloudWatch y SQS siguen creados.

### Ajuste posterior: limpieza automatica en loadgen AWS

Se actualiza `scripts/run-loadgen-aws.ps1` para ejecutar `scripts/clean-test-state.ps1` automaticamente antes de lanzar la task Fargate.

Esto reduce el riesgo operativo de olvidar la limpieza antes de un test. Si se necesita lanzar una prueba sin limpiar, se puede usar:

```powershell
.\scripts\run-loadgen-aws.ps1 -SkipClean
```

### Validacion de limpieza automatica

Se ejecuta un autosmoke sin llamar manualmente a `clean-test-state.ps1`. La limpieza la ejecuta `run-loadgen-aws.ps1` antes de lanzar Fargate.

Run:

```text
run_id = e41437db-c4c8-4ec8-b52a-678ca51ee4b1
artifact = autosmoke-uniform-n-e41437db
source = ecs-fargate
```

Archivos:

```text
report/loadgen_runs/loadgen-autosmoke-uniform-n-e41437db.json
report/results/summary-autosmoke-uniform-n-e41437db.csv
report/results/latencies-autosmoke-uniform-n-e41437db.csv
```

Resultado:

```text
requests = 5
completed = 5
sold = 5
errored = 0
processing_p50_seconds = 0.104948
end_to_end_p50_seconds = 0.127017
container_exit_code = 0
```

Estado al cerrar:

```text
desired = 0
running = 0
pending = 0
```

## 2026-06-08 - Cluster compartido ECS y ECR antiguo

### Revision del enunciado

El enunciado pide workers stateless en Fargate, procesamiento asincrono, metricas fiables y despliegue IaC. No exige separar el generador de carga en otro cluster ECS.

### Decision sobre cluster ECS

El loadgen se ejecuta como task one-shot dentro del mismo cluster ECS que los workers:

```text
ticket-service-academy-worker
  worker service: desired_count escalable
  loadgen task: ejecucion temporal bajo demanda
```

Esto es correcto porque el cluster ECS es un agrupador logico de capacidad Fargate y configuracion operativa. La separacion real se mantiene en:

- Task definition distinta: `ticket-service-academy-worker` vs `ticket-service-academy-loadgen`.
- Imagen ECR distinta: `ticket-service-worker` vs `ticket-service-loadgen`.
- Log group distinto: `/ecs/ticket-service-academy-worker` vs `/ecs/ticket-service-academy-loadgen`.
- Ciclo de vida distinto: worker service persistente, loadgen task temporal.

Separar clusters no mejora la correccion ni las metricas de esta practica; solo anade mas recursos y mas complejidad visual.

### Revision de ECR antiguo

Repositorios ECR encontrados:

```text
ticket-worker              creado 2026-06-06
ticket-service-worker      creado 2026-06-08
ticket-service-loadgen     creado 2026-06-08
```

Task definitions activas:

```text
ticket-service-academy-worker  -> ticket-service-worker:latest
ticket-service-academy-loadgen -> ticket-service-loadgen:latest
```

Conclusion: `ticket-worker` es un repositorio antiguo de una version previa y no es necesario para el stack actual. Se puede borrar si se quiere limpiar la cuenta, pero no se borra automaticamente para evitar una accion destructiva sin confirmacion explicita.

### Limpieza ejecutada de ECR antiguo

Se borro el repositorio antiguo `ticket-worker` con confirmacion explicita del usuario.

Comando aplicado:

```powershell
aws ecr delete-repository --repository-name ticket-worker --force
```

Repositorios ECR restantes:

```text
ticket-service-worker
ticket-service-loadgen
```

No afecta al stack actual porque las task definitions activas usan `ticket-service-worker:latest` y `ticket-service-loadgen:latest`.

## 2026-06-08 - Documentacion interna del codigo

### Revision del enunciado

Se revisaron especialmente estos puntos:

- Punto 2: correccion bajo concurrencia y no overselling.
- Punto 3: arquitectura asincrona con RabbitMQ, workers stateless y PostgreSQL.
- Punto 4: delay artificial de 100 ms dentro del worker.
- Punto 9: metricas desde transacciones completadas, no solo cliente.
- Punto 10: idempotencia, retries y DLQ.

### Que se hizo

Se comentaron los archivos principales con dos niveles de explicacion:

- Explicacion simple: que hace el archivo en lenguaje directo.
- Explicacion tecnica: como conecta con RabbitMQ, PostgreSQL, ECS/Fargate, SQS, Terraform y metricas.

Archivos mas importantes comentados:

```text
app/worker/src/worker.py
app/loadgen/src/loadgen.py
infra/terraform/core_infra.tf
infra/terraform/worker_service.tf
infra/terraform/loadgen_task.tf
scripts/run-loadgen-aws.ps1
scripts/clean-test-state.ps1
scripts/collect-run-results.ps1
scripts/observe.ps1
scripts/set-workers.ps1
```

Tambien se documento que `app/smoke-worker` y Terraform smoke son auxiliares antiguos, no parte del sistema real.

### Guia creada

Se creo:

```text
documents/guia_codigo_comentado.md
```

Sirve como mapa rapido para explicar que hace cada archivo y que puntos defender.

### Validacion

```text
python -m py_compile app/worker/src/worker.py app/loadgen/src/loadgen.py app/smoke-worker/smoke_worker.py
PowerShell parser scripts/*.ps1
terraform -chdir=infra/terraform fmt -recursive -check
terraform -chdir=infra/terraform validate
```

Resultado: todo OK.

## 2026-06-08 - Optimizacion del ciclo de pruebas

### Problema detectado

El ciclo de test parecia volver a tardar demasiado, parecido a destruir y recrear stack. Se reviso el flujo y el cuello principal no era la limpieza de RabbitMQ/PostgreSQL/SQS, sino usar `terraform apply` para cambiar `worker_desired_count` en cada prueba.

Terraform hace refresh/plan/apply de muchos recursos aunque solo queramos cambiar desired_count. Eso es correcto como IaC, pero lento para iterar tests.

### Decision

Se separan dos caminos:

```text
Terraform = crear/reconciliar infraestructura
AWS CLI directo = escalar workers rapido durante pruebas
```

### Nuevo script rapido

Se crea:

```text
scripts/set-workers-fast.ps1
```

Usa:

```powershell
aws ecs update-service --desired-count N
```

Lee cluster/service desde Terraform outputs, pero no ejecuta `terraform apply`.

Ventaja: evita el refresh completo de Terraform.

Trade-off: introduce drift temporal respecto a Terraform state. No es grave durante pruebas; al final se puede reconciliar con `scripts/set-workers.ps1 -DesiredCount 0`.

### Limpieza optimizada

Se optimiza `scripts/clean-test-state.ps1`:

- RabbitMQ: purge por Management API.
- PostgreSQL: ya no actualiza siempre los 100.000 seats.
- PostgreSQL: solo resetea seats dirty (`status <> available`, `request_id IS NOT NULL`, `sold_at IS NOT NULL`).
- SQS: purge de DLQ.
- Ahora imprime tiempos por paso.

### Medicion real

Limpieza medida:

```text
RabbitMQ purge: 8.65s
PostgreSQL reset: 12.04s
SQS DLQ purge: 5.05s
Total clean: 25.77s
```

Escalado rapido a workers 0 medido:

```text
set-workers-fast desired=0: ~12s
```

Conclusion: el flujo rapido debe usar `set-workers-fast.ps1`, no `set-workers.ps1`, durante tandas de pruebas.

### Chuleta actualizada

`documents/comandos_rapidos_aws_academy.md` ahora usa `set-workers-fast.ps1` para iniciar/parar workers en smoke tests y ahorro rapido.

## 2026-06-08 - Smoke test con flujo rapido medido

### Objetivo

Validar que el nuevo flujo evita volver a ciclos de 15 minutos.

### Comando conceptual ejecutado

```powershell
$runId = [guid]::NewGuid().ToString()
.\scripts\set-workers-fast.ps1 -DesiredCount 1
.\scripts\run-loadgen-aws.ps1 -RunName smoke-fast -Requests 10 -Rate 5 -Mode numbered -Distribution uniform -ReportEvery 5 -RunId $runId
.\scripts\collect-run-results.ps1 -RunId $runId
.\scripts\set-workers-fast.ps1 -DesiredCount 0
```

### Run

```text
run_id = fd966d8c-7902-4446-a582-2c2c502427b0
artifact = smoke-fast-uniform-n-fd966d8c
source = ecs-fargate
```

### Tiempos medidos

```text
start_workers_seconds = 44.04
clean_and_loadgen_seconds = 88.20
collect_seconds = 8.53
stop_workers_seconds = 28.98
total_seconds = 169.79
```

Detalle de limpieza dentro de `run-loadgen-aws.ps1`:

```text
RabbitMQ purge = 7.64s
PostgreSQL reset = 11.53s
SQS DLQ purge = 4.84s
clean total = 24.02s
```

### Resultado funcional

```text
requests = 10
completed = 10
sold = 10
sold_out = 0
seat_unavailable = 0
errored = 0
container_exit_code = 0
```

Latencias:

```text
processing_p50_seconds = 0.1060755
processing_p95_seconds = 0.1065038
processing_p99_seconds = 0.10655276
end_to_end_p50_seconds = 0.132598
end_to_end_p95_seconds = 0.1366196
end_to_end_p99_seconds = 0.13883432
```

### Conclusion

El smoke completo tardo ~2m50s. Ya no estamos en el problema de ~15m. El coste temporal restante viene sobre todo de arranque/parada Fargate y de esperar la task one-shot del loadgen. Para una tanda larga de pruebas conviene dejar workers encendidos durante varios tests y pararlos solo al final.

### Estado final

```text
workers desired = 0
workers running = 0
workers pending = 0
```

## 2026-06-08 - Cierre completo de AWS Academy

### Motivo

El usuario indico que iba a cerrar AWS Academy y pidio parar todo para evitar gasto.

### Accion ejecutada

Primero se forzo el servicio ECS de workers a cero:

```powershell
.\scripts\set-workers-fast.ps1 -DesiredCount 0 -NoWait
```

Despues se destruyo el stack gestionado por Terraform:

```powershell
terraform -chdir=infra/terraform destroy -auto-approve `
  -var enable_core_infra=true `
  -var enable_worker_service=true `
  -var operator_cidr=86.127.229.77/32 `
  -var worker_desired_count=0
```

### Resultado

Terraform destruyo 16 recursos:

```text
CloudWatch log group worker/loadgen
ECR worker/loadgen
ECS cluster/service/task definitions
EC2 RabbitMQ
EC2 PostgreSQL
Security groups
SQS DLQ
random passwords
```

Comprobaciones posteriores:

```text
Remaining tagged EC2 instances: none
Remaining ECR repositories with ticket-service prefix: none
Remaining ECS clusters with ticket-service prefix: none
Remaining SQS queues with ticket-service prefix: none
```

### Estado final

No queda infraestructura del proyecto encendida en AWS Academy segun las comprobaciones realizadas.

## 2026-06-08 - Pruebas pre-scaling: capacidad, estabilidad, hotspot y tolerancia a fallos

### Revision del enunciado

Antes de ejecutar esta tanda se revisaron especialmente estos puntos:

- Punto 5: el autoscaling debe basarse en carga medida y parametros estimados experimentalmente.
- Punto 7: hay que determinar throughput maximo por nodo, punto de saturacion y degradacion.
- Punto 8: hay que comparar carga uniforme y hotspot.
- Punto 9: throughput = completadas / tiempo total, latencias p50/p95/p99 y end-to-end.
- Punto 10: hay que validar idempotencia y DLQ.

### Ajuste de metricas

Se actualizo `scripts/collect-run-results.ps1` para separar dos metricas:

```text
completed_per_second_experiment_window = completed / (last_completed_at - first_enqueued_at)
completed_per_second_server_window     = completed / (last_completed_at - first_worker_started_at)
```

La primera es la metrica literal del enunciado. La segunda se conserva como metrica auxiliar para estimar capacidad pura de workers.

### Capacidad por numero de workers

Se lanzaron pruebas saturantes con loadgen en ECS/Fargate, RabbitMQ/PostgreSQL limpios antes de cada run y workers Fargate fijos.

```text
w1: 300 requests, rate 30/s, numbered uniform
w2: 600 requests, rate 60/s, numbered uniform
w4: 1200 requests, rate 120/s, numbered uniform
w8: 2400 requests, rate 240/s, numbered uniform
```

Resultados principales:

```text
workers  completed  sold  seat_unavailable  errors  throughput_server
1        300        299   1                 0       7.92 req/s
2        600        599   1                 0       15.56 req/s
4        1200       1194  6                 0       30.54 req/s
8        2400       2378  22                0       54.97 req/s
```

Interpretacion:

- La capacidad de 1 worker queda estimada en C ~= 7.9 req/s.
- 2 y 4 workers escalan casi linealmente.
- 8 workers sigue mejorando, pero baja la eficiencia: speedup aproximado 6.95x, no 8x.
- No hubo errores tecnicos ni mensajes en DLQ durante las pruebas de capacidad.
- Los `seat_unavailable` son rechazos de negocio esperables en modo numbered cuando dos requests eligen el mismo asiento aleatorio; no son fallo del sistema.

### Estabilidad por debajo de capacidad

Se ejecuto una prueba con 4 workers por debajo de su capacidad medida:

```text
run_id = 1ab3084b-58ca-46e2-9050-896d3088ddfd
requests = 480
rate = 24 req/s
mode = numbered
distribution = uniform
```

Resultado:

```text
completed = 480
sold = 478
seat_unavailable = 2
errors = 0
throughput_experiment = 23.90 req/s
end_to_end_p50 = 0.129s
end_to_end_p95 = 0.543s
end_to_end_p99 = 0.625s
```

Comparacion clave:

- Con 4 workers a 24 req/s, el sistema no acumula backlog importante y la latencia end-to-end se mantiene baja.
- Con 4 workers a 120 req/s, la capacidad real ronda 30.5 req/s y el resto queda esperando en cola; por eso el p50 end-to-end sube a unos 14.6s.

Esto demuestra la diferencia entre tiempo de procesamiento interno y tiempo end-to-end bajo saturacion.

### Comparacion numbered vs unnumbered

Se ejecuto una prueba con 4 workers en modo unnumbered:

```text
run_id = 80241c9c-f5c1-45d0-902d-1af93cdf664e
requests = 1200
rate = 120 req/s
mode = unnumbered
distribution = uniform
```

Resultado:

```text
completed = 1200
sold = 1200
errors = 0
throughput_experiment = 30.48 req/s
throughput_server = 30.50 req/s
end_to_end_p50 = 14.86s
end_to_end_p95 = 27.90s
```

Interpretacion:

- A esta escala, el contador global de tickets unnumbered en PostgreSQL no es un cuello de botella mayor que la venta numbered.
- El limite dominante sigue siendo el delay obligatorio de 100 ms dentro del worker mas overhead de red/DB.

### Escenario hotspot

Se ejecuto la distribucion hotspot obligatoria:

```text
run_id = fb7f61c9-52eb-45f2-91a8-a2af64073f6e
requests = 1200
rate = 120 req/s
mode = numbered
distribution = hotspot
```

Resultado:

```text
completed = 1200
sold = 1128
seat_unavailable = 72
errors = 0
throughput_experiment = 30.23 req/s
end_to_end_p50 = 14.69s
end_to_end_p95 = 28.25s
```

Interpretacion:

- Hotspot aumenta claramente las colisiones logicas de asiento: 72 rechazos frente a 6 en uniforme comparable.
- La correccion se mantiene: no hay overselling, no hay errores tecnicos y DLQ queda a 0.
- PostgreSQL resuelve la contencion con UPDATE condicional y constraints; las peticiones conflictivas terminan como `seat_unavailable`.

### Tolerancia a fallos: DLQ

Se publico manualmente un mensaje invalido en RabbitMQ:

```text
payload = esto-no-es-json
exchange = tickets.exchange
routing_key = ticket.buy
```

Resultado:

```text
RabbitMQ routed = true
SQS DLQ visible messages = 1
DLQ reason = permanent_message_error
DLQ error = Message body is not valid UTF-8 JSON
```

Interpretacion:

- El worker detecta errores permanentes.
- Hace ack del mensaje original para que RabbitMQ no lo reintente indefinidamente.
- Envia evidencia a SQS DLQ para inspeccion posterior.

### Tolerancia a fallos: idempotencia

Se publicaron dos mensajes validos con el mismo `request_id`:

```text
run_id = 6a7081f2-702c-43bb-8360-2bc028c2be61
request_id = 7106a204-7f1f-4932-9153-5ecbcd5b197b
seat_id = 4242
publicaciones RabbitMQ = 2
```

Resultado en PostgreSQL:

```text
requests = 1
completed = 1
sales_for_request = 1
status = completed
result = sold
attempts = 1
```

Interpretacion:

- La clave primaria `request_id` evita duplicar la request.
- `sales.request_id UNIQUE` y la logica idempotente evitan doble venta.
- RabbitMQ puede entregar duplicados, pero PostgreSQL mantiene la correccion.

### Incidencia operativa encontrada

Una ejecucion de loadgen estable fallo antes de arrancar el contenedor:

```text
stopCode = TaskFailedToStart
stoppedReason = CannotPullContainerError contra ECR por i/o timeout
```

No publico mensajes y PostgreSQL quedo vacio. Se reintento con un run nuevo y funciono.

Se corrigio `scripts/run-loadgen-aws.ps1` para que, si ECS no entrega `exitCode`, muestre `stopCode`, `stoppedReason` y `containerReason` en vez de un error vacio.

### Implicacion para el scaler

Parametro inicial defendible:

```text
C = 7.9 mensajes/segundo por worker
```

Para evitar ir al limite, el scaler deberia usar margen de seguridad. Ejemplo inicial:

```text
capacidad_segura_por_worker = 6.5 req/s
workers_necesarios = ceil(lambda / capacidad_segura_por_worker)
```

Tambien conviene combinarlo con backlog:

```text
workers_por_backlog = ceil(backlog / (target_response_time * capacidad_segura_por_worker))
workers_finales = max(workers_por_lambda, workers_por_backlog)
```

Esto conecta directamente con el punto 5 del enunciado.

### Estado final tras la tanda

Para controlar coste se bajaron los workers Fargate a cero:

```text
ECS desired = 0
ECS running = 0
ECS pending = 0
```

El stack base sigue vivo para seguir trabajando sin redeploy completo:

```text
RabbitMQ EC2 vivo
PostgreSQL EC2 vivo
ECR vivo
SQS DLQ viva
ECS cluster vivo sin workers corriendo
```

## 2026-06-08 - Implementacion del autoscaler dinamico ECS/Fargate

### Revision del enunciado

Se reviso el punto 5, que es requisito central:

- Implementar escalado dinamico basado en carga medida.
- Estimar parametros experimentalmente.
- Mapear la formula a ECS/Fargate.

Tambien se reviso el punto 6:

- Workload Z(t) con baja carga, ramp-up, spike, carga alta sostenida y cool-down.
- El sistema debe escalar arriba y abajo, evitando over-provisioning.

### Que se implemento

Se creo el autoscaler real del proyecto:

```text
app/scaler/src/scaler.py
app/scaler/Dockerfile
infra/terraform/scaler_service.tf
scripts/build-push-scaler.ps1
scripts/set-scaler-fast.ps1
scripts/run-scaler-once.ps1
```

Tambien se actualizo Terraform:

- Nuevo ECR repo `ticket-service-scaler`.
- Nuevo ECS task definition `ticket-service-academy-scaler`.
- Nuevo ECS service `ticket-service-academy-scaler`.
- Nuevo CloudWatch log group `/ecs/ticket-service-academy-scaler`.
- Nueva regla de security group para que el scaler lea RabbitMQ Management API por IP privada.

El scaler queda apagado por defecto:

```text
scaler_desired_count = 0
```

Motivo: controlar coste en AWS Academy.

### Formula usada

El scaler implementa las dos formulas pedidas por el enunciado:

```text
workers_by_lambda = ceil(lambda / C)
workers_by_backlog = ceil(B / (Tr * C))
workers_finales = max(workers_by_lambda, workers_by_backlog)
```

Donde:

```text
lambda = tasa de llegada medida en RabbitMQ
B = messages_ready en RabbitMQ
Tr = tiempo objetivo para drenar backlog
C = capacidad segura por worker
```

Parametros actuales:

```text
C real medido ~= 7.9 req/s por worker
C seguro usado = 6.5 req/s por worker
Tr = 10s
min_workers = 0
max_workers = 8
poll = 5s
scale_down_cooldown = 30s
```

### Por que se usa C=6.5

En las pruebas previas se midio:

```text
1 worker ~= 7.9 req/s
2 workers ~= 15.6 req/s
4 workers ~= 30.5 req/s
8 workers ~= 55.0 req/s
```

Como el enunciado dice que el delay artificial de 100 ms debe considerarse en throughput y scaling, `C` no se calcula teoricamente como 10 req/s perfecto. Se usa el valor medido y se aplica margen para no saturar.

### Como conecta

```text
RabbitMQ Management API -> scaler Fargate -> ECS UpdateService -> worker service -> workers Fargate
```

El scaler no vende tickets y no toca PostgreSQL. La correccion sigue siendo responsabilidad del worker y PostgreSQL.

### Workload Z(t) expuesto en scripts

Se amplio `scripts/run-loadgen-aws.ps1` para poder ajustar el perfil Z(t):

```text
ZLowRate, ZRampRate, ZSpikeRate, ZHighRate
ZLowSeconds, ZRampSeconds, ZSpikeSeconds, ZHighSeconds, ZCooldownSeconds
```

Tambien calcula `requested_messages` correctamente en modo `Profile z`, para que `wait-run-complete.ps1` pueda esperar el numero real de requests.

### Prueba funcional ejecutada

Se encendio el scaler Fargate y se dejo el worker service en 0:

```text
scaler desired = 1
workers desired = 0
```

Se lanzo un workload Z(t) reducido:

```text
run_id = f5a12cb3-850e-4d63-99bb-b1701fec2b8b
requests esperadas = 720
low = 2 req/s durante 5s
ramp = 20 req/s durante 5s
spike = 80 req/s durante 4s
high = 35 req/s durante 8s
cool-down = 2 req/s durante 5s
```

Resultado de procesamiento:

```text
completed = 720
sold = 719
seat_unavailable = 1
errored = 0
DLQ = 0
```

Resultado de escalado observado en logs del scaler:

```text
current=0 desired=1 target=1 lambda=0.39
current=1 desired=5 target=5 lambda=30.20 ready=115
current=5 desired=8 target=8 lambda=63.40 ready=468
current=8 desired=7 target=5 ready=270
```

Interpretacion:

- El scaler arranco desde 0 workers.
- Subio a 1, luego a 5 y luego a 8 segun lambda/backlog.
- Cuando la cola empezo a drenarse, inicio scale-down con cooldown.
- No hubo errores tecnicos ni overselling.

### Resultado de metricas

CSV generado:

```text
report/results/summary-elastic-z-smoke-uniform-n-f5a12cb3.csv
report/results/latencies-elastic-z-smoke-uniform-n-f5a12cb3.csv
report/loadgen_runs/loadgen-elastic-z-smoke-uniform-n-f5a12cb3.json
```

Resumen:

```text
experiment_window_seconds = 56.98
throughput_experiment = 12.64 req/s
server_processing_window_seconds = 19.95
throughput_server = 36.08 req/s
processing_p50 = 0.107s
end_to_end_p50 = 36.39s
```

### Hallazgo importante

Escalar desde 0 funciona, pero introduce cold start de Fargate. En esta prueba:

```text
first_enqueued_at = 16:59:21
first_worker_started_at = 16:59:58
```

Es decir, hubo unos 37s hasta que el primer worker empezo a procesar. Esto explica el end-to-end alto aunque el processing interno sea correcto.

Decision defendible para siguientes pruebas:

- Para minimizar coste: `min_workers=0`.
- Para reducir latencia inicial: `min_workers=1` durante la ventana de experimento.
- En el informe se puede discutir este trade-off como elasticidad vs latencia/coste.

### Estado final

Para controlar coste se paro todo lo elastico:

```text
worker desired = 0
worker running = 0
scaler desired = 0
scaler running = 0
```

Se limpio RabbitMQ, PostgreSQL y SQS DLQ tras la prueba.

## 2026-06-08 - Datasets finales para graficas de scaling

### Pregunta resuelta

Se evaluo si habia que repetir todas las pruebas. Decision:

- No repetir toda la capacidad, porque no cambio la logica del worker ni el delay de 100 ms ni la forma de venta en PostgreSQL.
- Si repetir las pruebas de scaling, porque se implemento el autoscaler y necesitabamos series temporales limpias de backlog/workers.

### Problema detectado y corregido

Se creo `scripts/monitor-scaling.ps1` para generar CSV de backlog y workers durante Z(t).

Primera version del monitor escribia decimales con coma por locale espa?ol de PowerShell:

```text
0,015
```

Eso rompia el CSV porque la coma tambien separa columnas. Se corrigio usando cultura invariante para escribir decimales con punto:

```text
0.015
```

### Pruebas finales ejecutadas

Perfil Z(t) usado en ambas:

```text
low = 2 req/s durante 5s
ramp = 20 req/s durante 5s
spike = 80 req/s durante 4s
high = 35 req/s durante 8s
cool-down = 2 req/s durante 5s
expected_requests = 720
mode = numbered
distribution = uniform
```

#### Baseline sin autoscaling

```text
run_id = f029fc7a-49b8-4c91-91c6-f1ecdd53d24f
workers = 1 fijo
scaler = apagado
```

Resultados:

```text
completed = 720
sold = 719
seat_unavailable = 1
errored = 0
throughput_experiment = 7.47 req/s
end_to_end_p50 = 37.26s
end_to_end_p95 = 70.47s
max_ready = 555
max_worker_running = 1
```

#### Autoscaling

```text
run_id = f9026410-d0d4-4480-ad47-494b6d3e1486
scaler = encendido
min_workers = 1
max_workers = 8
```

Resultados:

```text
completed = 720
sold = 719
seat_unavailable = 1
errored = 0
throughput_experiment = 15.69 req/s
end_to_end_p50 = 24.89s
end_to_end_p95 = 26.72s
max_ready = 554
max_worker_running = 8
```

### Interpretacion

El autoscaler no evita que el spike cree backlog inicial, porque la llegada es muy rapida y Fargate tarda en arrancar tasks. Lo que si mejora claramente es el drenado de cola:

```text
baseline 1 worker: p95 end-to-end ~= 70s
autoscale hasta 8 workers: p95 end-to-end ~= 27s
```

Esto demuestra elasticidad real y conecta directamente con el punto 5 y 6 del enunciado.

### Archivos preparados para graficas

```text
report/results/throughput-vs-workers.csv
report/results/scaling-comparison-final.csv
report/results/scaling-timeseries-baseline-z-w1-final-f029fc7a.csv
report/results/scaling-timeseries-autoscale-z-min1-final-f9026410.csv
report/results/scaling-timeseries-summary-final.csv
report/results/latencies-baseline-z-w1-final-uniform-n-f029fc7a.csv
report/results/latencies-autoscale-z-min1-final-uniform-n-f9026410.csv
report/results/README_scaling_results.md
```

### Estado final

Se paro todo lo elastico y se limpio estado de test:

```text
worker desired = 0
worker running = 0
scaler desired = 0
scaler running = 0
RabbitMQ/PostgreSQL/SQS limpios
```

## 2026-06-08 - Graficas para el informe

### Que se hizo

Se genero un conjunto completo de figuras para el informe a partir de los CSV ya preparados en `report/results`.

Script reproducible:

```text
report/generate_figures.py
```

Dependencias locales:

```text
report/requirements.txt
```

Comando:

```powershell
.\.venv\Scripts\python.exe report\generate_figures.py
```

### Figuras generadas

```text
report/figures/01_throughput_vs_workers.png
report/figures/02_speedup_efficiency.png
report/figures/03_capacity_latency_percentiles.png
report/figures/04_scaling_backlog_workers.png
report/figures/05_scaling_throughput_latency_comparison.png
report/figures/06_latency_cdf_baseline_vs_autoscale.png
report/figures/07_uniform_vs_hotspot.png
report/figures/08_steady_vs_saturated_w4.png
```

### Documento de interpretacion

Se creo:

```text
report/figures/analisis_graficas.md
```

Explica que muestra cada grafica, que conclusion aporta y como defenderla en el informe.

### Lectura principal

- Throughput escala casi linealmente hasta 4 workers y pierde algo de eficiencia en 8.
- El autoscaler mejora throughput global de Z(t) de `7.47 req/s` a `15.69 req/s`.
- El p95 end-to-end baja de `70.47s` a `26.72s` con autoscaling.
- Hotspot aumenta `seat_unavailable`, pero no genera overselling ni errores tecnicos.
- El processing interno se mantiene cerca de `0.105s`, coherente con el delay obligatorio de 100 ms.

### Estado

No se tocaron recursos AWS en este paso. Solo se procesaron CSV locales y se generaron PNG/MD para el informe.

## 2026-06-08 - Cierre completo del stack AWS Academy

### Motivo

El usuario indico que iba a cerrar AWS Academy y pidio apagar todo el stack completamente para evitar gasto.

### Accion ejecutada

Primero se forzo a cero todo lo elastico:

```powershell
.\scripts\set-scaler-fast.ps1 -DesiredCount 0 -NoWait
.\scripts\set-workers-fast.ps1 -DesiredCount 0
```

Despues se destruyo todo lo gestionado por Terraform, incluyendo scaler:

```powershell
terraform -chdir=infra/terraform destroy -auto-approve `
  -var enable_core_infra=true `
  -var enable_worker_service=true `
  -var enable_scaler_service=true `
  -var operator_cidr=86.127.229.77/32 `
  -var worker_desired_count=0 `
  -var scaler_desired_count=0
```

### Recursos destruidos

Terraform destruyo 20 recursos:

```text
EC2 RabbitMQ
EC2 PostgreSQL
ECS cluster
ECS worker service
ECS scaler service
ECS task definitions worker/loadgen/scaler
ECR worker/loadgen/scaler
CloudWatch log groups worker/loadgen/scaler
SQS DLQ
Security groups workers/rabbitmq/postgres
Random passwords
```

### Verificacion posterior

Comprobaciones independientes con AWS CLI:

```text
EC2 tagged Project=ticket-service: none
ECR repositories ticket-service*: none
ECS clusters ticket-service*: none
SQS queues ticket-service*: none
CloudWatch log groups /ecs/ticket-service*: none
EBS volumes tagged Project=ticket-service: none
terraform state list: empty
```

### Estado final

No queda infraestructura del proyecto encendida en AWS Academy segun Terraform y AWS CLI.

Los resultados, CSV, graficas y documentacion quedan en local dentro del repositorio.

## 2026-06-08 - Guia para redactar el informe final

### Que se hizo

Se creo una guia completa para redactar `report/final_report.md`:

```text
report/guia_informe_final.md
```

Incluye:

- Estructura recomendada del informe.
- Requisitos del enunciado mapeados a componentes del proyecto.
- Que explicar en arquitectura, correctness, scaling, fault tolerance y metricas.
- Figuras que deben entrar obligatoriamente.
- Numeros clave para memorizar.
- Respuestas a preguntas probables del profesor.
- Checklist final antes de entregar.

### Uso recomendado

Usar este documento como plantilla de contenido para completar `report/final_report.md` sin perder ningun punto obligatorio del enunciado.

## 2026-06-09 - Tanda de scaling con max_workers=32

### Que se hizo

Se volvio a desplegar el stack en AWS Academy con Terraform usando `max_workers=32`:

```text
RabbitMQ EC2
PostgreSQL EC2
ECS/Fargate worker service
ECS/Fargate scaler service
ECS task loadgen
SQS DLQ
ECR worker/loadgen/scaler
CloudWatch logs
```

Se reconstruyeron y subieron las imagenes Docker de worker, loadgen y scaler a ECR.

### Pruebas ejecutadas

Se ejecutaron dos tandas de autoscaling:

- Perfil original Z: 720 mensajes, pico 80 msg/s, autoscale max32.
- Perfil aggressive Z: 2570 mensajes, pico 250 msg/s, baseline 1 worker y autoscale max32.

Antes de cada prueba se limpio RabbitMQ, PostgreSQL y SQS DLQ para que los datos no arrastrasen estado anterior.

### Resultados importantes

```text
Original autoscale max32:
completed=720/720
errors=0
max_desired=9
max_running=8
p95_end_to_end=35.43s

Aggressive baseline 1 worker:
completed=2570/2570
errors=0
max_running=1
p95_end_to_end=292.88s

Aggressive autoscale max32:
completed=2570/2570
errors=0
max_desired=32
max_running=32
p95_end_to_end=42.21s
throughput_end_to_end=39.75 req/s
```

### Por que importa

El perfil original no necesita 32 workers: la formula del scaler solo pidio hasta 9 desired y llegaron a correr 8. Esto demuestra que subir el limite no implica gastar siempre mas, depende de lambda y backlog.

El perfil aggressive si fuerza el sistema: el scaler llega al cap de 32 workers y reduce el p95 end-to-end de 292.88s a 42.21s. Esta es la evidencia mas fuerte para defender el punto de autoscaling del enunciado.

### Artefactos generados

```text
report/results/scaling-comparison-max32.csv
report/results/scaling-timeseries-summary-max32.csv
report/figures/max32/01_original_profile_max8_vs_max32.png
report/figures/max32/02_original_profile_throughput_latency.png
report/figures/max32/03_aggressive_profile_backlog_workers.png
report/figures/max32/04_aggressive_profile_throughput_latency.png
report/figures/max32/05_original_profile_latency_cdf.png
report/figures/max32/06_aggressive_profile_latency_cdf.png
report/figures/max32/07_scaler_formula_terms_aggressive.png
report/figures/max32/08_worker_growth_original_max32.png
report/figures/max32/09_worker_growth_aggressive_max32.png
report/figures/max32/10_outcomes_processing_latency.png
report/figures/max32/analisis_graficas_max32.md
```
