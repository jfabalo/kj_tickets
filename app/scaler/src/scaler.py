"""Autoscaler para el servicio distribuido de tickets.

Explicacion simple:
    Este programa mira cuanta carga hay en RabbitMQ y decide cuantos workers
    Fargate deben estar activos. Si hay mucha llegada de mensajes o backlog,
    sube workers. Si la cola se vacia y no entra carga, baja workers para no
    gastar mas de lo necesario en AWS Academy.

Explicacion tecnica:
    Implementa directamente el punto 5 del enunciado:

        workers_por_lambda = ceil(lambda / C)
        workers_por_backlog = ceil(B / (Tr * C))
        workers_finales = max(workers_por_lambda, workers_por_backlog)

    Donde:
        lambda = tasa de llegada medida en RabbitMQ.
        C = capacidad segura por worker, estimada experimentalmente.
        B = mensajes esperando en RabbitMQ.
        Tr = tiempo objetivo de respuesta/backlog.

    El scaler no procesa ventas. Solo consulta RabbitMQ Management API y llama a
    ECS UpdateService para cambiar desired_count del servicio de workers. La
    correccion de ventas sigue estando en PostgreSQL y en el worker idempotente.
"""

from __future__ import annotations

# argparse permite ejecutar el scaler tambien desde terminal con parametros,
# no solo dentro de ECS/Fargate mediante variables de entorno.
import argparse
# logging envia las decisiones del scaler a stdout; ECS las recoge en CloudWatch.
import logging
# math.ceil se usa directamente en las formulas del enunciado.
import math
# os lee variables de entorno inyectadas por Terraform en la task definition.
import os
# signal permite parar el loop limpiamente cuando ECS manda SIGTERM.
import signal
# sys se usa para escribir errores compactos en stderr y devolver exit codes.
import sys
# time.monotonic se usa para medir intervalos/cooldowns sin depender del reloj real.
import time
# dataclass reduce boilerplate para objetos de configuracion y snapshots inmutables.
from dataclasses import dataclass
# Any se usa solo en tipos de JSON devuelto por RabbitMQ.
from typing import Any

# boto3 es el SDK AWS: aqui se usa para ECS describe_services/update_service.
import boto3
# requests consulta la RabbitMQ Management API por HTTP.
import requests

# Logger propio para distinguir logs del scaler de librerias externas.
LOGGER = logging.getLogger("ticket_scaler")
# STOP se cambia desde el signal handler para salir del loop sin matar el proceso a medias.
STOP = False


def _stop(_signum: int, _frame: object) -> None:
    """Permite parar el loop limpiamente cuando ECS envia SIGTERM."""
    # STOP es global porque el signal handler no recibe el objeto config/loop.
    global STOP
    # El loop principal revisa esta bandera y termina despues de la iteracion actual.
    STOP = True


@dataclass(frozen=True)
class ScalerConfig:
    """Configuracion del scaler, normalmente inyectada por Terraform en ECS."""

    # Region AWS donde estan ECS, RabbitMQ/PostgreSQL EC2 y CloudWatch.
    aws_region: str
    # URL HTTP de RabbitMQ Management API, por ejemplo http://<ip-privada>:15672.
    rabbitmq_management_url: str
    # Usuario RabbitMQ creado por Terraform/user_data.
    rabbitmq_user: str
    # Password RabbitMQ generada por Terraform.
    rabbitmq_password: str
    # Cola observada por el scaler. En la practica es tickets.buy.
    rabbitmq_queue: str
    # Cluster ECS donde corre el servicio de workers.
    ecs_cluster: str
    # Servicio ECS cuyo desired_count se va a modificar.
    ecs_service: str
    # Minimo de workers permitido para evitar bajar por debajo de lo configurado.
    min_workers: int
    # Maximo de workers permitido para controlar coste en AWS Academy.
    max_workers: int
    # C: capacidad segura por worker en req/s, estimada experimentalmente.
    safe_capacity_per_worker: float
    # Tr: tiempo objetivo para drenar backlog, usado en B/(Tr*C).
    target_response_time_seconds: float
    # Cada cuantos segundos el scaler toma una decision.
    poll_seconds: float
    # Tiempo minimo entre bajadas de workers para evitar flapping.
    scale_down_cooldown_seconds: float
    # Cuantos workers puede subir como maximo en una decision.
    scale_up_step: int
    # Cuantos workers puede bajar como maximo en una decision.
    scale_down_step: int
    # Si true, calcula y loguea decisiones pero no llama ECS UpdateService.
    dry_run: bool

    @staticmethod
    def from_env(args: argparse.Namespace) -> "ScalerConfig":
        """Une CLI y variables de entorno para poder correr en local o Fargate."""

        def value(name: str, default: str | None = None) -> str | None:
            # La CLI tiene prioridad sobre variables de entorno para poder probar localmente.
            cli_value = getattr(args, name.lower(), None)
            # Si el argumento no se paso por CLI, usamos variable de entorno o default.
            return cli_value if cli_value is not None else os.getenv(name, default)

        return ScalerConfig(
            # Region y credenciales salen del entorno AWS Academy/LabRole.
            aws_region=str(value("AWS_REGION", "us-east-1")),
            # RabbitMQ Management API expone backlog y tasas que alimentan la formula.
            rabbitmq_management_url=require(value("RABBITMQ_MANAGEMENT_URL"), "RABBITMQ_MANAGEMENT_URL"),
            # RabbitMQ requiere basic auth para consultar /api/queues.
            rabbitmq_user=require(value("RABBITMQ_USER", "ticket_user"), "RABBITMQ_USER"),
            rabbitmq_password=require(value("RABBITMQ_PASSWORD"), "RABBITMQ_PASSWORD"),
            # Si no se indica otra cola, escalamos segun la cola principal de compras.
            rabbitmq_queue=str(value("RABBITMQ_QUEUE", "tickets.buy")),
            # ECS service al que se le modifica desired_count.
            ecs_cluster=require(value("ECS_CLUSTER"), "ECS_CLUSTER"),
            ecs_service=require(value("ECS_SERVICE"), "ECS_SERVICE"),
            # Limites de coste/capacidad definidos en Terraform.
            min_workers=int(value("MIN_WORKERS", "0") or "0"),
            max_workers=int(value("MAX_WORKERS", "8") or "8"),
            # C y Tr son los parametros de la formula del enunciado.
            safe_capacity_per_worker=float(value("SAFE_CAPACITY_PER_WORKER", "6.5") or "6.5"),
            target_response_time_seconds=float(value("TARGET_RESPONSE_TIME_SECONDS", "10") or "10"),
            # Frecuencia y suavizado operativo del scaler.
            poll_seconds=float(value("POLL_SECONDS", "5") or "5"),
            # Este cooldown explica por que en graficas los workers bajan lentamente.
            scale_down_cooldown_seconds=float(value("SCALE_DOWN_COOLDOWN_SECONDS", "30") or "30"),
            # Subida agresiva: si el target pide muchos workers, puede subir varios de golpe.
            scale_up_step=int(value("SCALE_UP_STEP", "8") or "8"),
            # Bajada conservadora: normalmente baja 1 worker por cooldown.
            scale_down_step=int(value("SCALE_DOWN_STEP", "1") or "1"),
            # args.dry_run viene de argparse; bool lo normaliza a True/False.
            dry_run=bool(args.dry_run),
        )


def require(value: str | None, name: str) -> str:
    """Falla pronto si falta una variable critica."""
    # Sin estos valores el scaler no puede observar RabbitMQ ni modificar ECS.
    if not value:
        # Fallar al arrancar es mejor que correr un scaler silenciosamente inutil.
        raise ValueError(f"missing required configuration: {name}")
    # A partir de aqui type checker sabe que no es None.
    return value


@dataclass(frozen=True)
class QueueSnapshot:
    """Lectura de RabbitMQ usada para una decision de escalado."""

    # Mensajes esperando en cola sin haber sido entregados a ningun worker.
    ready: int
    # Mensajes ya entregados a workers pero todavia sin ACK.
    unacked: int
    # Total RabbitMQ = ready + unacked.
    total: int
    # Numero de consumidores conectados a la cola; normalmente workers running.
    consumers: int
    # Tasa suavizada de publicacion medida por RabbitMQ.
    publish_rate: float
    # Tasa suavizada de ACKs; ayuda a observar drenaje aunque no decide target.
    ack_rate: float
    # Contador acumulado de mensajes publicados; puede no existir en arranque.
    publish_count: int | None
    # Tiempo monotonic local de la muestra; permite calcular deltas entre muestras.
    timestamp: float


@dataclass(frozen=True)
class ScalingDecision:
    """Resultado completo de una evaluacion de autoscaling."""

    # desired_count actual leido desde ECS antes de decidir.
    current_workers: int
    # desired_count que queremos aplicar despues de cooldown/steps.
    desired_workers: int
    # Target teorico despues de aplicar min_workers/max_workers.
    bounded_target: int
    # Lambda estimada: mensajes por segundo de entrada.
    lambda_rate: float
    # Backlog ready usado por la formula B/(Tr*C).
    backlog_ready: int
    # Resultado parcial ceil(lambda/C).
    workers_by_lambda: int
    # Resultado parcial ceil(B/(Tr*C)).
    workers_by_backlog: int
    # Motivo textual de la decision: scale_up, scale_down, cooldown o steady.
    reason: str


class RabbitMQClient:
    """Cliente minimo de RabbitMQ Management API."""

    def __init__(self, base_url: str, username: str, password: str, queue: str) -> None:
        # Quitamos slash final para construir URLs sin doble //.
        self.base_url = base_url.rstrip("/")
        # requests acepta auth=(user,password) y genera Basic Auth.
        self.auth = (username, password)
        # Nombre de la cola observada. No es exchange ni routing key.
        self.queue = queue

    def snapshot(self) -> QueueSnapshot:
        """Lee backlog, consumidores y tasas expuestas por RabbitMQ.

        `messages_ready` es el backlog que aun no tiene worker asignado.
        `messages_unacknowledged` son mensajes entregados a workers pero todavia
        sin ACK. Para escalar usamos sobre todo ready y publish_rate: ready mide
        cola acumulada y publish_rate mide presion de entrada.
        """
        # %2F representa el vhost "/" de RabbitMQ dentro de la URL de Management API.
        url = f"{self.base_url}/api/queues/%2F/{self.queue}"
        # Timeout corto: si RabbitMQ no responde, la iteracion falla y se reintenta.
        response = requests.get(url, auth=self.auth, timeout=5)
        # Convierte HTTP 4xx/5xx en excepcion para no usar datos corruptos.
        response.raise_for_status()
        # RabbitMQ devuelve JSON con mensajes, consumidores y message_stats.
        data: dict[str, Any] = response.json()
        # RabbitMQ puede omitir message_stats si la cola acaba de crearse o no hay trafico.
        message_stats = data.get("message_stats") or {}
        # publish_details.rate es la tasa suavizada de entrada.
        publish_details = message_stats.get("publish_details") or {}
        # ack_details.rate es la tasa suavizada de confirmaciones de workers.
        ack_details = message_stats.get("ack_details") or {}
        return QueueSnapshot(
            # `or 0` evita None si RabbitMQ omite un campo.
            ready=int(data.get("messages_ready") or 0),
            # Mensajes en proceso; no se usan como B principal para no sobrerreaccionar.
            unacked=int(data.get("messages_unacknowledged") or 0),
            # Total se loguea para diagnostico: ready + unacked.
            total=int(data.get("messages") or 0),
            # Consumidores ayuda a comprobar si workers estan realmente conectados.
            consumers=int(data.get("consumers") or 0),
            # Si RabbitMQ no calcula rate todavia, asumimos 0.
            publish_rate=float(publish_details.get("rate") or 0.0),
            # ACK rate no decide escalado, pero se guarda en logs/graficas.
            ack_rate=float(ack_details.get("rate") or 0.0),
            # Contador acumulado; se normaliza porque puede venir como None/string.
            publish_count=to_int_or_none(message_stats.get("publish")),
            # Muestra temporal local para calcular lambda por delta en la siguiente iteracion.
            timestamp=time.monotonic(),
        )


def to_int_or_none(value: object) -> int | None:
    """Normaliza contadores RabbitMQ opcionales."""
    try:
        # RabbitMQ devuelve None antes de que exista el contador.
        return int(value) if value is not None else None
    except (TypeError, ValueError):
        # Si llega algo no convertible, lo ignoramos y usamos solo publish_rate.
        return None


class ECSScaler:
    """Encapsula llamadas ECS para leer y cambiar desired_count."""

    def __init__(self, region: str, cluster: str, service: str) -> None:
        # Cluster ECS donde vive el servicio worker.
        self.cluster = cluster
        # Nombre del ECS service de workers.
        self.service = service
        # Cliente ECS con credenciales del LabRole/entorno AWS.
        self.ecs = boto3.client("ecs", region_name=region)

    def current_desired_count(self) -> int:
        """Lee desired_count actual del ECS service de workers."""
        # describe_services es la fuente de verdad de cuantas tasks queremos tener.
        response = self.ecs.describe_services(cluster=self.cluster, services=[self.service])
        # AWS devuelve una lista aunque pidamos un solo servicio.
        services = response.get("services") or []
        if not services:
            # Si Terraform no creo el service o el nombre es incorrecto, paramos.
            raise RuntimeError(f"ECS service not found: cluster={self.cluster} service={self.service}")
        # desiredCount es el objetivo; runningCount puede tardar por cold start.
        return int(services[0]["desiredCount"])

    def update_desired_count(self, desired: int) -> None:
        """Aplica el nuevo numero de workers Fargate."""
        # Esta es la accion real del autoscaler: cambiar desired_count del service.
        self.ecs.update_service(cluster=self.cluster, service=self.service, desiredCount=desired)


def estimate_lambda(snapshot: QueueSnapshot, previous: QueueSnapshot | None) -> float:
    """Estima lambda usando la tasa nativa de RabbitMQ y, si existe, delta de contador.

    RabbitMQ expone una tasa suavizada (`publish_details.rate`). En loop tambien
    calculamos tasa por diferencia de contador para no depender de una sola fuente.
    """
    # Primera candidata: tasa suavizada que RabbitMQ calcula internamente.
    candidates = [snapshot.publish_rate]
    # Segunda candidata: solo se puede calcular si tenemos muestra anterior y contadores.
    if previous and snapshot.publish_count is not None and previous.publish_count is not None:
        # Segunda estimacion: diferencia de contador / tiempo entre muestras.
        elapsed = snapshot.timestamp - previous.timestamp
        # Diferencia de mensajes publicados entre la muestra anterior y la actual.
        delta = snapshot.publish_count - previous.publish_count
        if elapsed > 0 and delta >= 0:
            # Mensajes nuevos / segundos transcurridos = tasa de llegada observada.
            candidates.append(delta / elapsed)
    # Usamos la mayor estimacion para no infraescalar durante picos bruscos.
    return max(candidates)


def clamp(value: int, minimum: int, maximum: int) -> int:
    """Limita workers para proteger presupuesto AWS Academy."""
    # Primero aplica el maximo, luego el minimo. Resultado siempre queda [minimum, maximum].
    return max(minimum, min(maximum, value))


def calculate_target(snapshot: QueueSnapshot, lambda_rate: float, config: ScalerConfig) -> tuple[int, int, int]:
    """Aplica las formulas del enunciado y devuelve target bruto.

    `workers_by_lambda` responde a carga entrante: si llegan 80 msg/s y cada
    worker soporta C=6.5 msg/s, necesitamos ceil(80/6.5).

    `workers_by_backlog` responde a cola acumulada: si hay B mensajes esperando
    y queremos drenarlos en Tr segundos, necesitamos ceil(B/(Tr*C)).

    El target real es el maximo de ambos porque un pico puede manifestarse como
    llegada alta, backlog alto, o ambas cosas a la vez.
    """
    # C es la capacidad segura por worker, no el maximo teorico.
    capacity = config.safe_capacity_per_worker
    if capacity <= 0:
        # Evita division por cero y configuraciones sin sentido.
        raise ValueError("SAFE_CAPACITY_PER_WORKER must be > 0")
    # N_lambda = ceil(lambda / C): workers necesarios para la tasa de llegada actual.
    workers_by_lambda = math.ceil(lambda_rate / capacity) if lambda_rate > 0 else 0
    # N_backlog = ceil(B / (Tr*C)): workers necesarios para drenar cola en Tr segundos.
    denominator = config.target_response_time_seconds * capacity
    # Solo hay workers por backlog si hay mensajes ready pendientes.
    workers_by_backlog = math.ceil(snapshot.ready / denominator) if denominator > 0 and snapshot.ready > 0 else 0
    # Se toma el maximo porque la presion puede venir de entrada alta o de cola acumulada.
    raw_target = max(workers_by_lambda, workers_by_backlog)
    # Devolvemos tambien los terminos parciales para logs/graficas/defensa.
    return raw_target, workers_by_lambda, workers_by_backlog


def decide(
    snapshot: QueueSnapshot,
    previous_snapshot: QueueSnapshot | None,
    current_workers: int,
    config: ScalerConfig,
    last_scale_down_at: float,
) -> ScalingDecision:
    """Decide el desired_count siguiente evitando flapping al bajar.

    Subir es agresivo porque durante un spike el coste de quedarse corto es
    backlog y latencia end-to-end. Bajar es conservador mediante cooldown para
    no apagar workers justo antes de otra rafaga.
    """
    # Estimamos lambda antes de aplicar la formula.
    lambda_rate = estimate_lambda(snapshot, previous_snapshot)
    # Calculamos target bruto y los dos terminos parciales del enunciado.
    raw_target, by_lambda, by_backlog = calculate_target(snapshot, lambda_rate, config)
    # El target bruto se limita por presupuesto y por parametros del experimento.
    bounded = clamp(raw_target, config.min_workers, config.max_workers)

    if bounded > current_workers:
        # Scale-up por pasos grandes para reaccionar rapido a spikes.
        # min evita pasar del target aunque scale_up_step sea mayor.
        desired = min(bounded, current_workers + config.scale_up_step)
        reason = "scale_up"
    elif bounded < current_workers:
        # Si el target baja, comprobamos cuanto ha pasado desde la ultima bajada real.
        since_last_down = time.monotonic() - last_scale_down_at
        if since_last_down < config.scale_down_cooldown_seconds:
            # Scale-down lento: evita apagar workers justo antes de otro pico.
            desired = current_workers
            reason = "scale_down_cooldown"
        else:
            # Bajamos como maximo scale_down_step workers por cooldown.
            # max evita bajar por debajo del target calculado.
            desired = max(bounded, current_workers - config.scale_down_step)
            reason = "scale_down"
    else:
        # El numero actual ya coincide con el target limitado.
        desired = current_workers
        reason = "steady"

    # La decision empaqueta todo lo necesario para logs y para entender la accion.
    return ScalingDecision(
        current_workers=current_workers,
        desired_workers=desired,
        bounded_target=bounded,
        lambda_rate=lambda_rate,
        backlog_ready=snapshot.ready,
        workers_by_lambda=by_lambda,
        workers_by_backlog=by_backlog,
        reason=reason,
    )


def log_decision(snapshot: QueueSnapshot, decision: ScalingDecision) -> None:
    """Log estructurado: sera visible en CloudWatch cuando corra en Fargate."""
    # Un unico log contiene inputs, formula y resultado. Esto simplifica depurar
    # por que el scaler subio, bajo o se quedo igual durante una prueba.
    LOGGER.info(
        # Formato key=value para poder leerlo facilmente en CloudWatch.
        "scaling_decision reason=%s current=%s desired=%s target=%s lambda=%.2f "
        "ready=%s unacked=%s total=%s consumers=%s by_lambda=%s by_backlog=%s",
        # Motivo final de la decision.
        decision.reason,
        # desired_count antes de decidir.
        decision.current_workers,
        # desired_count que queremos aplicar.
        decision.desired_workers,
        # target despues de min/max.
        decision.bounded_target,
        # tasa de llegada estimada.
        decision.lambda_rate,
        # backlog ready observado.
        snapshot.ready,
        # mensajes ya entregados a workers pero sin ACK.
        snapshot.unacked,
        # total de mensajes en RabbitMQ.
        snapshot.total,
        # consumidores conectados.
        snapshot.consumers,
        # termino lambda/C.
        decision.workers_by_lambda,
        # termino B/(Tr*C).
        decision.workers_by_backlog,
    )


def run_once(
    rabbitmq: RabbitMQClient,
    ecs: ECSScaler,
    config: ScalerConfig,
    previous_snapshot: QueueSnapshot | None = None,
    last_scale_down_at: float = 0.0,
) -> tuple[QueueSnapshot, ScalingDecision, float]:
    """Ejecuta una sola iteracion de observar -> decidir -> aplicar.

    Esta funcion es util para defender el flujo del autoscaler:
    1. Lee RabbitMQ.
    2. Lee desired_count actual de ECS.
    3. Calcula target con las formulas.
    4. Llama UpdateService si hay cambio.
    """
    # Paso 1: observar RabbitMQ.
    snapshot = rabbitmq.snapshot()
    # Paso 2: observar ECS desired_count actual.
    current = ecs.current_desired_count()
    # Paso 3: calcular decision con formulas, min/max, steps y cooldown.
    decision = decide(snapshot, previous_snapshot, current, config, last_scale_down_at)
    # Paso 4: dejar trazabilidad de la decision en CloudWatch/stdout.
    log_decision(snapshot, decision)

    if decision.desired_workers != current:
        # Solo llamamos a ECS si realmente hay cambio de desired_count.
        if config.dry_run:
            # Dry-run permite validar formula sin modificar infraestructura.
            LOGGER.info("dry_run=true; not updating ECS desired_count")
        else:
            # Accion real: ECS empezara a crear/parar tasks Fargate.
            ecs.update_desired_count(decision.desired_workers)
            LOGGER.info("updated_ecs_service desired=%s", decision.desired_workers)
            if decision.desired_workers < current:
                # Guardamos cuando bajamos para aplicar cooldown en siguientes iteraciones.
                last_scale_down_at = time.monotonic()
    # Devolvemos snapshot para que la siguiente iteracion pueda estimar lambda por delta.
    return snapshot, decision, last_scale_down_at


def run_loop(config: ScalerConfig) -> None:
    """Loop principal para ejecutar como servicio Fargate."""
    # Cliente RabbitMQ persistente a nivel logico; cada snapshot hace HTTP GET.
    rabbitmq = RabbitMQClient(
        config.rabbitmq_management_url,
        config.rabbitmq_user,
        config.rabbitmq_password,
        config.rabbitmq_queue,
    )
    # Cliente ECS que modifica el servicio de workers.
    ecs = ECSScaler(config.aws_region, config.ecs_cluster, config.ecs_service)
    # Muestra anterior de RabbitMQ; al principio no existe.
    previous: QueueSnapshot | None = None
    # 0 permite que la primera bajada no quede bloqueada por cooldown artificial.
    last_scale_down_at = 0.0

    # El scaler vive mientras ECS mantenga la task corriendo y no llegue SIGTERM.
    while not STOP:
        try:
            # Una iteracion completa: observar, calcular, aplicar.
            previous, _decision, last_scale_down_at = run_once(
                rabbitmq,
                ecs,
                config,
                previous_snapshot=previous,
                last_scale_down_at=last_scale_down_at,
            )
        except Exception:
            # Un fallo puntual de RabbitMQ/ECS no debe matar el scaler durante una prueba larga.
            LOGGER.exception("scaler_iteration_failed")
        # Calculamos el instante de la siguiente decision.
        sleep_until = time.monotonic() + config.poll_seconds
        while not STOP and time.monotonic() < sleep_until:
            # Dormimos en trozos pequenos para reaccionar rapido a SIGTERM de ECS.
            time.sleep(0.2)


def build_parser() -> argparse.ArgumentParser:
    """CLI del scaler para local, Fargate o pruebas dry-run."""
    # Parser base del ejecutable `python -m src.scaler`.
    parser = argparse.ArgumentParser(description="Scale ECS workers from RabbitMQ load")
    # --once sirve para una unica decision manual/debug.
    parser.add_argument("--once", action="store_true", help="Run one scaling decision and exit")
    # --dry-run calcula pero no cambia ECS.
    parser.add_argument("--dry-run", action="store_true", help="Print decision without updating ECS")
    # LOG_LEVEL tambien puede venir por entorno; por defecto INFO.
    parser.add_argument("--log-level", default=os.getenv("LOG_LEVEL", "INFO"))
    # Lista de variables que Terraform inyecta y que tambien aceptamos por CLI.
    for name in (
        "AWS_REGION",
        "RABBITMQ_MANAGEMENT_URL",
        "RABBITMQ_USER",
        "RABBITMQ_PASSWORD",
        "RABBITMQ_QUEUE",
        "ECS_CLUSTER",
        "ECS_SERVICE",
        "MIN_WORKERS",
        "MAX_WORKERS",
        "SAFE_CAPACITY_PER_WORKER",
        "TARGET_RESPONSE_TIME_SECONDS",
        "POLL_SECONDS",
        "SCALE_DOWN_COOLDOWN_SECONDS",
        "SCALE_UP_STEP",
        "SCALE_DOWN_STEP",
    ):
        # Cada variable de entorno tambien se expone como argumento --nombre-en-minusculas.
        parser.add_argument(f"--{name.lower().replace('_', '-')}", dest=name.lower(), default=None)
    # Devuelve el parser listo para parse_args en main().
    return parser


def main() -> int:
    """Entrada principal."""
    # ECS manda SIGTERM al parar la task; asi damos tiempo a salir limpio.
    signal.signal(signal.SIGTERM, _stop)
    # SIGINT permite Ctrl+C si se ejecuta localmente.
    signal.signal(signal.SIGINT, _stop)
    # Lee argumentos CLI. En Fargate normalmente casi todo llega por env vars.
    args = build_parser().parse_args()
    # Configura formato de logs antes de construir config para ver errores de arranque.
    logging.basicConfig(
        # Convierte string INFO/DEBUG/etc. en constante logging.INFO...
        level=getattr(logging, str(args.log_level).upper(), logging.INFO),
        # Formato simple compatible con CloudWatch Logs.
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )
    try:
        # Une CLI + env vars en una config tipada.
        config = ScalerConfig.from_env(args)
        # Primer log de arranque: muestra limites y parametros clave de formula.
        LOGGER.info(
            "scaler_started once=%s dry_run=%s min=%s max=%s safe_capacity=%.2f target_response=%.2fs",
            args.once,
            config.dry_run,
            config.min_workers,
            config.max_workers,
            config.safe_capacity_per_worker,
            config.target_response_time_seconds,
        )
        if args.once:
            # Modo diagnostico: crea clientes, ejecuta una decision y sale.
            rabbitmq = RabbitMQClient(
                config.rabbitmq_management_url,
                config.rabbitmq_user,
                config.rabbitmq_password,
                config.rabbitmq_queue,
            )
            ecs = ECSScaler(config.aws_region, config.ecs_cluster, config.ecs_service)
            run_once(rabbitmq, ecs, config)
        else:
            # Modo normal en ECS: loop permanente de autoscaling.
            run_loop(config)
        # Si el loop termina sin excepcion, proceso correcto.
        return 0
    except Exception as exc:  # noqa: BLE001 - CLI should return a compact failure.
        # Log completo para CloudWatch.
        LOGGER.exception("scaler_failed")
        # Mensaje compacto para salida de consola/ECS stopped reason.
        print(f"scaler error: {exc}", file=sys.stderr)
        # Exit code no cero para que ECS marque fallo si ocurre al arrancar.
        return 1


if __name__ == "__main__":
    # Permite ejecutar el modulo directamente: python -m src.scaler.
    raise SystemExit(main())
