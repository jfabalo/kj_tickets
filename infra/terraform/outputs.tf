# outputs.tf
#
# Objetivo del archivo:
#   Exponer datos creados por Terraform para que los scripts no tengan que usar
#   IPs, ARNs ni nombres hardcodeados.
#
# Seguridad:
#   Las passwords se marcan como sensitive. Terraform las puede usar y los scripts
#   pueden leerlas con `terraform output -raw`, pero no se imprimen por defecto.

output "account_id" {
  # Cuenta AWS Academy activa. Sirve para verificar que se despliega donde toca.
  description = "AWS account currently used by Terraform."
  value       = data.aws_caller_identity.current.account_id
}

output "region" {
  # Region efectiva del provider AWS.
  description = "AWS region currently used by Terraform."
  value       = data.aws_region.current.region
}

output "default_vpc_id" {
  # VPC default reutilizada por EC2 y Fargate.
  description = "Default VPC selected for AWS Academy deployment."
  value       = data.aws_vpc.default.id
}

output "default_subnet_ids" {
  # Subnets donde ECS puede arrancar tasks Fargate.
  description = "Default subnet IDs available in the default VPC."
  value       = data.aws_subnets.default.ids
}

output "rabbitmq_public_ip" {
  # IP publica para operador: UI/API, debug o limpieza desde local.
  description = "RabbitMQ EC2 public IP."
  value       = var.enable_core_infra ? aws_instance.rabbitmq[0].public_ip : null
}

output "rabbitmq_private_ip" {
  # IP privada para trafico interno desde Fargate hacia RabbitMQ.
  description = "RabbitMQ EC2 private IP for ECS workers."
  value       = var.enable_core_infra ? aws_instance.rabbitmq[0].private_ip : null
}

output "rabbitmq_amqp_url" {
  # Endpoint AMQP interno sin credenciales. Workers/loadgen usan host+port.
  description = "RabbitMQ AMQP endpoint without credentials."
  value       = var.enable_core_infra ? "amqp://${aws_instance.rabbitmq[0].private_ip}:${local.rabbitmq_port}" : null
}

output "rabbitmq_management_url" {
  # URL publica de RabbitMQ Management. La usan scripts locales y humanos.
  description = "RabbitMQ management UI URL."
  value       = var.enable_core_infra ? "http://${aws_instance.rabbitmq[0].public_ip}:${local.rabbitmq_ui_port}" : null
}

output "rabbitmq_username" {
  # Usuario creado por el contenedor RabbitMQ en user_data.
  description = "RabbitMQ username."
  value       = var.enable_core_infra ? local.rabbitmq_user : null
}

output "rabbitmq_password" {
  # Password aleatoria generada por Terraform para RabbitMQ.
  description = "RabbitMQ password."
  value       = var.enable_core_infra ? random_password.rabbitmq[0].result : null
  sensitive   = true
}

output "postgres_public_ip" {
  # IP publica para scripts locales: limpieza y exportacion de CSV.
  description = "PostgreSQL EC2 public IP."
  value       = var.enable_core_infra ? aws_instance.postgres[0].public_ip : null
}

output "postgres_private_ip" {
  # IP privada para workers/loadgen dentro de la VPC.
  description = "PostgreSQL EC2 private IP for ECS workers."
  value       = var.enable_core_infra ? aws_instance.postgres[0].private_ip : null
}

output "postgres_connection_host" {
  # Alias semantico del host privado usado por contenedores ECS.
  description = "PostgreSQL host for ECS workers."
  value       = var.enable_core_infra ? aws_instance.postgres[0].private_ip : null
}

output "postgres_database" {
  # Nombre de la base de datos creada al arrancar el contenedor PostgreSQL.
  description = "PostgreSQL database name."
  value       = var.enable_core_infra ? local.postgres_db : null
}

output "postgres_username" {
  # Usuario de aplicacion usado por worker, loadgen y scripts locales.
  description = "PostgreSQL username."
  value       = var.enable_core_infra ? local.postgres_user : null
}

output "postgres_password" {
  # Password aleatoria generada por Terraform para PostgreSQL.
  description = "PostgreSQL password."
  value       = var.enable_core_infra ? random_password.postgres[0].result : null
  sensitive   = true
}

output "ticket_failures_dlq_url" {
  # URL de SQS DLQ donde el worker manda fallos definitivos.
  description = "SQS DLQ URL for permanent ticket processing failures."
  value       = var.enable_core_infra ? aws_sqs_queue.ticket_failures_dlq[0].url : null
}

output "worker_repository_url" {
  # URL ECR donde se sube la imagen Docker del worker.
  description = "ECR repository URL for the real ticket worker image."
  value       = var.enable_core_infra ? aws_ecr_repository.worker[0].repository_url : null
}

output "loadgen_repository_url" {
  # URL ECR donde se sube la imagen Docker del load generator.
  description = "ECR repository URL for the load generator image."
  value       = var.enable_core_infra ? aws_ecr_repository.loadgen[0].repository_url : null
}

output "scaler_repository_url" {
  # URL ECR donde se sube la imagen Docker del autoscaler.
  description = "ECR repository URL for the autoscaler image."
  value       = var.enable_core_infra ? aws_ecr_repository.scaler[0].repository_url : null
}

output "workers_security_group_id" {
  # Security group que se adjunta a tasks Fargate.
  description = "Security group ID to attach to ECS worker tasks."
  value       = var.enable_core_infra ? aws_security_group.workers[0].id : null
}

output "worker_cluster_name" {
  # Nombre del cluster ECS compartido por worker, loadgen y scaler.
  description = "ECS cluster name for the real worker service."
  value       = local.worker_service_on ? aws_ecs_cluster.worker[0].name : null
}

output "worker_service_name" {
  # Nombre del ECS service que mantiene los workers vivos.
  description = "ECS service name for the real worker service."
  value       = local.worker_service_on ? aws_ecs_service.worker[0].name : null
}

output "worker_log_group" {
  # CloudWatch Logs del worker. Lo usa observe.ps1.
  description = "CloudWatch log group for the real worker service."
  value       = local.worker_service_on ? aws_cloudwatch_log_group.worker[0].name : null
}

output "loadgen_task_definition_arn" {
  # ARN de task definition para aws ecs run-task del loadgen.
  description = "ECS task definition ARN for one-shot load generator runs."
  value       = local.loadgen_task_on ? aws_ecs_task_definition.loadgen[0].arn : null
}

output "loadgen_log_group" {
  # CloudWatch Logs del loadgen, util para revisar publicaciones y errores.
  description = "CloudWatch log group for one-shot load generator runs."
  value       = local.loadgen_task_on ? aws_cloudwatch_log_group.loadgen[0].name : null
}

output "scaler_service_name" {
  # Nombre del ECS service del autoscaler. Lo usan scripts/set-scaler-fast.ps1.
  description = "ECS service name for the autoscaler."
  value       = local.scaler_service_on ? aws_ecs_service.scaler[0].name : null
}

output "scaler_log_group" {
  # CloudWatch Logs del autoscaler: decisiones, backlog y desired_count.
  description = "CloudWatch log group for autoscaler decisions."
  value       = local.scaler_service_on ? aws_cloudwatch_log_group.scaler[0].name : null
}
