# Chuleta rapida AWS Academy

Estado recomendado entre pruebas: stack vivo, workers pausados (`desired=0`).

## 1. Credenciales

```powershell
Set-ExecutionPolicy Bypass -Scope Process; . .\scripts\set-academy-env.ps1 -CredentialsFile .\aws-academy-credentials.txt
aws sts get-caller-identity
```

## 2. Ver estado

```powershell
terraform -chdir=infra/terraform output
.\scripts\observe.ps1 -LogLimit 20
```

## 3. Iniciar / parar workers rapido

```powershell
.\scripts\set-workers-fast.ps1 -DesiredCount 1
.\scripts\set-workers-fast.ps1 -DesiredCount 4
.\scripts\set-workers-fast.ps1 -DesiredCount 0
```

Esto usa AWS CLI directo y evita `terraform apply`.

Para reconciliar Terraform al final si hace falta:

```powershell
.\scripts\set-workers.ps1 -DesiredCount 0
```

## 4. Limpiar antes de un test

Limpia RabbitMQ, PostgreSQL y SQS DLQ:

```powershell
.\scripts\clean-test-state.ps1
```

Solo RabbitMQ:

```powershell
.\scripts\clean-test-state.ps1 -SkipPostgres -SkipSqs
```

Solo PostgreSQL:

```powershell
.\scripts\clean-test-state.ps1 -SkipRabbitMQ -SkipSqs
```

Solo SQS DLQ:

```powershell
.\scripts\clean-test-state.ps1 -SkipRabbitMQ -SkipPostgres
```

## 5. Build/push del loadgen AWS

Solo hace falta si cambia `app/loadgen`:

```powershell
.\scripts\build-push-loadgen.ps1
```

## 6. Smoke test recomendado desde AWS

`run-loadgen-aws.ps1` limpia RabbitMQ, PostgreSQL y SQS antes de lanzar el test.

```powershell
$runId = [guid]::NewGuid().ToString()
.\scripts\set-workers-fast.ps1 -DesiredCount 1
.\scripts\run-loadgen-aws.ps1 -RunName smoke -Requests 10 -Rate 5 -Mode numbered -Distribution uniform -ReportEvery 5 -RunId $runId
.\scripts\collect-run-results.ps1 -RunId $runId
.\scripts\observe.ps1 -LogLimit 30
.\scripts\set-workers-fast.ps1 -DesiredCount 0
```

Si por algun motivo no quieres limpiar antes del test:

```powershell
.\scripts\run-loadgen-aws.ps1 -SkipClean
```

## 7. Test local, solo si hace falta

AWS/Fargate es el camino recomendado. Este comando queda como fallback:

```powershell
$runId = [guid]::NewGuid().ToString()
.\scripts\run-loadgen.ps1 -RunName local-smoke -Requests 10 -Rate 5 -Mode numbered -Distribution uniform -ReportEvery 5 -RunId $runId
.\scripts\collect-run-results.ps1 -RunId $runId
```

## 8. Donde mirar resultados

```text
report/results/summary-<test>-<distribution>-<mode>-<id8>.csv
report/results/latencies-<test>-<distribution>-<mode>-<id8>.csv
report/loadgen_runs/loadgen-<test>-<distribution>-<mode>-<id8>.json
```

Ejemplo:

```text
summary-smoke-uniform-n-ba063552.csv
latencies-smoke-uniform-n-ba063552.csv
loadgen-smoke-uniform-n-ba063552.json
```

`n` = numbered. `un` = unnumbered.

## 9. Ahorrar rapido

```powershell
.\scripts\set-workers-fast.ps1 -DesiredCount 0
```

Esto para Fargate. RabbitMQ/PostgreSQL siguen vivos y gastan algo.

## 10. Destruir todo al terminar

```powershell
terraform -chdir=infra/terraform destroy -auto-approve -var enable_core_infra=true -var enable_worker_service=true -var operator_cidr=86.127.229.77/32 -var worker_desired_count=0
```

Regla: durante una tanda de pruebas no destruir todo; solo workers a `0`. Al acabar el dia o si no vas a seguir, destruir todo.

## 11. Autoscaler ECS/Fargate

Crear/actualizar infra del scaler apagado:

```powershell
$ip = (Invoke-RestMethod -Uri 'https://checkip.amazonaws.com').Trim()
terraform -chdir=infra/terraform apply -auto-approve -var enable_core_infra=true -var enable_worker_service=true -var enable_scaler_service=true -var operator_cidr="$ip/32" -var worker_desired_count=0 -var scaler_desired_count=0
```

Subir imagen si cambia `app/scaler`:

```powershell
.\scripts\build-push-scaler.ps1
```

Probar una decision sin tocar ECS:

```powershell
.\scripts\run-scaler-once.ps1
```

Aplicar una decision puntual desde local:

```powershell
.\scripts\run-scaler-once.ps1 -Apply
```

Encender/apagar scaler Fargate:

```powershell
.\scripts\set-scaler-fast.ps1 -DesiredCount 1
.\scripts\set-scaler-fast.ps1 -DesiredCount 0
```

Regla de coste: al terminar una prueba elastica, parar scaler y workers:

```powershell
.\scripts\set-scaler-fast.ps1 -DesiredCount 0
.\scripts\set-workers-fast.ps1 -DesiredCount 0
```

## 12. Workload elastico Z(t) con scaler

Ejemplo reducido para validar escalado dinamico:

```powershell
$runId = [guid]::NewGuid().ToString()
.\scripts\set-workers-fast.ps1 -DesiredCount 0
.\scripts\set-scaler-fast.ps1 -DesiredCount 1
.\scripts\run-loadgen-aws.ps1 -RunName elastic-z-smoke -Profile z -Mode numbered -Distribution uniform -Requests 1 -Rate 1 -ReportEvery 120 -ZLowRate 2 -ZRampRate 20 -ZSpikeRate 80 -ZHighRate 35 -ZLowSeconds 5 -ZRampSeconds 5 -ZSpikeSeconds 4 -ZHighSeconds 8 -ZCooldownSeconds 5 -RunId $runId
.\scripts\wait-run-complete.ps1 -RunId $runId -ExpectedRequests 720
.\scripts\collect-run-results.ps1 -RunId $runId
.\scripts\set-scaler-fast.ps1 -DesiredCount 0
.\scripts\set-workers-fast.ps1 -DesiredCount 0
```

Formula defendible:

```text
workers_by_lambda = ceil(lambda / 6.5)
workers_by_backlog = ceil(backlog / (10 * 6.5))
workers = clamp(max(workers_by_lambda, workers_by_backlog), 0, 8)
```

Destroy completo incluyendo scaler:

```powershell
terraform -chdir=infra/terraform destroy -auto-approve -var enable_core_infra=true -var enable_worker_service=true -var enable_scaler_service=true -var operator_cidr=86.127.229.77/32 -var worker_desired_count=0 -var scaler_desired_count=0
```
