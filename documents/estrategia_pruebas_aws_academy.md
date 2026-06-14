# Estrategia de sesiones de prueba en AWS Academy

## Problema

Crear RabbitMQ EC2, PostgreSQL EC2, ECR, ECS, CloudWatch y SQS desde cero tarda varios minutos. Para pruebas repetidas no conviene destruir todo despues de cada carga pequena.

## Politica recomendada

Durante una sesion activa de trabajo:

- Mantener RabbitMQ EC2 encendido.
- Mantener PostgreSQL EC2 encendido.
- Mantener ECR y SQS DLQ creados.
- Mantener ECS creado.
- Escalar workers Fargate a `0` cuando no se este procesando carga.
- Escalar workers Fargate a `1..N` cuando se vaya a ejecutar un experimento.

Al terminar el bloque de trabajo o antes de cerrar AWS Academy:

- Ejecutar `terraform destroy`.
- Verificar que no quedan EC2 running, ECS services, SQS queues, ECR repos ni log groups del proyecto.

## Comandos

Pausar workers, dejando RabbitMQ/PostgreSQL vivos:

```powershell
.\scripts\set-workers.ps1 -DesiredCount 0
```

Reanudar con un worker:

```powershell
.\scripts\set-workers.ps1 -DesiredCount 1
```

Subir a cuatro workers para experimento:

```powershell
.\scripts\set-workers.ps1 -DesiredCount 4
```

Destruir al final:

```powershell
terraform -chdir=infra/terraform destroy -auto-approve -var enable_core_infra=true -var enable_worker_service=true -var operator_cidr=86.127.229.77/32 -var worker_desired_count=0
```

## Coste

Esta estrategia reduce tiempo de iteracion, pero no es coste cero:

- EC2 RabbitMQ y EC2 PostgreSQL siguen facturando mientras esten running.
- EBS sigue existiendo.
- Public IPv4 puede tener coste.
- Fargate no procesa ni factura tasks si `desired_count=0`.

Regla practica: dejarlo vivo durante una sesion de pruebas; destruirlo al acabar el dia o cuando no vayamos a usarlo durante un rato largo.

## Ubicacion de resultados

Los CSV se guardan por `run_id`:

```text
report/results/summary-<test>-<distribution>-<mode>-<id8>.csv
report/results/latencies-<test>-<distribution>-<mode>-<id8>.csv
```

El resumen local del productor se guarda en:

```text
report/loadgen_runs/loadgen-<test>-<distribution>-<mode>-<id8>.json
```



