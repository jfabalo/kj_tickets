"""Worker principal del servicio distribuido de venta de tickets.

Explicacion simple:
    Este proceso es el vendedor real. No recibe peticiones HTTP; recibe mensajes
    desde RabbitMQ. Cada mensaje representa un intento de compra. El worker lee
    el mensaje, espera 100 ms para simular el pago externo y escribe el resultado
    en PostgreSQL. Si la venta se puede hacer, marca el ticket como vendido. Si
    no se puede, deja registrado por que no se vendio.

Explicacion tecnica:
    RabbitMQ entrega los mensajes con semantica at-least-once: un mensaje puede
    llegar mas de una vez si hay fallos o reintentos. Por eso la correccion no se
    basa en RabbitMQ, sino en PostgreSQL. Cada request tiene un request_id unico,
    se bloquea con SELECT ... FOR UPDATE dentro de una transaccion y las tablas
    tienen restricciones UNIQUE/CHECK. Para entradas corruptas o fallos agotados
    se usa una SQS DLQ. Las marcas temporales importantes se generan en
    PostgreSQL con clock_timestamp() para medir end-to-end sin mezclar relojes.

Conexiones principales:
    - RabbitMQ EC2: consume de la cola durable tickets.buy.
    - PostgreSQL EC2: registra requests, ventas, asientos y metricas.
    - SQS DLQ: guarda mensajes imposibles de procesar correctamente.
    - CloudWatch Logs: recibe stdout/stderr del contenedor Fargate.
"""

from __future__ import annotations

import json
import logging
import os
import signal
import sys
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any
from uuid import UUID

import boto3
import pika
import psycopg
from dotenv import load_dotenv
from pika.adapters.blocking_connection import BlockingChannel
from pika.spec import Basic, BasicProperties
from psycopg.rows import dict_row

LOGGER = logging.getLogger("ticket-worker")


class PermanentMessageError(Exception):
    """Error no recuperable: el mensaje esta mal formado y no debe reintentarse."""


@dataclass(frozen=True)
class Config:
    """Configuracion del worker leida desde variables de entorno.

    Terraform inyecta estas variables en la task definition de ECS/Fargate. Asi
    el codigo no contiene IPs, passwords ni nombres acoplados al entorno. En AWS
    usamos IPs privadas para RabbitMQ y PostgreSQL porque el worker corre dentro
    de la misma VPC.
    """

    aws_region: str
    rabbitmq_host: str
    rabbitmq_port: int
    rabbitmq_user: str
    rabbitmq_password: str
    rabbitmq_exchange: str
    rabbitmq_queue: str
    rabbitmq_routing_key: str
    postgres_host: str
    postgres_port: int
    postgres_db: str
    postgres_user: str
    postgres_password: str
    sqs_dlq_url: str
    worker_prefetch: int
    max_attempts: int
    payment_delay_ms: int

    @staticmethod
    def from_env() -> "Config":
        """Construye Config desde el entorno del contenedor.

        `require_env` se usa para valores sin los que el worker no puede operar:
        host/password de RabbitMQ y host/password de PostgreSQL. El resto tiene
        defaults razonables para ejecucion local o pruebas.
        """
        load_dotenv()
        return Config(
            aws_region=getenv("AWS_REGION", "us-east-1"),
            rabbitmq_host=require_env("RABBITMQ_HOST"),
            rabbitmq_port=int(getenv("RABBITMQ_PORT", "5672")),
            rabbitmq_user=getenv("RABBITMQ_USER", "ticket_user"),
            rabbitmq_password=require_env("RABBITMQ_PASSWORD"),
            rabbitmq_exchange=getenv("RABBITMQ_EXCHANGE", "tickets.exchange"),
            rabbitmq_queue=getenv("RABBITMQ_QUEUE", "tickets.buy"),
            rabbitmq_routing_key=getenv("RABBITMQ_ROUTING_KEY", "ticket.buy"),
            postgres_host=require_env("POSTGRES_HOST"),
            postgres_port=int(getenv("POSTGRES_PORT", "5432")),
            postgres_db=getenv("POSTGRES_DB", "tickets"),
            postgres_user=getenv("POSTGRES_USER", "ticket_user"),
            postgres_password=require_env("POSTGRES_PASSWORD"),
            sqs_dlq_url=getenv("SQS_DLQ_URL", ""),
            worker_prefetch=int(getenv("WORKER_PREFETCH", "1")),
            max_attempts=int(getenv("MAX_ATTEMPTS", "3")),
            payment_delay_ms=int(getenv("PAYMENT_DELAY_MS", "100")),
        )

    @property
    def postgres_dsn(self) -> str:
        """Cadena de conexion psycopg para PostgreSQL."""
        return (
            f"host={self.postgres_host} port={self.postgres_port} "
            f"dbname={self.postgres_db} user={self.postgres_user} "
            f"password={self.postgres_password} connect_timeout=5"
        )


def getenv(name: str, default: str) -> str:
    """Wrapper pequeno para hacer explicitos los defaults de entorno."""
    return os.getenv(name, default)


def require_env(name: str) -> str:
    """Lee una variable obligatoria y falla rapido si no existe."""
    value = os.getenv(name)
    if not value:
        raise RuntimeError(f"Missing required environment variable: {name}")
    return value


def utc_now() -> datetime:
    """Timestamp UTC usado para envelopes de DLQ, no para metricas principales."""
    return datetime.now(timezone.utc)


def parse_uuid(value: Any, field: str) -> UUID:
    """Valida UUIDs de entrada para impedir mensajes ambiguos o no idempotentes."""
    try:
        return UUID(str(value))
    except (TypeError, ValueError) as exc:
        raise PermanentMessageError(f"Invalid {field}: {value!r}") from exc


def parse_timestamp(value: Any, field: str) -> datetime:
    """Normaliza timestamps recibidos en el payload.

    El loadgen actual ya inserta `enqueued_at` en PostgreSQL y manda ese valor en
    el mensaje. Este fallback existe para compatibilidad con mensajes antiguos o
    pruebas manuales, pero las metricas fiables salen del reloj de PostgreSQL.
    """
    if value is None:
        return utc_now()
    if isinstance(value, (int, float)):
        return datetime.fromtimestamp(value, tz=timezone.utc)
    if not isinstance(value, str):
        raise PermanentMessageError(f"Invalid {field}: {value!r}")
    try:
        normalized = value.replace("Z", "+00:00")
        parsed = datetime.fromisoformat(normalized)
    except ValueError as exc:
        raise PermanentMessageError(f"Invalid {field}: {value!r}") from exc
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def decode_payload(body: bytes) -> dict[str, Any]:
    """Convierte el cuerpo RabbitMQ a JSON dict o marca el mensaje como invalido."""
    try:
        payload = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise PermanentMessageError("Message body is not valid UTF-8 JSON") from exc
    if not isinstance(payload, dict):
        raise PermanentMessageError("Message body must be a JSON object")
    return payload


def validate_payload(payload: dict[str, Any]) -> dict[str, Any]:
    """Valida la semantica de una compra antes de tocar PostgreSQL.

    Modo numbered: requiere seat_id 1..100000.
    Modo unnumbered: no usa asiento concreto, solo contador global de tickets.
    """
    # request_id identifica una compra concreta; sin el no podemos hacer idempotencia.
    request_id = parse_uuid(payload.get("request_id"), "request_id")
    # run_id agrupa todas las compras de un experimento para metricas/CSV.
    run_id = parse_uuid(payload.get("run_id"), "run_id")
    # mode decide que algoritmo de venta se aplica: asiento concreto o contador global.
    mode = payload.get("mode")
    if mode not in {"unnumbered", "numbered"}:
        raise PermanentMessageError("mode must be 'unnumbered' or 'numbered'")

    seat_id = payload.get("seat_id")
    if mode == "numbered":
        if seat_id is None:
            raise PermanentMessageError("numbered mode requires seat_id")
        try:
            seat_id = int(seat_id)
        except (TypeError, ValueError) as exc:
            raise PermanentMessageError(f"Invalid seat_id: {seat_id!r}") from exc
        if seat_id < 1 or seat_id > 100000:
            raise PermanentMessageError("seat_id must be between 1 and 100000")
    else:
        # En modo unnumbered cualquier seat_id recibido se ignora: solo importa el pool global.
        seat_id = None

    # En el camino oficial este timestamp viene de PostgreSQL, no del reloj local.
    enqueued_at = parse_timestamp(payload.get("enqueued_at"), "enqueued_at")
    workload_name = str(payload.get("workload_name") or "auto-created-by-worker")
    return {
        "request_id": request_id,
        "run_id": run_id,
        "workload_name": workload_name,
        "mode": mode,
        "seat_id": seat_id,
        "enqueued_at": enqueued_at,
    }


def message_attempt(properties: BasicProperties | None) -> int:
    """Extrae el numero de intento desde headers RabbitMQ.

    RabbitMQ no incrementa un contador de intento por nosotros cuando republicamos.
    Por eso escribimos y leemos `x-attempt` manualmente.
    """
    headers = properties.headers if properties and properties.headers else {}
    try:
        return max(1, int(headers.get("x-attempt", 1)))
    except (TypeError, ValueError):
        return 1


class TicketWorker:
    """Consumidor RabbitMQ que ejecuta compras de tickets de forma transaccional."""

    def __init__(self, config: Config) -> None:
        self.config = config
        # Cliente SQS usado solo para DLQ; no participa en las ventas correctas.
        self.sqs = boto3.client("sqs", region_name=config.aws_region)
        # La conexion AMQP se abre en connect_rabbitmq para permitir retry externo si fallara al arrancar.
        self.connection: pika.BlockingConnection | None = None
        self.channel: BlockingChannel | None = None
        # Flag de parada suave usado cuando ECS manda SIGTERM.
        self.should_stop = False

    def connect_rabbitmq(self) -> None:
        """Abre la conexion AMQP y declara exchange/queue/binding.

        - host/port/usuario/password llegan desde Terraform por variables de entorno.
        - exchange direct + routing_key `ticket.buy` enruta compras a `tickets.buy`.
        - queue durable + delivery_mode=2 en publish sobreviven a reinicios del broker.
        - prefetch=1 hace que cada worker procese un mensaje cada vez, simplificando
          calculos de capacidad por worker con el delay artificial de 100 ms.
        """
        credentials = pika.PlainCredentials(
            self.config.rabbitmq_user,
            self.config.rabbitmq_password,
        )
        params = pika.ConnectionParameters(
            host=self.config.rabbitmq_host,
            port=self.config.rabbitmq_port,
            credentials=credentials,
            heartbeat=60,
            blocked_connection_timeout=120,
        )
        self.connection = pika.BlockingConnection(params)
        self.channel = self.connection.channel()
        self.channel.exchange_declare(
            exchange=self.config.rabbitmq_exchange,
            exchange_type="direct",
            durable=True,
        )
        self.channel.queue_declare(queue=self.config.rabbitmq_queue, durable=True)
        self.channel.queue_bind(
            queue=self.config.rabbitmq_queue,
            exchange=self.config.rabbitmq_exchange,
            routing_key=self.config.rabbitmq_routing_key,
        )
        self.channel.basic_qos(prefetch_count=self.config.worker_prefetch)

    def run(self) -> None:
        """Bucle principal del worker.

        `auto_ack=False` significa que RabbitMQ solo elimina el mensaje cuando
        llamamos a basic_ack. Si el contenedor muere durante el proceso, RabbitMQ
        puede redeliverarlo y PostgreSQL lo resolvera por idempotencia.
        """
        self.connect_rabbitmq()
        assert self.channel is not None
        LOGGER.info("worker started queue=%s", self.config.rabbitmq_queue)
        self.channel.basic_consume(
            queue=self.config.rabbitmq_queue,
            on_message_callback=self.on_message,
            auto_ack=False,
        )
        while not self.should_stop:
            # BlockingConnection no usa async/await; esta llamada bombea eventos de RabbitMQ.
            self.connection.process_data_events(time_limit=1)  # type: ignore[union-attr]
        LOGGER.info("worker stopping")
        if self.connection and self.connection.is_open:
            self.connection.close()

    def stop(self, *_args: Any) -> None:
        """Marca parada suave cuando ECS envia SIGTERM al task."""
        self.should_stop = True

    def on_message(
        self,
        channel: BlockingChannel,
        method: Basic.Deliver,
        properties: BasicProperties,
        body: bytes,
    ) -> None:
        """Callback invocado por RabbitMQ por cada mensaje recibido.

        Flujo de errores:
        - Mensaje mal formado: no sirve reintentar, se manda a SQS DLQ y se hace ack.
        - Error transitorio: se republica con x-attempt+1 o acaba en DLQ al limite.
        - Exito: se confirma con basic_ack despues de commit en PostgreSQL.
        """
        attempt = message_attempt(properties)
        try:
            raw_payload = decode_payload(body)
            payload = validate_payload(raw_payload)
            result = self.process_payload(payload, attempt)
            LOGGER.info(
                "processed request_id=%s result=%s attempt=%s",
                payload["request_id"],
                result,
                attempt,
            )
            # ACK despues de procesar evita perder mensajes si el worker muere antes del commit.
            channel.basic_ack(method.delivery_tag)
        except PermanentMessageError as exc:
            LOGGER.warning("permanent message error attempt=%s error=%s", attempt, exc)
            self.send_dlq(body, attempt, "permanent_message_error", str(exc))
            # ACK porque el mensaje ya esta en DLQ y reintentarlo no arreglaria el payload.
            channel.basic_ack(method.delivery_tag)
        except Exception as exc:  # noqa: BLE001 - any unexpected processing failure must be retried safely.
            LOGGER.exception("transient processing error attempt=%s", attempt)
            self.retry_or_dlq(channel, method, properties, body, attempt, exc)

    def process_payload(self, payload: dict[str, Any], attempt: int) -> str:
        """Ejecuta una compra dentro de una unica transaccion PostgreSQL.

        Esta funcion es el centro de la consistencia fuerte:
        1. Asegura que existen `experiment_runs` y `requests`.
        2. Bloquea la request con FOR UPDATE para serializar duplicados.
        3. Si ya estaba completada, devuelve el resultado anterior: idempotencia.
        4. Marca inicio de worker con clock_timestamp().
        5. Aplica el delay de pago de 100 ms exigido por el enunciado.
        6. Ejecuta la venta numbered o unnumbered con UPDATE condicional.
        """
        with psycopg.connect(self.config.postgres_dsn, row_factory=dict_row) as conn:
            with conn.transaction():
                with conn.cursor() as cur:
                    self.ensure_experiment_run(cur, payload)
                    self.ensure_request_row(cur, payload)
                    existing = self.lock_request(cur, payload["request_id"])
                    if existing["status"] in {"completed", "failed"}:
                        # Idempotencia: si llega duplicado, devolvemos resultado previo sin vender de nuevo.
                        return str(existing["result"] or existing["status"])

                    cur.execute(
                        """
                        UPDATE requests
                        SET status = 'processing',
                            attempts = attempts + 1,
                            worker_started_at = clock_timestamp(),
                            error = NULL
                        WHERE request_id = %s
                        """,
                        (payload["request_id"],),
                    )

                    # Requisito del enunciado: cada compra simula 100 ms de pago
                    # externo dentro del worker, por tanto limita throughput real.
                    time.sleep(self.config.payment_delay_ms / 1000.0)

                    if payload["mode"] == "unnumbered":
                        return self.sell_unnumbered(cur, payload)
                    return self.sell_numbered(cur, payload)

    @staticmethod
    def ensure_experiment_run(cur: Any, payload: dict[str, Any]) -> None:
        """Crea el run si el loadgen no lo habia creado aun.

        Normalmente el loadgen registra el run antes de publicar. Este fallback
        evita perder mensajes manuales o antiguos.
        """
        cur.execute(
            """
            INSERT INTO experiment_runs(run_id, workload_name, mode, started_at, notes)
            VALUES (%s, %s, %s, %s, 'Created because the worker saw this run_id first')
            ON CONFLICT (run_id) DO NOTHING
            """,
            (
                payload["run_id"],
                payload["workload_name"],
                payload["mode"],
                payload["enqueued_at"],
            ),
        )

    @staticmethod
    def ensure_request_row(cur: Any, payload: dict[str, Any]) -> None:
        """Inserta la request si no existe; request_id PRIMARY KEY evita duplicados."""
        cur.execute(
            """
            INSERT INTO requests(request_id, run_id, mode, seat_id, status, attempts, enqueued_at)
            VALUES (%s, %s, %s, %s, 'received', 0, %s)
            ON CONFLICT (request_id) DO NOTHING
            """,
            (
                payload["request_id"],
                payload["run_id"],
                payload["mode"],
                payload["seat_id"],
                payload["enqueued_at"],
            ),
        )

    @staticmethod
    def lock_request(cur: Any, request_id: UUID) -> dict[str, Any]:
        """Bloquea una request concreta para que duplicados no compitan entre si."""
        cur.execute(
            """
            SELECT status, result, error
            FROM requests
            WHERE request_id = %s
            FOR UPDATE
            """,
            (request_id,),
        )
        row = cur.fetchone()
        if row is None:
            raise RuntimeError(f"request row was not created: {request_id}")
        return row

    @staticmethod
    def sell_unnumbered(cur: Any, payload: dict[str, Any]) -> str:
        """Venta de ticket no numerado usando contador atomico.

        `UPDATE ... WHERE sold_count < total_tickets` es la proteccion contra
        overselling. PostgreSQL bloquea la fila `ticket_pools.main`; si ya se
        llego al limite, no actualiza nada y devolvemos sold_out.
        """
        cur.execute(
            """
            UPDATE ticket_pools
            SET sold_count = sold_count + 1
            WHERE pool_id = 'main'
              AND sold_count < total_tickets
            RETURNING sold_count
            """,
        )
        row = cur.fetchone()
        if row is None:
            TicketWorker.complete_request(cur, payload["request_id"], "sold_out", None)
            return "sold_out"

        cur.execute(
            """
            INSERT INTO sales(request_id, mode, sold_at)
            VALUES (%s, 'unnumbered', clock_timestamp())
            """,
            (payload["request_id"],),
        )
        TicketWorker.complete_request(cur, payload["request_id"], "sold", None)
        return "sold"

    @staticmethod
    def sell_numbered(cur: Any, payload: dict[str, Any]) -> str:
        """Venta de asiento numerado usando UPDATE condicional por asiento.

        Dos workers pueden intentar vender el mismo seat_id. Solo uno conseguira
        cambiar `available` a `sold`; el otro no recibira fila en RETURNING y se
        marcara como seat_unavailable. Ademas `sales.seat_id UNIQUE` es una red
        de seguridad adicional.
        """
        cur.execute(
            """
            UPDATE seats
            SET status = 'sold', request_id = %s, sold_at = clock_timestamp()
            WHERE seat_id = %s
              AND status = 'available'
            RETURNING seat_id
            """,
            (payload["request_id"], payload["seat_id"]),
        )
        row = cur.fetchone()
        if row is None:
            TicketWorker.complete_request(
                cur,
                payload["request_id"],
                "seat_unavailable",
                None,
            )
            return "seat_unavailable"

        cur.execute(
            """
            INSERT INTO sales(request_id, mode, seat_id, sold_at)
            VALUES (%s, 'numbered', %s, clock_timestamp())
            """,
            (payload["request_id"], payload["seat_id"]),
        )
        TicketWorker.complete_request(cur, payload["request_id"], "sold", None)
        return "sold"

    @staticmethod
    def complete_request(
        cur: Any,
        request_id: UUID,
        result: str,
        error: str | None,
    ) -> None:
        """Marca la request como completada y fija completed_at en PostgreSQL."""
        cur.execute(
            """
            UPDATE requests
            SET status = 'completed',
                result = %s,
                error = %s,
                completed_at = clock_timestamp()
            WHERE request_id = %s
            """,
            (result, error, request_id),
        )

    def retry_or_dlq(
        self,
        channel: BlockingChannel,
        method: Basic.Deliver,
        properties: BasicProperties,
        body: bytes,
        attempt: int,
        exc: Exception,
    ) -> None:
        """Reintenta errores transitorios o manda a DLQ al superar max_attempts."""
        if attempt >= self.config.max_attempts:
            # Al limite de intentos preferimos DLQ a bloquear RabbitMQ con un poison message.
            self.send_dlq(body, attempt, "max_attempts_exceeded", repr(exc))
            channel.basic_ack(method.delivery_tag)
            return

        # Copiamos headers existentes para conservar trazabilidad y solo modificar x-attempt.
        retry_headers = dict(properties.headers or {})
        retry_headers["x-attempt"] = attempt + 1
        retry_properties = BasicProperties(
            content_type=properties.content_type or "application/json",
            delivery_mode=2,
            headers=retry_headers,
        )
        try:
            # Republicamos el mismo body para conservar request_id y mantener
            # idempotencia. El unico cambio es el contador x-attempt.
            channel.basic_publish(
                exchange=self.config.rabbitmq_exchange,
                routing_key=self.config.rabbitmq_routing_key,
                body=body,
                properties=retry_properties,
            )
            channel.basic_ack(method.delivery_tag)
            LOGGER.info("republished retry attempt=%s", attempt + 1)
        except Exception:
            LOGGER.exception("could not republish retry; requeueing original message")
            # Si ni siquiera podemos republicar el retry, pedimos a RabbitMQ que redelivere el original.
            channel.basic_nack(method.delivery_tag, requeue=True)

    def send_dlq(self, body: bytes, attempt: int, reason: str, error: str) -> None:
        """Envia a SQS DLQ informacion suficiente para diagnosticar el fallo.

        La DLQ no participa en el camino feliz de ventas. Solo conserva evidencia
        de mensajes que no deben seguir bloqueando RabbitMQ: payload corrupto,
        validacion imposible o reintentos agotados.
        """
        if not self.config.sqs_dlq_url:
            LOGGER.error("SQS_DLQ_URL not configured reason=%s error=%s", reason, error)
            return

        envelope = {
            "reason": reason,
            "error": error,
            "attempt": attempt,
            "failed_at": utc_now().isoformat(),
            "body": body.decode("utf-8", errors="replace"),
        }
        self.sqs.send_message(
            QueueUrl=self.config.sqs_dlq_url,
            MessageBody=json.dumps(envelope, separators=(",", ":")),
        )
        LOGGER.warning("sent message to dlq reason=%s attempt=%s", reason, attempt)


def configure_logging() -> None:
    """Configura logs para que CloudWatch muestre eventos legibles por linea."""
    level = os.getenv("LOG_LEVEL", "INFO").upper()
    logging.basicConfig(
        level=level,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    logging.getLogger("pika").setLevel(os.getenv("PIKA_LOG_LEVEL", "WARNING").upper())


def main() -> int:
    """Punto de entrada del contenedor Fargate."""
    configure_logging()
    config = Config.from_env()
    worker = TicketWorker(config)
    signal.signal(signal.SIGTERM, worker.stop)
    signal.signal(signal.SIGINT, worker.stop)
    worker.run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
