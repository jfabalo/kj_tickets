<#
.SYNOPSIS
  Cambia rapido desired_count del servicio ECS autoscaler.

.DESCRIPTION
  Explicacion simple:
    Enciende o apaga el scaler sin hacer `terraform apply`, igual que hacemos con
    los workers durante pruebas.

  Explicacion tecnica:
    Usa AWS CLI `ecs update-service` sobre el servicio `ticket-service-*-scaler`.
    Se usa para controlar coste: `DesiredCount 0` apaga el scaler; `1` lo deja
    tomando decisiones periodicas.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateRange(0, 1)]
    [int]$DesiredCount,
    [string]$TerraformDir = "infra/terraform",
    [switch]$NoWait
)

$ErrorActionPreference = "Stop"

$cluster = terraform "-chdir=$TerraformDir" output -raw worker_cluster_name
$service = terraform "-chdir=$TerraformDir" output -raw scaler_service_name 2>$null
if ($LASTEXITCODE -ne 0 -or -not $service -or $service -eq "null") {
    throw "scaler_service_name is not available. Apply Terraform with -var enable_scaler_service=true first."
}

Write-Host "Fast scaling autoscaler service $service to desired=$DesiredCount" -ForegroundColor Cyan
# Igual que set-workers-fast, cambia capacidad operativa sin Terraform.
# DesiredCount=1 activa decisiones periodicas; 0 detiene el scaler.
aws ecs update-service `
    --cluster $cluster `
    --service $service `
    --desired-count $DesiredCount `
    --query "service.{status:status,desired:desiredCount,running:runningCount,pending:pendingCount}" `
    --output table
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

if (-not $NoWait) {
    aws ecs wait services-stable --cluster $cluster --services $service
    aws ecs describe-services `
        --cluster $cluster `
        --services $service `
        --query "services[0].{status:status,desired:desiredCount,running:runningCount,pending:pendingCount}" `
        --output table
}

