<#
.SYNOPSIS
  Espera a que un run_id tenga todas sus requests completadas en PostgreSQL.

.DESCRIPTION
  Explicacion simple:
    Para cargas grandes, el loadgen termina cuando publica mensajes, no cuando
    los workers han acabado de procesarlos. Este script espera a que PostgreSQL
    muestre `completed >= ExpectedRequests` antes de recoger CSV.

  Explicacion tecnica:
    Consulta `requests` por `run_id` usando psycopg en el entorno local. No usa
    Docker, para evitar depender de Docker Desktop para esta espera. Si hay
    errores o timeout, falla para que no exportemos metricas incompletas.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$RunId,
    [Parameter(Mandatory = $true)]
    [int]$ExpectedRequests,
    [string]$TerraformDir = "infra/terraform",
    [int]$TimeoutSeconds = 600,
    [int]$PollSeconds = 5
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

try {
    [guid]$RunId | Out-Null
} catch {
    throw "RunId must be a valid UUID."
}

$python = Join-Path (Get-Location) ".venv\Scripts\python.exe"
if (-not (Test-Path $python)) {
    throw "Python virtualenv not found at .venv."
}

$env:PGHOST = TfOutput "postgres_public_ip"
$env:PGPORT = "5432"
$env:PGDATABASE = TfOutput "postgres_database"
$env:PGUSER = TfOutput "postgres_username"
$env:PGPASSWORD = TfOutput "postgres_password"
$env:RUN_ID = $RunId
$env:EXPECTED_REQUESTS = [string]$ExpectedRequests
$env:TIMEOUT_SECONDS = [string]$TimeoutSeconds
$env:POLL_SECONDS = [string]$PollSeconds

@'
import os
import time
import psycopg

# Este script mira PostgreSQL, no RabbitMQ. El loadgen termina al publicar, pero
# el criterio del enunciado es transacciones completadas.
run_id = os.environ["RUN_ID"]
expected = int(os.environ["EXPECTED_REQUESTS"])
timeout = int(os.environ["TIMEOUT_SECONDS"])
poll = int(os.environ["POLL_SECONDS"])

conninfo = (
    f"host={os.environ['PGHOST']} port={os.environ['PGPORT']} "
    f"dbname={os.environ['PGDATABASE']} user={os.environ['PGUSER']} "
    f"password={os.environ['PGPASSWORD']} connect_timeout=5"
)

deadline = time.monotonic() + timeout
last = None

with psycopg.connect(conninfo) as conn:
    while True:
        with conn.cursor() as cur:
            # completed cuenta requests con status final. Si hay errores tecnicos,
            # se muestran para no recoger CSV incompletos sin darnos cuenta.
            cur.execute(
                """
                select
                  count(*) as requests,
                  count(*) filter (where status = 'completed') as completed,
                  count(*) filter (where error is not null) as errored
                from requests
                where run_id = %s
                """,
                (run_id,),
            )
            requests, completed, errored = cur.fetchone()

        current = (requests, completed, errored)
        if current != last:
            print(f"run_id={run_id} requests={requests} completed={completed} errored={errored}", flush=True)
            last = current

        if completed >= expected:
            break

        if time.monotonic() >= deadline:
            raise TimeoutError(
                f"timeout waiting for run_id={run_id}: "
                f"requests={requests} completed={completed} expected={expected} errored={errored}"
            )

        time.sleep(poll)
'@ | & $python -

if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
