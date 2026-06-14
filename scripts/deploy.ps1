<#
.SYNOPSIS
  Despliega la infraestructura real del Ticket Service en AWS Academy.

.DESCRIPTION
  Explicacion simple:
    Crea RabbitMQ/PostgreSQL/ECR/SQS/ECS con Terraform, sube las imagenes Docker
    y deja los servicios ECS creados. Por defecto los workers y el scaler quedan
    apagados para no gastar Fargate hasta lanzar pruebas.

  Explicacion tecnica:
    Terraform necesita crear primero los repositorios ECR. Despues se construyen
    y publican worker/loadgen/scaler, y finalmente se aplica otra vez Terraform
    para crear las task definitions y services que referencian esas imagenes.
#>

[CmdletBinding()]
param(
    [string]$TerraformDir = "infra/terraform",
    [string]$OperatorCidr = "0.0.0.0/32",
    [int]$WorkerDesiredCount = 0,
    [int]$ScalerDesiredCount = 0,
    [int]$MaxWorkers = 8,
    [switch]$SkipDockerBuild
)

$ErrorActionPreference = "Stop"

# Paso 0: descarga providers y prepara .terraform localmente.
terraform "-chdir=$TerraformDir" init
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

# Paso 1: creamos solo la infraestructura base.
# Motivo: los repositorios ECR deben existir antes de poder hacer docker push.
terraform "-chdir=$TerraformDir" apply -auto-approve `
    -var enable_core_infra=true `
    -var enable_worker_service=false `
    -var enable_scaler_service=false `
    -var operator_cidr=$OperatorCidr `
    -var max_workers=$MaxWorkers
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

if (-not $SkipDockerBuild) {
    # Paso 2: publicamos imagenes Docker en los ECR creados en el paso anterior.
    # Si se cambia codigo Python, este bloque es el que actualiza lo que ECS ejecuta.
    .\scripts\build-push-worker.ps1 -TerraformDir $TerraformDir
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    .\scripts\build-push-loadgen.ps1 -TerraformDir $TerraformDir
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    .\scripts\build-push-scaler.ps1 -TerraformDir $TerraformDir
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

# Paso 3: creamos task definitions y services ECS apuntando a las imagenes ECR.
# Por defecto se dejan desired_count=0 para no gastar Fargate hasta lanzar tests.
terraform "-chdir=$TerraformDir" apply -auto-approve `
    -var enable_core_infra=true `
    -var enable_worker_service=true `
    -var enable_scaler_service=true `
    -var operator_cidr=$OperatorCidr `
    -var worker_desired_count=$WorkerDesiredCount `
    -var scaler_desired_count=$ScalerDesiredCount `
    -var max_workers=$MaxWorkers
exit $LASTEXITCODE
