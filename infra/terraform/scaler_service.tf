# scaler_service.tf
#
# Objetivo del archivo:
#   Definir el autoscaler como servicio ECS/Fargate.
#
# Papel en la practica:
#   Implementa el requisito principal de escalado dinamico. Lee metricas reales de
#   RabbitMQ, calcula workers necesarios con lambda/C y B/(Tr*C), y actualiza el
#   desired_count del servicio ECS de workers.

locals {
  # Solo tiene sentido crear scaler si existen core infra, worker service y el
  # usuario activo explicitamente enable_scaler_service.
  scaler_service_on = var.enable_core_infra && var.enable_worker_service && var.enable_scaler_service

  # Imagen Docker completa del autoscaler en ECR.
  scaler_image = var.enable_core_infra ? "${aws_ecr_repository.scaler[0].repository_url}:${var.scaler_image_tag}" : ""
}

resource "aws_cloudwatch_log_group" "scaler" {
  # Grupo de logs creado solo si existe el servicio autoscaler.
  count = local.scaler_service_on ? 1 : 0

  # Logs separados para ver decisiones de escalado y formulas.
  name = "/ecs/${local.core_name}-scaler"
  # Retencion corta para controlar coste en AWS Academy.
  retention_in_days = 1
}

resource "aws_ecs_task_definition" "scaler" {
  # Plantilla de task que ejecuta app/scaler.
  count = local.scaler_service_on ? 1 : 0

  # Familia visible en ECS.
  family = "${local.core_name}-scaler"
  # Se ejecuta en Fargate.
  requires_compatibilities = ["FARGATE"]
  # Necesario para Fargate: cada task tiene su interfaz de red.
  network_mode = "awsvpc"
  # Recursos pequenos: el scaler solo consulta APIs y calcula formulas.
  cpu    = "256"
  memory = "512"
  # Rol para pull de ECR y CloudWatch Logs.
  execution_role_arn = data.aws_iam_role.worker_lab_role[0].arn
  # Rol usado por boto3 para llamar ECS UpdateService.
  task_role_arn = data.aws_iam_role.worker_lab_role[0].arn

  # Definicion del contenedor autoscaler.
  container_definitions = jsonencode([
    {
      # Nombre del contenedor en ECS.
      name = "ticket-scaler"
      # Imagen ECR construida desde app/scaler.
      image = local.scaler_image
      # Si el scaler falla, ECS reemplaza la task del service.
      essential = true

      # Variables leidas por app/scaler/src/scaler.py.
      environment = [
        # Region para cliente boto3 ECS.
        { name = "AWS_REGION", value = var.aws_region },
        # Management API privada de RabbitMQ: fuente de backlog y rates.
        { name = "RABBITMQ_MANAGEMENT_URL", value = "http://${aws_instance.rabbitmq[0].private_ip}:${local.rabbitmq_ui_port}" },
        # Credenciales RabbitMQ.
        { name = "RABBITMQ_USER", value = local.rabbitmq_user },
        { name = "RABBITMQ_PASSWORD", value = random_password.rabbitmq[0].result },
        # Cola que se observa para tomar decisiones.
        { name = "RABBITMQ_QUEUE", value = local.rabbitmq_queue },
        # Cluster ECS que contiene el servicio worker.
        { name = "ECS_CLUSTER", value = aws_ecs_cluster.worker[0].name },
        # Servicio ECS cuyo desired_count se modifica.
        { name = "ECS_SERVICE", value = aws_ecs_service.worker[0].name },
        # Limite inferior del numero de workers.
        { name = "MIN_WORKERS", value = tostring(var.min_workers) },
        # Limite superior del numero de workers.
        { name = "MAX_WORKERS", value = tostring(var.max_workers) },
        # C: capacidad segura estimada experimentalmente por worker.
        { name = "SAFE_CAPACITY_PER_WORKER", value = tostring(var.scaler_safe_capacity_per_worker) },
        # Tr: objetivo de respuesta/drenaje para formula por backlog.
        { name = "TARGET_RESPONSE_TIME_SECONDS", value = tostring(var.scaler_target_response_time_seconds) },
        # Intervalo entre decisiones de escalado.
        { name = "POLL_SECONDS", value = tostring(var.scaler_poll_seconds) },
        # Cooldown para bajar workers y evitar flapping.
        { name = "SCALE_DOWN_COOLDOWN_SECONDS", value = tostring(var.scaler_scale_down_cooldown_seconds) },
        # Permite subir rapidamente hasta max_workers si la formula lo pide.
        { name = "SCALE_UP_STEP", value = tostring(var.max_workers) },
        # Baja de uno en uno para ser conservador al reducir capacidad.
        { name = "SCALE_DOWN_STEP", value = "1" },
        # Nivel de logs.
        { name = "LOG_LEVEL", value = "INFO" }
      ]

      # Logs de decisiones: backlog, lambda, target, desired/running.
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.scaler[0].name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])
}

resource "aws_ecs_service" "scaler" {
  # Servicio permanente del autoscaler, normalmente desired_count=0 o 1.
  count = local.scaler_service_on ? 1 : 0

  # Nombre visible en ECS.
  name = "${local.core_name}-scaler"
  # Reutiliza el mismo cluster que workers/loadgen.
  cluster = aws_ecs_cluster.worker[0].id
  # Task definition del autoscaler.
  task_definition = aws_ecs_task_definition.scaler[0].arn
  # 0 lo apaga; 1 lo deja tomando decisiones periodicas.
  desired_count = var.scaler_desired_count
  # Fargate para no administrar EC2.
  launch_type = "FARGATE"

  network_configuration {
    # Subnets default disponibles en AWS Academy.
    subnets = data.aws_subnets.default.ids
    # Mismo SG que workers: salida a RabbitMQ privado y AWS APIs.
    security_groups = [aws_security_group.workers[0].id]
    # Necesaria para salir a ECS API/CloudWatch/ECR sin NAT Gateway.
    assign_public_ip = true
  }

  depends_on = [
    # Logs antes de iniciar el contenedor.
    aws_cloudwatch_log_group.scaler,
    # El scaler modifica el service worker, asi que debe existir antes.
    aws_ecs_service.worker,
    # RabbitMQ debe existir porque el scaler consulta su Management API.
    aws_instance.rabbitmq
  ]
}
