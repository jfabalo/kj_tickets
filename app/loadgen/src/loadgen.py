"""Generador de carga RabbitMQ para el servicio distribuido de tickets.

Explicacion simple:
    Este programa simula clientes comprando tickets. Genera mensajes de compra
    con un run_id comun y los publica en RabbitMQ. Los workers son quienes venden
    realmente; el loadgen solo crea carga controlada para medir el sistema.

Explicacion tecnica:
    Antes de publicar cada mensaje, el loadgen registra la request en PostgreSQL
    y obtiene `enqueued_at = clock_timestamp()`. Despues publica el payload en
    RabbitMQ incluyendo ese timestamp. El worker completara la request con
    `completed_at = clock_timestamp()`. Asi `end_to_end = completed_at -
    enqueued_at` usa el mismo reloj de base de datos y evita tiempos negativos.

Perfiles soportados:
    - constant: N mensajes a una tasa fija.
    - z: workload elastico con fases low, ramp-up, spike, high y cool-down.

Distribuciones soportadas:
    - uniform: asiento aleatorio uniforme.
    - hotspot: 80% de peticiones sobre 5% de asientos por defecto, para medir
      contencion en tickets numerados.

Conexiones principales:
    - PostgreSQL EC2: fuente de verdad para metricas de inicio de request.
    - RabbitMQ EC2: cola asincrona que desacopla clientes y workers.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable
from uuid import UUID, uuid4

import pika
import psycopg


@dataclass(frozen=True)
class Phase:
    """Una fase del workload Z(t): duracion y tasa objetivo de publicacion."""

    name: str
    duration_seconds: float
    rate_per_second: float


@dataclass
class PublishStats:
    """Resumen local de publicacion del loadgen.

    Este JSON no sustituye las metricas oficiales. Sirve para trazabilidad del
    experimento: que se intento publicar, desde donde y con que parametros.
    Las metricas evaluables salen de PostgreSQL con collect-run-results.ps1.
    """

    run_id: str
    mode: str
    distribution: str
    requested_messages: int
    published_messages: int
    started_at: str
    finished_at: str
    elapsed_seconds: float
    average_publish_rate: float
    phases: list[dict[str, float | str]]


def utc_now_iso() -> str:
    """Timestamp UTC para logs locales del loadgen, no para end-to-end oficial."""
    return datetime.now(timezone.utc).isoformat()


def positive_int(value: str) -> int:
    """Tipo argparse: entero estrictamente positivo."""
    parsed = int(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("value must be > 0")
    return parsed


def positive_float(value: str) -> float:
    """Tipo argparse: float estrictamente positivo."""
    parsed = float(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("value must be > 0")
    return parsed


def parse_run_id(value: str | None) -> str:
    """Normaliza o genera el UUID que agrupa todas las requests de un test."""
    if not value:
        return str(uuid4())
    try:
        return str(UUID(value))
    except ValueError as exc:
        raise argparse.ArgumentTypeError("run_id must be a valid UUID") from exc


def env_default(name: str, default: str | None = None) -> str | None:
    """Permite que ECS inyecte defaults por variables de entorno."""
    return os.getenv(name, default)


def build_parser() -> argparse.ArgumentParser:
    """Define la interfaz CLI del loadgen.

    Los parametros RabbitMQ/PostgreSQL se pueden pasar por CLI o por variables de
    entorno. En AWS/Fargate, Terraform los inyecta en la task definition.
    """
    # argparse convierte argumentos de terminal/ECS en `args.<nombre>`.
    # Esto permite reutilizar la misma imagen Docker para todos los experimentos.
    parser = argparse.ArgumentParser(description="Publish controlled ticket load to RabbitMQ")

    # Conexion RabbitMQ. En AWS estos valores llegan desde Terraform como env vars.
    parser.add_argument("--rabbitmq-host", default=env_default("RABBITMQ_HOST"))
    parser.add_argument("--rabbitmq-port", type=positive_int, default=env_default("RABBITMQ_PORT", "5672"))
    parser.add_argument("--rabbitmq-user", default=env_default("RABBITMQ_USER", "ticket_user"))
    parser.add_argument("--rabbitmq-password", default=env_default("RABBITMQ_PASSWORD"))
    parser.add_argument("--exchange", default=env_default("RABBITMQ_EXCHANGE", "tickets.exchange"))
    parser.add_argument("--routing-key", default=env_default("RABBITMQ_ROUTING_KEY", "ticket.buy"))

    # Conexion PostgreSQL. Se usa para registrar enqueued_at antes de publicar.
    parser.add_argument("--postgres-host", default=env_default("POSTGRES_HOST"))
    parser.add_argument("--postgres-port", type=positive_int, default=env_default("POSTGRES_PORT", "5432"))
    parser.add_argument("--postgres-db", default=env_default("POSTGRES_DB", "tickets"))
    parser.add_argument("--postgres-user", default=env_default("POSTGRES_USER", "ticket_user"))
    parser.add_argument("--postgres-password", default=env_default("POSTGRES_PASSWORD"))

    # Solo para pruebas manuales/dry-run: sin registro DB no hay metrica oficial end-to-end.
    parser.add_argument("--skip-db-registration", action="store_true")

    # Identificacion del experimento y tipo de tickets.
    parser.add_argument("--run-id", type=parse_run_id, default=None)
    parser.add_argument("--workload-name", default="manual-loadgen")
    parser.add_argument("--mode", choices=("unnumbered", "numbered"), default="numbered")
    parser.add_argument("--distribution", choices=("uniform", "hotspot"), default="uniform")

    # Parametros generales del workload constante.
    parser.add_argument("--seat-count", type=positive_int, default=100_000)
    parser.add_argument("--requests", type=positive_int, default=100)
    parser.add_argument("--rate", type=positive_float, default=10.0)
    parser.add_argument("--profile", choices=("constant", "z"), default="constant")

    # Parametros del perfil Z(t): low, ramp-up, spike, high y cool-down.
    parser.add_argument("--z-low-rate", type=positive_float, default=5.0)
    parser.add_argument("--z-ramp-rate", type=positive_float, default=25.0)
    parser.add_argument("--z-spike-rate", type=positive_float, default=80.0)
    parser.add_argument("--z-high-rate", type=positive_float, default=40.0)
    parser.add_argument("--z-low-seconds", type=positive_float, default=10.0)
    parser.add_argument("--z-ramp-seconds", type=positive_float, default=20.0)
    parser.add_argument("--z-spike-seconds", type=positive_float, default=8.0)
    parser.add_argument("--z-high-seconds", type=positive_float, default=20.0)
    parser.add_argument("--z-cooldown-seconds", type=positive_float, default=10.0)

    # Hotspot: porcentaje de requests que caen en un subconjunto pequeño de asientos.
    parser.add_argument("--hotspot-request-fraction", type=float, default=0.80)
    parser.add_argument("--hotspot-seat-fraction", type=float, default=0.05)

    # Seed fija hace reproducible la secuencia aleatoria en pruebas comparables.
    parser.add_argument("--seed", type=int, default=None)
    parser.add_argument("--publisher-confirms", action="store_true")
    parser.add_argument("--report-every", type=positive_int, default=100)
    parser.add_argument("--summary-file", default=None)

    # Dry-run imprime payloads de ejemplo sin tocar AWS/RabbitMQ/PostgreSQL.
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--dry-run-limit", type=positive_int, default=5)
    return parser


def validate_args(args: argparse.Namespace) -> None:
    """Valida combinaciones de parametros antes de abrir conexiones."""
    missing_rabbitmq = [
        name
        for name, value in {
            "--rabbitmq-host": args.rabbitmq_host,
            "--rabbitmq-password": args.rabbitmq_password,
        }.items()
        if not value
    ]
    if missing_rabbitmq and not args.dry_run:
        raise ValueError(f"missing required RabbitMQ arguments: {', '.join(missing_rabbitmq)}")

    if not 0 < args.hotspot_request_fraction <= 1:
        raise ValueError("--hotspot-request-fraction must be in (0, 1]")
    if not 0 < args.hotspot_seat_fraction <= 1:
        raise ValueError("--hotspot-seat-fraction must be in (0, 1]")
    if args.distribution == "hotspot" and args.mode != "numbered":
        raise ValueError("hotspot distribution only applies to numbered tickets")
    if not args.skip_db_registration and not args.dry_run:
        missing = [
            name
            for name, value in {
                "--postgres-host": args.postgres_host,
                "--postgres-password": args.postgres_password,
            }.items()
            if not value
        ]
        if missing:
            raise ValueError(f"missing required DB registration arguments: {', '.join(missing)}")


def phases_for(args: argparse.Namespace) -> list[Phase]:
    """Construye las fases del workload.

    Perfil constant: una fase cuya duración teorica es requests / rate.
    Perfil z: workload elastico pedido por el enunciado: baja carga, subida,
    pico, alta sostenida y enfriamiento.
    """
    if args.profile == "constant":
        duration = args.requests / args.rate
        return [Phase("constant", duration, args.rate)]

    return [
        Phase("low", args.z_low_seconds, args.z_low_rate),
        Phase("ramp-up", args.z_ramp_seconds, args.z_ramp_rate),
        Phase("spike", args.z_spike_seconds, args.z_spike_rate),
        Phase("high", args.z_high_seconds, args.z_high_rate),
        Phase("cool-down", args.z_cooldown_seconds, args.z_low_rate),
    ]


def phase_message_count(phase: Phase) -> int:
    """Mensajes esperados por fase: duracion * tasa, redondeado minimo a 1."""
    return max(1, round(phase.duration_seconds * phase.rate_per_second))


def choose_seat(args: argparse.Namespace, rng: random.Random) -> int | None:
    """Selecciona asiento segun modo y distribucion.

    En hotspot, el 80% de peticiones cae por defecto en el primer 5% de asientos.
    Esto fuerza contencion y permite observar bloqueos, fallos seat_unavailable y
    crecimiento de latencia bajo conflicto.
    """
    if args.mode == "unnumbered":
        # En tickets no numerados no existe asiento concreto; se vende contra contador global.
        return None
    if args.distribution == "uniform":
        # Cualquier asiento tiene la misma probabilidad de ser elegido.
        return rng.randint(1, args.seat_count)

    # Tamano del subconjunto caliente. Con 100000 y 0.05 son los asientos 1..5000.
    hotspot_size = max(1, round(args.seat_count * args.hotspot_seat_fraction))
    if rng.random() < args.hotspot_request_fraction:
        # La mayoria de peticiones hotspot cae dentro del subconjunto caliente.
        return rng.randint(1, hotspot_size)

    # El resto de peticiones va a la zona fria: hotspot_size+1 .. seat_count.
    # Si el hotspot ocupa todos los asientos, no hay zona fria; devolvemos 1 como fallback.
    if hotspot_size < args.seat_count:
        return rng.randint(hotspot_size + 1, args.seat_count)
    return 1


def payload_for(args: argparse.Namespace, rng: random.Random, run_id: str, sequence: int) -> dict[str, object]:
    """Crea el JSON que viajara por RabbitMQ."""
    # request_id es distinto para cada compra y es la clave de idempotencia del worker.
    payload: dict[str, object] = {
        "request_id": str(uuid4()),
        "run_id": run_id,
        "workload_name": args.workload_name,
        "sequence": sequence,
        "mode": args.mode,
    }
    seat_id = choose_seat(args, rng)
    if seat_id is not None:
        # Solo los tickets numbered llevan seat_id; los unnumbered usan contador global.
        payload["seat_id"] = seat_id
    return payload


def connect(args: argparse.Namespace) -> tuple[pika.BlockingConnection, pika.adapters.blocking_connection.BlockingChannel]:
    """Conecta con RabbitMQ y declara el exchange usado por los workers.

    Declarar el exchange aqui es idempotente: si ya existe no lo recrea. Esto
    hace que el loadgen sea robusto ante reinicios del broker o despliegues
    parciales. La cola la crea tambien Terraform/user_data, pero el contrato real
    de publicacion es exchange + routing_key.
    """
    credentials = pika.PlainCredentials(args.rabbitmq_user, args.rabbitmq_password)
    params = pika.ConnectionParameters(
        host=args.rabbitmq_host,
        port=args.rabbitmq_port,
        credentials=credentials,
        heartbeat=60,
        blocked_connection_timeout=120,
    )
    connection = pika.BlockingConnection(params)
    channel = connection.channel()
    channel.exchange_declare(exchange=args.exchange, exchange_type="direct", durable=True)
    if args.publisher_confirms:
        # Publisher confirms aumenta seguridad de publicacion, pero tambien puede
        # reducir tasa. Lo dejamos opcional para experimentos de rendimiento.
        channel.confirm_delivery()
    return connection, channel


def postgres_dsn(args: argparse.Namespace) -> str:
    """Cadena de conexion a PostgreSQL para registrar metricas antes de publicar."""
    return (
        f"host={args.postgres_host} port={args.postgres_port} "
        f"dbname={args.postgres_db} user={args.postgres_user} "
        f"password={args.postgres_password} connect_timeout=5"
    )


def register_request(conn: psycopg.Connection, args: argparse.Namespace, payload: dict[str, object], expected_messages: int) -> str:
    """Registra request/run usando PostgreSQL como reloj oficial de metricas.

    Este paso es intencionado aunque anada una escritura antes de RabbitMQ:
    permite medir end-to-end correctamente, desde que la peticion entra al sistema
    hasta que el worker la completa, sin depender del reloj local del loadgen.
    """
    with conn.transaction():
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO experiment_runs(run_id, workload_name, mode, started_at, expected_requests, notes)
                VALUES (%s, %s, %s, clock_timestamp(), %s, 'Created by load generator before RabbitMQ publish')
                ON CONFLICT (run_id) DO UPDATE
                SET expected_requests = COALESCE(experiment_runs.expected_requests, EXCLUDED.expected_requests)
                """,
                (
                    payload["run_id"],
                    payload["workload_name"],
                    payload["mode"],
                    expected_messages,
                ),
            )
            cur.execute(
                """
                INSERT INTO requests(request_id, run_id, mode, seat_id, status, attempts, enqueued_at)
                VALUES (%s, %s, %s, %s, 'queued', 0, clock_timestamp())
                RETURNING enqueued_at
                """,
                (
                    payload["request_id"],
                    payload["run_id"],
                    payload["mode"],
                    payload.get("seat_id"),
                ),
            )
            enqueued_at = cur.fetchone()[0]
    return enqueued_at.isoformat()


def iter_schedule(phases: Iterable[Phase]) -> Iterable[tuple[Phase, int, float]]:
    """Genera el calendario de publicacion.

    Cada yield indica fase actual, total de mensajes de la fase e intervalo entre
    publicaciones. El bucle principal duerme hasta respetar ese intervalo.
    """
    for phase in phases:
        interval = 1.0 / phase.rate_per_second
        count = phase_message_count(phase)
        for _ in range(count):
            yield phase, count, interval


def publish(args: argparse.Namespace) -> PublishStats:
    """Publica la carga completa y devuelve un resumen local.

    La escritura en PostgreSQL ocurre antes de publicar en RabbitMQ porque
    `enqueued_at` representa la entrada de la request al sistema. Si se midiera
    solo desde el cliente, se incumpliria el enunciado y podrian aparecer sesgos
    por red local o relojes distintos.
    """
    validate_args(args)
    rng = random.Random(args.seed)
    run_id = args.run_id or str(uuid4())
    phases = phases_for(args)
    expected_messages = sum(phase_message_count(phase) for phase in phases)
    if args.profile == "constant":
        # En constant respetamos exactamente --requests; en Z(t) se calcula por fases.
        expected_messages = args.requests

    rabbit_connection, channel = connect(args)
    # Si no se salta DB, cada request se registra antes de publicar para medir end-to-end.
    pg_connection = None if args.skip_db_registration else psycopg.connect(postgres_dsn(args))
    started_wall = utc_now_iso()
    # monotonic mide duracion local sin verse afectado por cambios del reloj del sistema.
    started = time.monotonic()
    published = 0
    next_publish_at = started

    # delivery_mode=2 marca el mensaje como persistente en RabbitMQ. No convierte
    # el sistema en exactly-once, pero reduce riesgo de perder mensajes si el
    # broker reinicia despues de aceptar la publicacion.
    properties = pika.BasicProperties(content_type="application/json", delivery_mode=2)
    try:
        schedule = iter_schedule(phases)
        for phase, _phase_count, interval in schedule:
            if args.profile == "constant" and published >= args.requests:
                # iter_schedule genera por fases; para constant cortamos exactamente en N.
                break

            now = time.monotonic()
            if now < next_publish_at:
                # Controla la tasa de entrada: espera hasta el siguiente slot de publicacion.
                time.sleep(next_publish_at - now)

            payload = payload_for(args, rng, run_id, published + 1)
            if pg_connection:
                # Esta llamada devuelve el timestamp de PostgreSQL que luego se
                # envia al worker. Asi end_to_end usa el mismo reloj para inicio
                # y fin: enqueued_at y completed_at salen de PostgreSQL.
                payload["enqueued_at"] = register_request(pg_connection, args, payload, expected_messages)
            else:
                # Solo para dry/fallback. Para medicion oficial no usar este camino.
                payload["enqueued_at"] = utc_now_iso()

            body = json.dumps(payload, separators=(",", ":")).encode("utf-8")
            # Publicacion asincrona: el loadgen no espera a que la venta termine.
            # RabbitMQ desacopla tasa de llegada y tasa de procesamiento.
            channel.basic_publish(
                exchange=args.exchange,
                routing_key=args.routing_key,
                body=body,
                properties=properties,
                mandatory=False,
            )
            published += 1
            next_publish_at += interval

            if args.report_every and published % args.report_every == 0:
                elapsed = max(time.monotonic() - started, 0.001)
                print(
                    f"published={published} run_id={run_id} phase={phase.name} "
                    f"avg_rate={published / elapsed:.2f}/s",
                    flush=True,
                )
    finally:
        if pg_connection:
            pg_connection.close()
        rabbit_connection.close()

    elapsed_seconds = max(time.monotonic() - started, 0.001)
    stats = PublishStats(
        run_id=run_id,
        mode=args.mode,
        distribution=args.distribution,
        requested_messages=expected_messages,
        published_messages=published,
        started_at=started_wall,
        finished_at=utc_now_iso(),
        elapsed_seconds=elapsed_seconds,
        average_publish_rate=published / elapsed_seconds,
        phases=[
            {
                "name": phase.name,
                "duration_seconds": phase.duration_seconds,
                "rate_per_second": phase.rate_per_second,
                "messages": phase_message_count(phase),
            }
            for phase in phases
        ],
    )
    return stats


def write_summary(stats: PublishStats, summary_file: str | None) -> None:
    """Escribe el JSON local del loadgen para enlazar run_id con artefactos.

    Este JSON ayuda a saber que parametros se usaron, pero las metricas del
    informe salen de PostgreSQL con collect-run-results.ps1.
    """
    encoded = json.dumps(stats.__dict__, indent=2)
    print(encoded)
    if not summary_file:
        return
    path = Path(summary_file)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(encoded + "\n", encoding="utf-8")


def dry_run(args: argparse.Namespace) -> None:
    """Muestra un plan de carga sin conectar a RabbitMQ ni PostgreSQL."""
    validate_args(args)
    rng = random.Random(args.seed)
    run_id = args.run_id or str(uuid4())
    phases = phases_for(args)
    expected_messages = args.requests if args.profile == "constant" else sum(phase_message_count(phase) for phase in phases)
    print(
        json.dumps(
            {
                "run_id": run_id,
                "profile": args.profile,
                "mode": args.mode,
                "distribution": args.distribution,
                "expected_messages": expected_messages,
                "phases": [
                    {
                        "name": phase.name,
                        "duration_seconds": phase.duration_seconds,
                        "rate_per_second": phase.rate_per_second,
                        "messages": phase_message_count(phase),
                    }
                    for phase in phases
                ],
                "sample_payloads": [
                    payload_for(args, rng, run_id, sequence)
                    for sequence in range(1, min(args.dry_run_limit, expected_messages) + 1)
                ],
            },
            indent=2,
        )
    )


def main() -> int:
    """Punto de entrada CLI/contendedor."""
    parser = build_parser()
    args = parser.parse_args()
    try:
        if args.dry_run:
            dry_run(args)
            return 0
        stats = publish(args)
        write_summary(stats, args.summary_file)
        return 0
    except KeyboardInterrupt:
        print("interrupted", file=sys.stderr)
        return 130
    except Exception as exc:  # noqa: BLE001 - CLI should print a compact actionable error.
        print(f"loadgen error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
