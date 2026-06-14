<#
.SYNOPSIS
  Exporta metricas PostgreSQL de un run_id a summary.csv y latencies.csv.

.DESCRIPTION
  Explicacion simple:
    Despues de un test, este script busca en PostgreSQL todas las requests de ese
    run_id y genera dos CSV: un resumen global y una fila por request.

  Explicacion tecnica:
    El enunciado exige medir transacciones completadas y no solo tiempos del
    cliente. Por eso las queries usan la tabla `requests`, donde el loadgen deja
    `enqueued_at` y el worker deja `worker_started_at` y `completed_at`. Los
    percentiles se calculan con `percentile_cont` en PostgreSQL. El throughput
    principal se calcula como exige el enunciado: completadas / tiempo total del
    experimento, desde `first_enqueued_at` hasta `last_completed_at`.

  Conecta con:
    - Terraform outputs: host/password de PostgreSQL.
    - report/loadgen_runs: usa el JSON del loadgen para reconstruir nombres.
    - report/results: escribe los CSV finales de analisis.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RunId,
    [string]$TerraformDir = "infra/terraform",
    [string]$RunName = "",
    [string]$LoadgenSummaryDir = "report/loadgen_runs",
    [string]$OutputDir = "report/results"
)

$ErrorActionPreference = "Stop"

function TfOutput {
    param([string]$Name)
    $value = terraform "-chdir=$TerraformDir" output -raw $Name 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $value) {
        throw "Terraform output '$Name' is not available. Deploy core infra before collecting results."
    }
    return $value.Trim()
}

function SafeName {
    param([string]$Value)
    $safe = $Value.ToLowerInvariant() -replace "[^a-z0-9]+", "-"
    return $safe.Trim("-")
}

function ArtifactBase {
    param(
        [string]$RunId,
        [string]$RunName,
        [string]$LoadgenSummaryDir
    )

    $shortRunId = $RunId.Substring(0, 8)
    if ($RunName) {
        return "$(SafeName $RunName)-$shortRunId"
    }

    # Si existe JSON del loadgen, reutilizamos su nombre para que summary/latencies
    # queden alineados: summary-<run-name>-xxxx.csv, latencies-...
    if (Test-Path $LoadgenSummaryDir) {
        $match = Get-ChildItem $LoadgenSummaryDir -Filter "*$shortRunId*.json" |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if ($match) {
            $base = [System.IO.Path]::GetFileNameWithoutExtension($match.Name)
            return $base -replace "^loadgen-", ""
        }
    }

    return "run-$shortRunId"
}

try {
    [guid]$RunId | Out-Null
} catch {
    throw "RunId must be a valid UUID."
}

if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir | Out-Null
}

$postgresHost = TfOutput "postgres_public_ip"
$postgresPassword = TfOutput "postgres_password"
$artifactBase = ArtifactBase -RunId $RunId -RunName $RunName -LoadgenSummaryDir $LoadgenSummaryDir
$summaryFile = Join-Path $OutputDir "summary-$artifactBase.csv"
$latencyFile = Join-Path $OutputDir "latencies-$artifactBase.csv"

$python = Join-Path (Get-Location) ".venv\Scripts\python.exe"
if (-not (Test-Path $python)) {
    throw "Python virtualenv not found at .venv. Create it and install app/loadgen requirements before collecting results."
}

function Invoke-PgCopyCsv {
    param(
        [string]$Sql,
        [string]$OutputFile
    )

    $env:PGHOST = $postgresHost
    $env:PGPORT = "5432"
    $env:PGDATABASE = "tickets"
    $env:PGUSER = "ticket_user"
    $env:PGPASSWORD = $postgresPassword
    $env:PG_COPY_SQL = $Sql
    $env:PG_OUTPUT_FILE = $OutputFile

@'
import os
import psycopg

# Usamos COPY TO STDOUT porque PostgreSQL genera el CSV directamente. Asi no
# reconstruimos columnas manualmente en PowerShell y evitamos errores de formato.
conninfo = (
    f"host={os.environ['PGHOST']} port={os.environ['PGPORT']} "
    f"dbname={os.environ['PGDATABASE']} user={os.environ['PGUSER']} "
    f"password={os.environ['PGPASSWORD']} connect_timeout=5"
)

with psycopg.connect(conninfo) as conn:
    with conn.cursor() as cur:
        # cur.copy transmite el CSV en chunks; funciona tambien con latencies grandes.
        with cur.copy(os.environ["PG_COPY_SQL"]) as copy:
            with open(os.environ["PG_OUTPUT_FILE"], "w", encoding="ascii", newline="") as output:
                for chunk in copy:
                    if isinstance(chunk, bytes):
                        chunk = chunk.decode("utf-8")
                    output.write(chunk)
'@ | & $python -
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

# Resumen por run.
#   - `completed_per_second_experiment_window` es la metrica del enunciado:
#     completadas / (ultima completada - primera encolada).
#   - `completed_per_second_server_window` se conserva para estimar capacidad pura
#     de workers sin contar el pequeno tramo antes de que el primer worker empiece.
#   - `processing_*` mide solo tiempo dentro del worker.
#   - `end_to_end_*` mide desde enqueued_at hasta completed_at.
$summarySql = @"
copy (
with base as (
  select *
  from requests
  where run_id = '$RunId'
), totals as (
  select
    count(*) as requests,
    count(*) filter (where status = 'completed') as completed,
    count(*) filter (where result = 'sold') as sold,
    count(*) filter (where result = 'sold_out') as sold_out,
    count(*) filter (where result = 'seat_unavailable') as seat_unavailable,
    count(*) filter (where error is not null) as errored
  from base
), completed_bounds as (
  select
    min(enqueued_at) as first_enqueued_at,
    min(worker_started_at) as first_worker_started_at,
    max(completed_at) as last_completed_at,
    percentile_cont(0.50) within group (order by extract(epoch from (completed_at - worker_started_at))) as processing_p50_seconds,
    percentile_cont(0.95) within group (order by extract(epoch from (completed_at - worker_started_at))) as processing_p95_seconds,
    percentile_cont(0.99) within group (order by extract(epoch from (completed_at - worker_started_at))) as processing_p99_seconds,
    percentile_cont(0.50) within group (order by extract(epoch from (completed_at - enqueued_at))) as end_to_end_p50_seconds,
    percentile_cont(0.95) within group (order by extract(epoch from (completed_at - enqueued_at))) as end_to_end_p95_seconds,
    percentile_cont(0.99) within group (order by extract(epoch from (completed_at - enqueued_at))) as end_to_end_p99_seconds
  from base
  where completed_at is not null
)
select
  '$RunId' as run_id,
  totals.requests,
  totals.completed,
  totals.sold,
  totals.sold_out,
  totals.seat_unavailable,
  totals.errored,
  first_enqueued_at,
  first_worker_started_at,
  last_completed_at,
  extract(epoch from (last_completed_at - first_enqueued_at)) as experiment_window_seconds,
  case
    when extract(epoch from (last_completed_at - first_enqueued_at)) > 0
    then completed / extract(epoch from (last_completed_at - first_enqueued_at))
    else null
  end as completed_per_second_experiment_window,
  extract(epoch from (last_completed_at - first_worker_started_at)) as server_processing_window_seconds,
  case
    when extract(epoch from (last_completed_at - first_worker_started_at)) > 0
    then completed / extract(epoch from (last_completed_at - first_worker_started_at))
    else null
  end as completed_per_second_server_window,
  processing_p50_seconds,
  processing_p95_seconds,
  processing_p99_seconds,
  end_to_end_p50_seconds,
  end_to_end_p95_seconds,
  end_to_end_p99_seconds
from totals
cross join completed_bounds
) to stdout with csv header;
"@

# Detalle por request para inspeccionar outliers, errores y tiempos negativos si aparecieran.
$latencySql = @"
copy (
select
  request_id,
  mode,
  seat_id,
  status,
  result,
  attempts,
  enqueued_at,
  worker_started_at,
  completed_at,
  extract(epoch from (completed_at - worker_started_at)) as processing_seconds,
  extract(epoch from (completed_at - enqueued_at)) as end_to_end_seconds,
  error
from requests
where run_id = '$RunId'
order by completed_at nulls last, request_id
) to stdout with csv header;
"@

Write-Host "Collecting summary for run_id=$RunId" -ForegroundColor Cyan
Invoke-PgCopyCsv -Sql $summarySql -OutputFile $summaryFile

Write-Host "Collecting per-request latencies for run_id=$RunId" -ForegroundColor Cyan
Invoke-PgCopyCsv -Sql $latencySql -OutputFile $latencyFile

Write-Host "Summary: $summaryFile" -ForegroundColor Green
Write-Host "Latencies: $latencyFile" -ForegroundColor Green
