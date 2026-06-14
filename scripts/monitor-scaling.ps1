<#
.SYNOPSIS
  Captura una serie temporal de RabbitMQ y ECS durante una prueba de scaling.

.DESCRIPTION
  Explicacion simple:
    Mientras corre un workload Z(t), este script mira cada pocos segundos cuantos
    mensajes hay en RabbitMQ y cuantos workers ECS estan activos. Guarda un CSV
    listo para graficas de backlog vs tiempo y workers vs tiempo.

  Explicacion tecnica:
    Lee RabbitMQ Management API para `messages_ready`, `messages_unacknowledged`,
    consumidores y rates. Lee ECS `describe-services` para desired/running/pending
    del worker service y del scaler service. No modifica infraestructura.
#>

[CmdletBinding()]
param(
    [string]$TerraformDir = "infra/terraform",
    [string]$RunId = "",
    [string]$RunName = "scaling",
    [int]$DurationSeconds = 300,
    [int]$PollSeconds = 5,
    [string]$OutputDir = "report/results"
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

function SafeName {
    param([string]$Value)
    $safe = $Value.ToLowerInvariant() -replace "[^a-z0-9]+", "-"
    return $safe.Trim("-")
}

if (-not $RunId) {
    $RunId = [guid]::NewGuid().ToString()
}

if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir | Out-Null
}

$shortRunId = $RunId.Substring(0, 8)
# El CSV se guarda con run_id corto para poder cruzarlo con summary/latencies.
$artifact = "scaling-timeseries-$(SafeName $RunName)-$shortRunId.csv"
$outputFile = Join-Path $OutputDir $artifact

$rabbitUrl = TfOutput "rabbitmq_management_url"
$rabbitUser = TfOutput "rabbitmq_username"
$rabbitPassword = TfOutput "rabbitmq_password"
$cluster = TfOutput "worker_cluster_name"
$workerService = TfOutput "worker_service_name"
$scalerService = TfOutput "scaler_service_name"

$basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$rabbitUser`:$rabbitPassword"))
$headers = @{ Authorization = "Basic $basic" }
$invariant = [System.Globalization.CultureInfo]::InvariantCulture

function CsvNumber {
    param([double]$Value)
    # PowerShell en locale espanol puede usar coma decimal; forzamos punto para CSV.
    return $Value.ToString("0.###", $invariant)
}

# Cabecera fija usada por los scripts de graficas.
"timestamp_utc,elapsed_seconds,run_id,rabbit_ready,rabbit_unacked,rabbit_total,rabbit_consumers,rabbit_publish_rate,rabbit_deliver_rate,rabbit_ack_rate,worker_desired,worker_running,worker_pending,scaler_desired,scaler_running,scaler_pending" |
    Set-Content -Path $outputFile -Encoding ascii

$start = Get-Date
$stopAt = $start.AddSeconds($DurationSeconds)
Write-Host "Monitoring scaling to $outputFile for ${DurationSeconds}s..." -ForegroundColor Cyan

while ((Get-Date) -lt $stopAt) {
    $now = Get-Date
    $elapsed = [math]::Round(($now - $start).TotalSeconds, 3)

    try {
        # RabbitMQ aporta backlog y rates; ECS aporta desired/running/pending.
        $queue = Invoke-RestMethod -Method Get -Uri "$rabbitUrl/api/queues/%2F/tickets.buy" -Headers $headers -TimeoutSec 5
        $publishRate = 0.0
        $deliverRate = 0.0
        $ackRate = 0.0
        if ($queue.message_stats.publish_details.rate -ne $null) { $publishRate = [double]$queue.message_stats.publish_details.rate }
        if ($queue.message_stats.deliver_get_details.rate -ne $null) { $deliverRate = [double]$queue.message_stats.deliver_get_details.rate }
        if ($queue.message_stats.ack_details.rate -ne $null) { $ackRate = [double]$queue.message_stats.ack_details.rate }

        $ecs = aws ecs describe-services --cluster $cluster --services $workerService $scalerService --output json | ConvertFrom-Json
        $worker = $ecs.services | Where-Object { $_.serviceName -eq $workerService } | Select-Object -First 1
        $scaler = $ecs.services | Where-Object { $_.serviceName -eq $scalerService } | Select-Object -First 1

        # Cada muestra es una fila temporal. Las graficas de autoscaling salen de aqui.
        $line = @(
            $now.ToUniversalTime().ToString("o"),
            (CsvNumber $elapsed),
            $RunId,
            [int]$queue.messages_ready,
            [int]$queue.messages_unacknowledged,
            [int]$queue.messages,
            [int]$queue.consumers,
            (CsvNumber $publishRate),
            (CsvNumber $deliverRate),
            (CsvNumber $ackRate),
            [int]$worker.desiredCount,
            [int]$worker.runningCount,
            [int]$worker.pendingCount,
            [int]$scaler.desiredCount,
            [int]$scaler.runningCount,
            [int]$scaler.pendingCount
        ) -join ","
        Add-Content -Path $outputFile -Value $line -Encoding ascii
    }
    catch {
        Write-Warning "monitor sample failed: $($_.Exception.Message)"
    }

    Start-Sleep -Seconds $PollSeconds
}

Write-Host "Scaling timeseries: $outputFile" -ForegroundColor Green

