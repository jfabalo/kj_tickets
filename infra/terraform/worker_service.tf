# worker_service.tf
#
# Objetivo del archivo:
#   Definir el servicio ECS/Fargate que ejecuta los workers de venta.
#
# Papel en la arquitectura:
#   Cada task worker consume mensajes desde RabbitMQ, aplica el delay artificial
#   de 100 ms y confirma la venta en PostgreSQL. Los workers son stateless: si
#   una task muere, otra puede continuar procesando mensajes de la cola.

locals {
  # Flag derivado: solo creamos workers si existe la infraestructura base y el
  # usuario ha activado explicitamente el servicio de workers.
  worker_service_on = var.enable_core_infra && var.enable_worker_service

  # Imagen Docker completa que ECS descargara desde ECR.
  # Si core infra esta desactivada, dejamos string vacio para no referenciar ECR[0].
  worker_image = var.enable_core_infra ? "${aws_ecr_repository.worker[0].repository_url}:${var.worker_image_tag}" : ""
}

# AWS Academy proporciona un rol IAM llamado LabRole.
# Lo reutilizamos como execution_role y task_role porque el laboratorio limita
# la creacion de roles personalizados.
data "aws_iam_role" "worker_lab_role" {
  # Solo se consulta cuando realmente vamos a crear el service/task definition.
  count = local.worker_service_on ? 1 : 0

  # Nombre exacto del rol precreado por AWS Academy.
  name = "LabRole"
}

resource "aws_cloudwatch_log_group" "worker" {
  # Si el servicio esta apagado a nivel Terraform, tampoco creamos logs.
  count = local.worker_service_on ? 1 : 0

  # Nombre estable del grupo de logs para encontrar los logs del worker.
  name = "/ecs/${local.core_name}-worker"
  # Retencion corta para reducir coste en AWS Academy.
  retention_in_days = 1
}

resource "aws_ecs_cluster" "worker" {
  # Cluster ECS que agrupa workers, loadgen one-shot y autoscaler.
  count = local.worker_service_on ? 1 : 0

  # Nombre visible en la consola ECS.
  name = "${local.core_name}-worker"
}

resource "aws_ecs_task_definition" "worker" {
  # La task definition describe como ejecutar un contenedor worker.
  count = local.worker_service_on ? 1 : 0

  # Familia/version logica de la task definition.
  family = "${local.core_name}-worker"
  # FARGATE indica que no gestionamos instancias ECS propias.
  requires_compatibilities = ["FARGATE"]
  # awsvpc da una interfaz de red propia a cada task.
  network_mode = "awsvpc"
  # CPU asignada a cada worker. 256 = 0.25 vCPU.
  cpu = var.worker_cpu
  # Memoria asignada a cada worker en MiB.
  memory = var.worker_memory
  # Rol que permite a ECS descargar imagen de ECR y escribir logs.
  execution_role_arn = data.aws_iam_role.worker_lab_role[0].arn
  # Rol disponible dentro del contenedor; necesario para enviar a SQS DLQ.
  task_role_arn = data.aws_iam_role.worker_lab_role[0].arn

  # Definicion del contenedor en JSON. jsonencode permite escribirlo como HCL.
  container_definitions = jsonencode([
    {
      # Nombre del contenedor dentro de la task.
      name = "ticket-worker"
      # Imagen ECR construida desde app/worker.
      image = local.worker_image
      # Si el contenedor falla, la task completa se considera fallida.
      essential = true

      # Variables de entorno consumidas por app/worker/src/worker.py.
      environment = [
        # Region AWS para boto3/SQS.
        { name = "AWS_REGION", value = var.aws_region },
        # Etiqueta de entorno usada en logs.
        { name = "TICKET_ENV", value = var.environment },

        # RabbitMQ se alcanza por IP privada porque worker y EC2 estan en la VPC.
        { name = "RABBITMQ_HOST", value = aws_instance.rabbitmq[0].private_ip },
        # Puerto AMQP del broker RabbitMQ.
        { name = "RABBITMQ_PORT", value = tostring(local.rabbitmq_port) },
        # Usuario creado durante el bootstrap de RabbitMQ.
        { name = "RABBITMQ_USER", value = local.rabbitmq_user },
        # Password aleatoria generada por Terraform.
        { name = "RABBITMQ_PASSWORD", value = random_password.rabbitmq[0].result },
        # Exchange direct donde el loadgen publica compras.
        { name = "RABBITMQ_EXCHANGE", value = "tickets.exchange" },
        # Cola que consume el worker.
        { name = "RABBITMQ_QUEUE", value = local.rabbitmq_queue },
        # Routing key enlazada a la cola tickets.buy.
        { name = "RABBITMQ_ROUTING_KEY", value = "ticket.buy" },

        # PostgreSQL privado: base de datos fuente de verdad.
        { name = "POSTGRES_HOST", value = aws_instance.postgres[0].private_ip },
        # Puerto PostgreSQL expuesto por el contenedor en EC2.
        { name = "POSTGRES_PORT", value = tostring(local.postgres_port) },
        # Nombre de base de datos creado por POSTGRES_DB.
        { name = "POSTGRES_DB", value = local.postgres_db },
        # Usuario de aplicacion.
        { name = "POSTGRES_USER", value = local.postgres_user },
        # Password aleatoria de PostgreSQL.
        { name = "POSTGRES_PASSWORD", value = random_password.postgres[0].result },

        # DLQ donde el worker envia mensajes invalidos o fallos definitivos.
        { name = "SQS_DLQ_URL", value = aws_sqs_queue.ticket_failures_dlq[0].url },
        # Prefetch 1: cada worker toma un mensaje a la vez, simplificando C.
        { name = "WORKER_PREFETCH", value = "1" },
        # Numero maximo de intentos antes de mandar a DLQ.
        { name = "MAX_ATTEMPTS", value = "3" },
        # Requisito del enunciado: simular pago externo dentro del worker.
        { name = "PAYMENT_DELAY_MS", value = "100" },
        # Nivel de logging del contenedor.
        { name = "LOG_LEVEL", value = "INFO" }
      ]

      # Envia stdout/stderr del contenedor a CloudWatch Logs.
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          # Grupo de logs creado arriba.
          awslogs-group = aws_cloudwatch_log_group.worker[0].name
          # Region donde CloudWatch Logs recibe eventos.
          awslogs-region = var.aws_region
          # Prefijo de streams dentro del grupo.
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "worker" {
  # El service mantiene desired_count tasks worker vivas.
  count = local.worker_service_on ? 1 : 0

  # Nombre visible del servicio en ECS.
  name = "${local.core_name}-worker"
  # Cluster donde se ejecuta el servicio.
  cluster = aws_ecs_cluster.worker[0].id
  # Revision de task definition que ejecutara ECS.
  task_definition = aws_ecs_task_definition.worker[0].arn
  # Numero deseado de workers; el autoscaler lo modifica con ECS UpdateService.
  desired_count = var.worker_desired_count
  # Fargate evita administrar EC2 para workers.
  launch_type = "FARGATE"

  network_configuration {
    # ECS puede colocar tasks en cualquiera de las subnets default.
    subnets = data.aws_subnets.default.ids
    # Security group sin inbound y con egress hacia AWS/EC2.
    security_groups = [aws_security_group.workers[0].id]
    # Public IP necesaria para que Fargate pueda llegar a ECR/CloudWatch sin NAT.
    assign_public_ip = true
  }

  depends_on = [
    # Asegura que el log group existe antes de arrancar contenedores.
    aws_cloudwatch_log_group.worker,
    # Asegura que RabbitMQ este creado antes de workers que consumen.
    aws_instance.rabbitmq,
    # Asegura que PostgreSQL este creado antes de workers que escriben ventas.
    aws_instance.postgres
  ]
}
