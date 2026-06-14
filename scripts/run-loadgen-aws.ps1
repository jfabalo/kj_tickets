<#
.SYNOPSIS
  Ejecuta el load generator como una task temporal ECS/Fargate dentro de AWS.

.DESCRIPTION
  Explicacion simple:
    Este script lanza el cliente de pruebas en AWS, no en el portatil. La task
    publica compras en RabbitMQ y registra el inicio de cada request en
    PostgreSQL. Cuando termina, la task queda en STOPPED y no queda consumiendo
    Fargate.

  Explicacion tecnica:
    Lee outputs de Terraform para localizar el cluster ECS, la task definition
    del loadgen, las subnets y el security group. Antes de lanzar el test limpia
    RabbitMQ/PostgreSQL/SQS salvo que se indique -SkipClean. Usa `aws ecs
    run-task` con un override de comando para pasar modo, distribucion, tasa y
    run_id. Luego espera `tasks-stopped` y escribe un JSON local con el ARN y el
    exit code del contenedor.

  Conecta con:
    - Terraform outputs: nombres/ARNs de infraestructura.
    - ECS/Fargate: ejecucion one-shot del loadgen.
    - clean-test-state.ps1: limpieza previa de colas y base de datos.
    - report/loadgen_runs: artefacto JSON de trazabilidad.
#>

[CmdletBinding()]
param(
    [string]$TerraformDir = "infra/terraform",
    [ValidateSet("constant", "z")]
    [string]$Profile = "constant",
    [ValidateSet("numbered", "unnumbered")]
    [string]$Mode = "numbered",
    [ValidateSet("uniform", "hotspot")]
    [string]$Distribution = "uniform",
    [int]$Requests = 100,
    [double]$Rate = 10.0,
    [int]$ReportEvery = 100,
    [int]$SeatCount = 100000,
    [double]$ZLowRate = 5.0,
    [double]$ZRampRate = 25.0,
    [double]$ZSpikeRate = 80.0,
    [double]$ZHighRate = 40.0,
    [double]$ZLowSeconds = 10.0,
    [double]$ZRampSeconds = 20.0,
    [double]$ZSpikeSeconds = 8.0,
    [double]$ZHighSeconds = 20.0,
    [double]$ZCooldownSeconds = 10.0,
    [double]$HotspotRequestFraction = 0.80,
    [double]$HotspotSeatFraction = 0.05,
    [string]$RunId = "",
    [string]$RunName = "aws",
    [string]$SummaryDir = "report/loadgen_runs",
    [switch]$SkipClean
)

$ErrorActionPreference = "Stop"

function TfOutput {
    param([string]$Name)
    # Los scripts no hardcodean IPs ni ARNs: siempre leen la salida real de Terraform.
    $value = terraform "-chdir=$TerraformDir" output -raw $Name 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $value) {
        throw "Terraform output '$Name' is not available."
    }
    return $value.Trim()
}

function SafeName {
    param([string]$Value)
    # Normaliza nombres de artefactos para que los CSV/JSON sean cortos y legibles.
    $safe = $Value.ToLowerInvariant() -replace "[^a-z0-9]+", "-"
    return $safe.Trim("-")
}

function ModeCode {
    param([string]$Mode)
    if ($Mode -eq "numbered") { return "n" }
    return "un"
}

if (-not $RunId) {
    # Cada experimento debe tener run_id unico para separar metricas en PostgreSQL.
    $RunId = [guid]::NewGuid().ToString()
}

if (-not (Test-Path $SummaryDir)) {
    New-Item -ItemType Directory -Path $SummaryDir | Out-Null
}

$shortRunId = $RunId.Substring(0, 8)
# Nombre corto y estable para alinear JSON del loadgen con summary/latencies CSV.
$artifactStem = "$(SafeName $RunName)-$(SafeName $Distribution)-$(ModeCode $Mode)-$shortRunId"
$summaryFile = Join-Path $SummaryDir "loadgen-$artifactStem.json"
$expectedMessages = $Requests
if ($Profile -eq "z") {
    # En perfil Z(t) el numero total no viene de -Requests, sino de sumar las
    # fases. Esta cuenta debe coincidir con loadgen.py para wait-run-complete.
    $expectedMessages = [int](
        [math]::Max(1, [math]::Round($ZLowRate * $ZLowSeconds)) +
        [math]::Max(1, [math]::Round($ZRampRate * $ZRampSeconds)) +
        [math]::Max(1, [math]::Round($ZSpikeRate * $ZSpikeSeconds)) +
        [math]::Max(1, [math]::Round($ZHighRate * $ZHighSeconds)) +
        [math]::Max(1, [math]::Round($ZLowRate * $ZCooldownSeconds))
    )
}

# Infraestructura necesaria para `aws ecs run-task`.
$cluster = TfOutput "worker_cluster_name"
$taskDefinition = TfOutput "loadgen_task_definition_arn"
$securityGroup = TfOutput "workers_security_group_id"
$region = TfOutput "region"
$subnets = terraform "-chdir=$TerraformDir" output -json default_subnet_ids | ConvertFrom-Json
$subnetList = ($subnets | ForEach-Object { $_ }) -join ","

if (-not $SkipClean) {
    # Limpieza obligatoria antes de comparar experimentos: RabbitMQ, PostgreSQL y DLQ.
    & (Join-Path $PSScriptRoot "clean-test-state.ps1") -TerraformDir $TerraformDir
}

# Override del comando del contenedor: la imagen es fija, pero cada test cambia parametros.
# Esto evita construir una imagen distinta por cada workload; solo cambia el comando.
$command = @(
    "python", "-m", "src.loadgen",
    "--profile", $Profile,
    "--mode", $Mode,
    "--distribution", $Distribution,
    "--requests", "$Requests",
    "--rate", "$Rate",
    "--report-every", "$ReportEvery",
    "--seat-count", "$SeatCount",
    "--z-low-rate", "$ZLowRate",
    "--z-ramp-rate", "$ZRampRate",
    "--z-spike-rate", "$ZSpikeRate",
    "--z-high-rate", "$ZHighRate",
    "--z-low-seconds", "$ZLowSeconds",
    "--z-ramp-seconds", "$ZRampSeconds",
    "--z-spike-seconds", "$ZSpikeSeconds",
    "--z-high-seconds", "$ZHighSeconds",
    "--z-cooldown-seconds", "$ZCooldownSeconds",
    "--hotspot-request-fraction", "$HotspotRequestFraction",
    "--hotspot-seat-fraction", "$HotspotSeatFraction",
    "--run-id", $RunId,
    "--workload-name", $RunName
)

$override = @{
    containerOverrides = @(
        @{
            # Debe coincidir con el nombre del contenedor en loadgen_task.tf.
            name = "ticket-loadgen"
            command = $command
        }
    )
} | ConvertTo-Json -Depth 8 -Compress

$overrideFile = Join-Path $env:TEMP "ticket-loadgen-override-$shortRunId.json"
# AWS CLI acepta overrides grandes de forma mas fiable como file:// que inline.
Set-Content $overrideFile $override -Encoding ascii

Write-Host "Running AWS loadgen run_id=$RunId artifact=$artifactStem" -ForegroundColor Cyan
$run = aws ecs run-task `
    --cluster $cluster `
    --launch-type FARGATE `
    --task-definition $taskDefinition `
    --network-configuration "awsvpcConfiguration={subnets=[$subnetList],securityGroups=[$securityGroup],assignPublicIp=ENABLED}" `
    --overrides "file://$overrideFile" `
    --query "tasks[0].taskArn" `
    --output text

if ($LASTEXITCODE -ne 0 -or -not $run -or $run -eq "None") {
    throw "Could not start loadgen ECS task."
}

Write-Host "Task: $run" -ForegroundColor Cyan
# tasks-stopped significa que el loadgen ya termino de publicar, no que los
# workers hayan terminado de procesar. Para eso existe wait-run-complete.ps1.
aws ecs wait tasks-stopped --cluster $cluster --tasks $run

# Se comprueba el exit code real del contenedor, no solo que ECS haya parado la task.
$task = aws ecs describe-tasks `
    --cluster $cluster `
    --tasks $run `
    --query "tasks[0].{lastStatus:lastStatus,stopCode:stopCode,stoppedReason:stoppedReason,container:containers[0].{exitCode:exitCode,reason:reason,lastStatus:lastStatus}}" `
    --output json | ConvertFrom-Json

$summary = [ordered]@{
    # Este JSON no es la metrica final; enlaza run_id con parametros y task ARN.
    run_id = $RunId
    artifact = $artifactStem
    source = "ecs-fargate"
    mode = $Mode
    distribution = $Distribution
    profile = $Profile
    requested_messages = $expectedMessages
    requested_rate = $Rate
    z_low_rate = $ZLowRate
    z_ramp_rate = $ZRampRate
    z_spike_rate = $ZSpikeRate
    z_high_rate = $ZHighRate
    z_low_seconds = $ZLowSeconds
    z_ramp_seconds = $ZRampSeconds
    z_spike_seconds = $ZSpikeSeconds
    z_high_seconds = $ZHighSeconds
    z_cooldown_seconds = $ZCooldownSeconds
    task_arn = $run
    task_status = $task.lastStatus
    stop_code = $task.stopCode
    stopped_reason = $task.stoppedReason
    container_exit_code = $task.container.exitCode
    container_reason = $task.container.reason
    created_at = (Get-Date).ToUniversalTime().ToString("o")
}

$summary | ConvertTo-Json -Depth 5 | Set-Content $summaryFile -Encoding ascii
Write-Host "Loadgen summary: $summaryFile" -ForegroundColor Green

if ($null -eq $task.container.exitCode) {
    throw "Loadgen ECS task stopped before container exit code was available. stopCode=$($task.stopCode) stoppedReason=$($task.stoppedReason) containerReason=$($task.container.reason)"
}

if ($task.container.exitCode -ne 0) {
    throw "Loadgen ECS task failed with exit code $($task.container.exitCode): $($task.container.reason)"
}

Write-Host "RunId: $RunId" -ForegroundColor Green

