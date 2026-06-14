<#
.SYNOPSIS
  Limpia RabbitMQ, PostgreSQL y SQS DLQ antes de ejecutar un test.

.DESCRIPTION
  Explicacion simple:
    Deja el sistema como si fuese una prueba nueva: vacia la cola de compras,
    borra resultados antiguos de la base de datos y limpia la cola de fallos.

  Explicacion tecnica:
    RabbitMQ se purga por su Management API. PostgreSQL se resetea dentro de una
    transaccion para que requests, sales, experiment_runs, seats y ticket_pools
    vuelvan a estado inicial. SQS se purga con AWS CLI. Esto evita que
    summary.csv y latencies.csv mezclen datos de varios experimentos.

  Optimizacion:
    No actualiza siempre los 100.000 asientos. Solo resetea filas dirty:
    status <> available, request_id no nulo o sold_at no nulo.

  Conecta con:
    - RabbitMQ management endpoint publico.
    - PostgreSQL EC2 por IP publica para mantenimiento desde operador.
    - SQS DLQ para fallos permanentes.
#>

[CmdletBinding()]
param(
    [string]$TerraformDir = "infra/terraform",
    [switch]$SkipRabbitMQ,
    [switch]$SkipPostgres,
    [switch]$SkipSqs
)

$ErrorActionPreference = "Stop"
$TotalStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

function TfOutput {
    param([string]$Name)
    $value = terraform "-chdir=$TerraformDir" output -raw $Name 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $value) {
        throw "Terraform output '$Name' is not available."
    }
    return $value.Trim()
}

function StepTime {
    param(
        [string]$Name,
        [scriptblock]$Block
    )
    # Mide cada fase para detectar si limpiar vuelve a tardar como redeployar.
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $Block
    $sw.Stop()
    Write-Host "$Name completed in $([math]::Round($sw.Elapsed.TotalSeconds, 2))s" -ForegroundColor DarkGray
}

if (-not $SkipRabbitMQ) {
    StepTime "RabbitMQ purge" {
        $rabbitUrl = TfOutput "rabbitmq_management_url"
        $rabbitUser = TfOutput "rabbitmq_username"
        $rabbitPassword = TfOutput "rabbitmq_password"
        $basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$rabbitUser`:$rabbitPassword"))
        $headers = @{ Authorization = "Basic $basic" }
        Write-Host "Purging RabbitMQ queue tickets.buy..." -ForegroundColor Cyan
        # DELETE /contents vacia mensajes ready/unacked de la cola principal.
        # Lo usamos antes de tests para que el backlog empiece en cero.
        Invoke-RestMethod `
            -Method Delete `
            -Uri "$rabbitUrl/api/queues/%2F/tickets.buy/contents" `
            -Headers $headers `
            -ContentType "application/json" | Out-Null
    }
}

if (-not $SkipPostgres) {
    StepTime "PostgreSQL reset" {
        $python = Join-Path (Get-Location) ".venv\Scripts\python.exe"
        if (-not (Test-Path $python)) {
            throw "Python virtualenv not found at .venv."
        }

        $env:PGHOST = TfOutput "postgres_public_ip"
        $env:PGPORT = "5432"
        $env:PGDATABASE = TfOutput "postgres_database"
        $env:PGUSER = TfOutput "postgres_username"
        $env:PGPASSWORD = TfOutput "postgres_password"

        Write-Host "Resetting PostgreSQL ticket state..." -ForegroundColor Cyan
        @'
import os
import psycopg

conninfo = (
    f"host={os.environ['PGHOST']} port={os.environ['PGPORT']} "
    f"dbname={os.environ['PGDATABASE']} user={os.environ['PGUSER']} "
    f"password={os.environ['PGPASSWORD']} connect_timeout=5"
)

with psycopg.connect(conninfo) as conn:
    with conn.transaction():
        with conn.cursor() as cur:
            # Borramos metricas y ventas; CASCADE limpia relaciones con requests.
            cur.execute("TRUNCATE sales, requests, experiment_runs RESTART IDENTITY CASCADE")
            # No tocamos los 100000 asientos si ya estan limpios; solo filas dirty.
            cur.execute("""
                UPDATE seats
                SET status='available', request_id=NULL, sold_at=NULL
                WHERE status <> 'available'
                   OR request_id IS NOT NULL
                   OR sold_at IS NOT NULL
            """)
            dirty_seats = cur.rowcount
            # Reset del contador global para tickets no numerados.
            cur.execute("UPDATE ticket_pools SET sold_count=0 WHERE pool_id='main' AND sold_count <> 0")
            pool_rows = cur.rowcount
            cur.execute("SELECT count(*) FROM seats WHERE status='sold'")
            sold = cur.fetchone()[0]
            if sold != 0:
                raise RuntimeError(f"expected 0 sold seats after reset, got {sold}")
print(f"PostgreSQL reset complete dirty_seats={dirty_seats} pool_rows={pool_rows}")
'@ | & $python -
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
}

if (-not $SkipSqs) {
    StepTime "SQS DLQ purge" {
        $dlqUrl = TfOutput "ticket_failures_dlq_url"
        Write-Host "Purging SQS DLQ..." -ForegroundColor Cyan
        # SQS solo permite purge una vez por minuto. Si se llama dos veces
        # seguidas, avisamos pero no rompemos toda la limpieza.
        aws sqs purge-queue --queue-url $dlqUrl 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "SQS purge may have been called recently; AWS allows purge once per 60 seconds."
        }
    }
}

$TotalStopwatch.Stop()
Write-Host "Test state cleaned in $([math]::Round($TotalStopwatch.Elapsed.TotalSeconds, 2))s." -ForegroundColor Green
