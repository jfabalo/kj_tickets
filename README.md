# Ticket Service - AWS Academy

Sistema distribuido de venta de tickets implementado con Terraform sobre AWS Academy.

## Arquitectura

- RabbitMQ en EC2 como cola asincrona principal.
- PostgreSQL en EC2 como fuente de verdad transaccional.
- Workers stateless en ECS Fargate.
- Load generator en ECS Fargate para ejecutar pruebas dentro de AWS.
- Autoscaler en ECS Fargate basado en backlog y tasa de llegada de RabbitMQ.
- SQS DLQ para fallos definitivos.
- CloudWatch Logs para observabilidad operativa.

## Requisitos locales

- AWS CLI.
- Terraform.
- Docker Desktop para construir y subir imagenes a ECR.
- PowerShell.
- Python virtualenv para scripts locales de limpieza/exportacion y generacion de graficas.

Preparar el entorno Python local:

```powershell
py -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r app\loadgen\requirements.txt -r report\requirements.txt
```

## Credenciales AWS Academy

Crear localmente `aws-academy-credentials.txt` con las credenciales temporales del laboratorio y cargarlo en la terminal:

```powershell
Set-ExecutionPolicy Bypass -Scope Process
. .\scripts\set-academy-env.ps1 -CredentialsFile .\aws-academy-credentials.txt
aws sts get-caller-identity
```

El archivo de credenciales esta ignorado por Git y no debe entregarse con secretos.

## Despliegue

Despliegue completo, dejando workers y scaler apagados por defecto:

```powershell
.\scripts\deploy.ps1 -OperatorCidr "<tu-ip-publica>/32"
```

Si las imagenes ya estan subidas a ECR:

```powershell
.\scripts\deploy.ps1 -OperatorCidr "<tu-ip-publica>/32" -SkipDockerBuild
```

## Operacion de pruebas

Para una secuencia manual pensada para la entrevista, usar `GUIA_ENTREVISTA.md`.

Arrancar o parar workers sin ejecutar Terraform:

```powershell
.\scripts\set-workers-fast.ps1 -DesiredCount 1
.\scripts\set-workers-fast.ps1 -DesiredCount 0 -NoWait
```

Arrancar o parar el autoscaler:

```powershell
.\scripts\set-scaler-fast.ps1 -DesiredCount 1
.\scripts\set-scaler-fast.ps1 -DesiredCount 0 -NoWait
```

Ejecutar el load generator en AWS:

```powershell
.\scripts\run-loadgen-aws.ps1 -Profile z -Mode numbered -Distribution uniform -RunName "autoscale-z"
```

Recoger resultados de un run:

```powershell
.\scripts\wait-run-complete.ps1 -RunId "<run_id>" -ExpectedRequests 720
.\scripts\collect-run-results.ps1 -RunId "<run_id>" -RunName "autoscale-z"
```

Monitorizar backlog y workers durante una prueba:

```powershell
.\scripts\monitor-scaling.ps1 -RunName "autoscale-z" -DurationSeconds 180
```

## Limpieza y destruccion

Limpiar estado entre experimentos:

```powershell
.\scripts\clean-test-state.ps1
```

Destruir toda la infraestructura al terminar:

```powershell
.\scripts\destroy.ps1 -OperatorCidr "<tu-ip-publica>/32"
```

## Informe y graficas

Los datos experimentales estan en `report/results` y las figuras en `report/figures`.

Regenerar figuras:

```powershell
.\.venv\Scripts\python.exe report\generate_figures.py
.\.venv\Scripts\python.exe report\generate_figures_max32.py
.\.venv\Scripts\python.exe report\generate_completion_comparison.py
```
