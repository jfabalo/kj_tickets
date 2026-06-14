<#
.SYNOPSIS
  Cambia desired_count del ECS worker service usando AWS CLI, sin terraform apply.

.DESCRIPTION
  Explicacion simple:
    Este es el comando rapido para pruebas. Arranca o para workers en segundos
    sin refrescar todo el estado Terraform.

  Explicacion tecnica:
    Lee `worker_cluster_name` y `worker_service_name` desde Terraform outputs,
    pero no ejecuta `terraform apply`. Llama directamente a
    `aws ecs update-service --desired-count`. Esto es mucho mas rapido para
    ciclos de test, pero introduce drift temporal: Terraform state puede seguir
    teniendo otro `worker_desired_count` hasta el siguiente apply.

  Uso recomendado:
    - Durante una tanda de pruebas: este script.
    - Para reconciliar Terraform al final: volver a ejecutar scripts/deploy.ps1
      con el worker_desired_count deseado o destruir el stack completo.
#>

[CmdletBinding()]
param(
    [ValidateRange(0, 100)]
    [int]$DesiredCount = 1,
    [string]$TerraformDir = "infra/terraform",
    [switch]$NoWait
)

$ErrorActionPreference = "Stop"

function TfOutput {
    param([string]$Name)
    $value = terraform "-chdir=$TerraformDir" output -raw $Name 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $value) {
        throw "Terraform output '$Name' is not available."
    }
    return $value.Trim()
}

$cluster = TfOutput "worker_cluster_name"
$service = TfOutput "worker_service_name"

Write-Host "Fast scaling ECS service $service to desired=$DesiredCount" -ForegroundColor Cyan
# Cambio operativo rapido: evita terraform plan/apply cuando solo queremos
# encender/apagar workers entre pruebas. Genera drift temporal asumido.
aws ecs update-service `
    --cluster $cluster `
    --service $service `
    --desired-count $DesiredCount `
    --query "service.{status:status,desired:desiredCount,running:runningCount,pending:pendingCount}" `
    --output table

if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

if (-not $NoWait) {
    # Espera a que ECS estabilice desired/running/pending. Con -NoWait se usa
    # para apagar rapido al cerrar AWS Academy.
    aws ecs wait services-stable --cluster $cluster --services $service
}

aws ecs describe-services `
    --cluster $cluster `
    --services $service `
    --query "services[0].{status:status,desired:desiredCount,running:runningCount,pending:pendingCount}" `
    --output table
