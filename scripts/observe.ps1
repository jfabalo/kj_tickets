<#
.SYNOPSIS
  Muestra una foto rapida de observabilidad del sistema de tickets.

.DESCRIPTION
  Explicacion simple:
    Este script responde a: cuantos workers hay, si hay mensajes pendientes en
    RabbitMQ, que dicen los logs, cuantos tickets se han vendido y si hay fallos
    en la DLQ.

  Explicacion tecnica:
    Combina AWS CLI, RabbitMQ Management API y consultas PostgreSQL. No sustituye
    CloudWatch dashboards, pero da feedback inmediato para pruebas de carga.
    Las consultas PostgreSQL son globales del estado actual; para un run concreto
    se debe usar collect-run-results.ps1 con RunId.

  Conecta con:
    - ECS service/tasks.
    - CloudWatch Logs del worker.
    - RabbitMQ queue metrics.
    - PostgreSQL summary.
    - SQS DLQ attributes.
#>

[CmdletBinding()]
param(
    [string]$TerraformDir = "infra/terraform",
    [int]$LogLimit = 20
)

$ErrorActionPreference = "Stop"

function TfOutput {
    param([string]$Name)
    $value = terraform "-chdir=$TerraformDir" output -raw $Name 2>$null
    if ($LASTEXITCODE -ne 0) {
        return $null
    }
    return $value
}

function Section {
    param([string]$Name)
    Write-Host "`n=== $Name ===" -ForegroundColor Cyan
}

$cluster = TfOutput "worker_cluster_name"
$service = TfOutput "worker_service_name"
$logGroup = TfOutput "worker_log_group"
$rabbitPublicIp = TfOutput "rabbitmq_public_ip"
$rabbitPassword = TfOutput "rabbitmq_password"
$postgresPublicIp = TfOutput "postgres_public_ip"
$postgresPassword = TfOutput "postgres_password"
$dlqUrl = TfOutput "ticket_failures_dlq_url"
$rabbitUser = TfOutput "rabbitmq_username"
if (-not $rabbitUser) { $rabbitUser = "ticket_user" }

Section "Terraform Outputs"
# Evitamos imprimir passwords en la salida de observabilidad.
terraform "-chdir=$TerraformDir" output | Select-String -Pattern "password" -NotMatch

if ($cluster -and $service) {
    Section "ECS Service"
    aws ecs describe-services `
        --cluster $cluster `
        --services $service `
        --query "services[0].{status:status,desired:desiredCount,running:runningCount,pending:pendingCount,events:events[0:5].message}" `
        --output table

    Section "ECS Tasks"
    $tasks = aws ecs list-tasks --cluster $cluster --service-name $service --query "taskArns" --output text
    if ($tasks) {
        aws ecs describe-tasks `
            --cluster $cluster `
            --tasks $tasks `
            --query "tasks[].{lastStatus:lastStatus,desiredStatus:desiredStatus,stoppedReason:stoppedReason,containers:containers[].{name:name,lastStatus:lastStatus,reason:reason,exitCode:exitCode}}" `
            --output json
    } else {
        Write-Host "No tasks found."
    }
}

if ($logGroup) {
    Section "Latest Worker Logs"
    $stream = aws logs describe-log-streams `
        --log-group-name $logGroup `
        --order-by LastEventTime `
        --descending `
        --max-items 1 `
        --query "logStreams[0].logStreamName" `
        --output text

    if ($stream -and $stream -ne "None") {
        aws logs get-log-events `
            --log-group-name $logGroup `
            --log-stream-name $stream `
            --limit $LogLimit `
            --query "events[].message" `
            --output text
    } else {
        Write-Host "No log streams found."
    }
}

if ($rabbitPublicIp -and $rabbitPassword) {
    Section "RabbitMQ Queue"
    $basic = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("$rabbitUser`:$rabbitPassword"))
    $headers = @{ Authorization = "Basic $basic" }
    try {
        # RabbitMQ da backlog total, ready/unacked y numero de consumidores.
        $queue = Invoke-RestMethod -Uri "http://$rabbitPublicIp`:15672/api/queues/%2F/tickets.buy" -Headers $headers
        [pscustomobject]@{
            name       = $queue.name
            messages   = $queue.messages
            ready      = $queue.messages_ready
            unacked    = $queue.messages_unacknowledged
            consumers  = $queue.consumers
            publishRate = $queue.message_stats.publish_details.rate
            deliverRate = $queue.message_stats.deliver_get_details.rate
            ackRate     = $queue.message_stats.ack_details.rate
        } | Format-List
    } catch {
        Write-Warning "Could not query RabbitMQ API: $($_.Exception.Message)"
    }
}

if ($postgresPublicIp -and $postgresPassword) {
    Section "PostgreSQL Summary"
    $python = Join-Path (Get-Location) ".venv\Scripts\python.exe"
    if (-not (Test-Path $python)) {
        Write-Warning "Python virtualenv not found at .venv. Skipping PostgreSQL summary."
    } else {
        $env:PGHOST = $postgresPublicIp
        $env:PGPORT = "5432"
        $env:PGDATABASE = "tickets"
        $env:PGUSER = "ticket_user"
        $env:PGPASSWORD = $postgresPassword

@'
import os
import psycopg
from psycopg.rows import dict_row

queries = [
    (
        "requests",
        """
select
  count(*) as requests,
  count(*) filter (where status='completed') as completed,
  count(*) filter (where result='sold') as sold,
  count(*) filter (where result='sold_out') as sold_out,
  count(*) filter (where result='seat_unavailable') as seat_unavailable,
  count(*) filter (where error is not null) as errored
from requests
        """,
    ),
    ("sales", "select count(*) as sales from sales"),
    (
        "end_to_end_latency",
        """
select
  percentile_cont(0.50) within group (order by extract(epoch from (completed_at - enqueued_at))) as p50_seconds,
  percentile_cont(0.95) within group (order by extract(epoch from (completed_at - enqueued_at))) as p95_seconds,
  percentile_cont(0.99) within group (order by extract(epoch from (completed_at - enqueued_at))) as p99_seconds
from requests
where completed_at is not null
        """,
    ),
    (
        "processing_latency",
        """
select
  percentile_cont(0.50) within group (order by extract(epoch from (completed_at - worker_started_at))) as processing_p50_seconds,
  percentile_cont(0.95) within group (order by extract(epoch from (completed_at - worker_started_at))) as processing_p95_seconds,
  percentile_cont(0.99) within group (order by extract(epoch from (completed_at - worker_started_at))) as processing_p99_seconds
from requests
where completed_at is not null
  and worker_started_at is not null
        """,
    ),
]

conninfo = (
    f"host={os.environ['PGHOST']} port={os.environ['PGPORT']} "
    f"dbname={os.environ['PGDATABASE']} user={os.environ['PGUSER']} "
    f"password={os.environ['PGPASSWORD']} connect_timeout=5"
)

with psycopg.connect(conninfo, row_factory=dict_row) as conn:
    with conn.cursor() as cur:
        for title, sql in queries:
            cur.execute(sql)
            row = cur.fetchone()
            print(f"\n[{title}]")
            if row:
                for key, value in row.items():
                    print(f"{key}: {value}")
'@ | & $python -
    }
}

if ($dlqUrl) {
    Section "SQS DLQ"
    aws sqs get-queue-attributes `
        --queue-url $dlqUrl `
        --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible `
        --output table
}
