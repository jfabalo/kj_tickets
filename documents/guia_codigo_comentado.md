# Guia de codigo comentado

## Idea general

El sistema vende tickets de forma asincrona:

```text
loadgen -> RabbitMQ -> worker Fargate -> PostgreSQL
                         |
                         v
                       SQS DLQ
```

El loadgen no vende tickets. Solo genera compras de prueba. El worker es el que aplica la transaccion de venta.

## Archivos principales

### `app/worker/src/worker.py`

Contiene la logica real de venta.

Puntos que debes saber defender:

- Se conecta a RabbitMQ en `connect_rabbitmq()`.
- Consume de `tickets.buy` con `auto_ack=False`.
- Usa `request_id` para idempotencia.
- Bloquea cada request con `SELECT ... FOR UPDATE`.
- Aplica el delay obligatorio de 100 ms dentro del worker.
- Evita overselling con `UPDATE ... WHERE status='available'` en numbered y `sold_count < total_tickets` en unnumbered.
- Envia fallos permanentes a SQS DLQ.

### `app/loadgen/src/loadgen.py`

Genera carga controlada.

Puntos clave:

- Perfil `constant`: N requests a tasa fija.
- Perfil `z`: baja carga, ramp-up, spike, alta sostenida y cool-down.
- Distribucion `uniform`: asientos aleatorios.
- Distribucion `hotspot`: concentra carga en pocos asientos para probar contencion.
- Registra `enqueued_at` en PostgreSQL antes de publicar a RabbitMQ.
- Esto permite medir `end_to_end = completed_at - enqueued_at` con reloj PostgreSQL.

### `infra/terraform/core_infra.tf`

Crea la base persistente:

- RabbitMQ EC2.
- PostgreSQL EC2.
- ECR worker/loadgen.
- SQS DLQ.
- Security groups.

### `infra/terraform/worker_service.tf`

Crea el ECS service de workers Fargate.

Puntos clave:

- `worker_desired_count` controla cuantos workers corren.
- Terraform inyecta IPs privadas de RabbitMQ/PostgreSQL.
- `PAYMENT_DELAY_MS=100` cumple el requisito de realismo.
- Logs van a `/ecs/ticket-service-academy-worker`.

### `infra/terraform/loadgen_task.tf`

Crea la task definition del loadgen.

Puntos clave:

- No es un service permanente.
- Se lanza con `aws ecs run-task`.
- Usa imagen ECR separada.
- Logs van a `/ecs/ticket-service-academy-loadgen`.

## Scripts operativos

### `scripts/run-loadgen-aws.ps1`

Camino recomendado para tests. Limpia estado y lanza loadgen como task Fargate temporal.

### `scripts/clean-test-state.ps1`

Limpia RabbitMQ, PostgreSQL y SQS DLQ para evitar metricas mezcladas.

### `scripts/collect-run-results.ps1`

Genera:

```text
summary-*.csv
latencies-*.csv
```

Usa PostgreSQL y filtra por `run_id`.

### `scripts/observe.ps1`

Muestra snapshot global:

- ECS service/tasks.
- Logs recientes.
- Backlog RabbitMQ.
- Resumen PostgreSQL.
- Estado SQS DLQ.

### `scripts/set-workers.ps1`

Escala manualmente workers a 0, 1, 4, etc. Sirve para ahorrar sin destruir todo.

## Validaciones hechas

```text
python -m py_compile: OK
PowerShell parser scripts/*.ps1: OK
terraform fmt -check: OK
terraform validate: OK
```
