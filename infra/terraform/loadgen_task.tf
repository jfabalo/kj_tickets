# loadgen_task.tf
#
# Objetivo del archivo:
#   Definir la task ECS/Fargate del generador de carga.
#
# Diferencia con worker:
#   Loadgen NO es un servicio permanente. Se ejecuta con aws ecs run-task desde
#   scripts/run-loadgen-aws.ps1, publica la carga y termina. Esto evita pagar una
#   task Fargate cuando no se esta ejecutando un experimento.

locals {
  # Solo se define loadgen cuando ya existe la infra base y el cluster worker.
  loadgen_task_on = var.enable_core_infra && var.enable_worker_service

  # Imagen Docker completa del generador de carga en ECR.
  loadgen_image = var.enable_core_infra ? "${aws_ecr_repository.loadgen[0].repository_url}:${var.loadgen_image_tag}" : ""
}

resource "aws_cloudwatch_log_group" "loadgen" {
  # Grupo de logs creado solo cuando la task definition existe.
  count = local.loadgen_task_on ? 1 : 0

  # Logs separados para distinguir productor de carga de workers.
  name = "/ecs/${local.core_name}-loadgen"
  # Retencion corta para ahorrar coste.
  retention_in_days = 1
}

resource "aws_ecs_task_definition" "loadgen" {
  # Plantilla de ejecucion one-shot para el load generator.
  count = local.loadgen_task_on ? 1 : 0

  # Familia visible en ECS task definitions.
  family = "${local.core_name}-loadgen"
  # Ejecutar en Fargate, sin EC2 administradas por nosotros.
  requires_compatibilities = ["FARGATE"]
  # Cada task obtiene ENI propia.
  network_mode = "awsvpc"
  # Recursos pequenos suficientes para generar carga de la practica.
  cpu    = "256"
  memory = "512"
  # Rol para pull de ECR y logs.
  execution_role_arn = data.aws_iam_role.worker_lab_role[0].arn
  # Rol disponible para la task si necesitara AWS APIs.
  task_role_arn = data.aws_iam_role.worker_lab_role[0].arn

  # Definicion del contenedor que ejecuta app/loadgen.
  container_definitions = jsonencode([
    {
      # Nombre usado por run-loadgen-aws.ps1 en containerOverrides.
      name = "ticket-loadgen"
      # Imagen ECR construida desde app/loadgen.
      image = local.loadgen_image
      # Si falla el contenedor, falla la task.
      essential = true

      # Valores por defecto de conexion. El comando de carga concreto se pasa
      # como override en cada ejecucion.
      environment = [
        # Region AWS disponible dentro del contenedor.
        { name = "AWS_REGION", value = var.aws_region },
        # RabbitMQ por IP privada para no depender de la red local.
        { name = "RABBITMQ_HOST", value = aws_instance.rabbitmq[0].private_ip },
        # Puerto AMQP.
        { name = "RABBITMQ_PORT", value = tostring(local.rabbitmq_port) },
        # Credenciales RabbitMQ generadas por Terraform.
        { name = "RABBITMQ_USER", value = local.rabbitmq_user },
        { name = "RABBITMQ_PASSWORD", value = random_password.rabbitmq[0].result },
        # Exchange y routing key donde se publican compras.
        { name = "RABBITMQ_EXCHANGE", value = "tickets.exchange" },
        { name = "RABBITMQ_ROUTING_KEY", value = "ticket.buy" },
        # PostgreSQL privado para registrar enqueued_at con reloj de AWS.
        { name = "POSTGRES_HOST", value = aws_instance.postgres[0].private_ip },
        { name = "POSTGRES_PORT", value = tostring(local.postgres_port) },
        { name = "POSTGRES_DB", value = local.postgres_db },
        { name = "POSTGRES_USER", value = local.postgres_user },
        { name = "POSTGRES_PASSWORD", value = random_password.postgres[0].result }
      ]

      # Logs del loadgen: run_id, parametros y estado final.
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.loadgen[0].name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])
}
