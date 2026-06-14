# variables.tf
#
# Objetivo del archivo:
#   Definir todos los parametros configurables del stack Terraform.
#
# Como leerlo:
#   - Variables generales: region, nombres y acceso del operador.
#   - Variables de imagen: tags Docker usados por ECS.
#   - Variables de coste/escala: workers min/max y desired_count.
#   - Variables de activacion: permiten crear infraestructura por fases.
#
# Relacion con AWS Academy:
#   Los defaults son conservadores para no crear recursos accidentalmente ni
#   gastar presupuesto sin querer. Por eso enable_core_infra empieza en false.

variable "aws_region" {
  # Region AWS donde se desplegara todo el stack.
  description = "AWS Academy region. Keep us-east-1 unless the lab changes."
  # Tipo string porque es un identificador de region como us-east-1.
  type = string
  # Region usada durante la practica.
  default = "us-east-1"
}

variable "project_name" {
  # Prefijo comun para nombres de recursos AWS.
  description = "Name prefix for created resources."
  type        = string
  # Genera nombres como ticket-service-academy-worker.
  default = "ticket-service"
}

variable "environment" {
  # Etiqueta de entorno usada en nombres y tags.
  description = "Deployment environment label."
  type        = string
  # En esta practica el entorno es AWS Academy.
  default = "academy"
}

variable "operator_cidr" {
  # IP publica del operador en formato CIDR. Ejemplo: 1.2.3.4/32.
  # Se usa para abrir acceso de mantenimiento a RabbitMQ UI y PostgreSQL.
  description = "Public CIDR allowed to access RabbitMQ UI and optional debug ports."
  type        = string
  # Valor cerrado por defecto: no abre acceso real hasta que se pase una IP.
  default = "0.0.0.0/32"
}

variable "worker_image_tag" {
  # Tag de la imagen Docker que usara la task definition del worker.
  description = "Docker image tag used by the ECS worker task."
  type        = string
  # latest simplifica la practica; en produccion convendria usar tags inmutables.
  default = "latest"
}

variable "loadgen_image_tag" {
  # Tag de la imagen Docker que usara la task one-shot del generador de carga.
  description = "Docker image tag used by the ECS load generator task."
  type        = string
  default     = "latest"
}

variable "scaler_image_tag" {
  # Tag de la imagen Docker que usara el servicio autoscaler.
  description = "Docker image tag used by the ECS autoscaler service."
  type        = string
  default     = "latest"
}

variable "min_workers" {
  # Limite inferior del autoscaler. Mantener 1 reduce cold start inicial.
  description = "Minimum ECS worker task count."
  type        = number
  default     = 1
}

variable "max_workers" {
  # Limite superior del autoscaler. Controla coste y evita escalar sin limite.
  description = "Maximum ECS worker task count for cost control in AWS Academy."
  type        = number
  default     = 8
}

variable "enable_core_infra" {
  # Flag principal: crea RabbitMQ, PostgreSQL, ECR, SQS DLQ y security groups.
  # Se deja en false por defecto para que terraform apply no cree coste accidental.
  description = "Create the real base infrastructure: RabbitMQ EC2, PostgreSQL EC2, SQS DLQ, ECR, and worker security group."
  type        = bool
  default     = false
}

variable "ec2_instance_type" {
  # Tipo de instancia para RabbitMQ y PostgreSQL. t3.micro es barato para Academy.
  description = "Small EC2 instance type used for RabbitMQ and PostgreSQL in AWS Academy."
  type        = string
  default     = "t3.micro"
}

variable "ec2_root_volume_size" {
  # Tamano del disco raiz de las EC2 en GiB.
  description = "Root EBS volume size in GiB for RabbitMQ and PostgreSQL EC2 instances."
  type        = number
  default     = 8
}

variable "worker_repository_name" {
  # Nombre del repositorio ECR para la imagen app/worker.
  description = "ECR repository name for the real ticket worker image."
  type        = string
  default     = "ticket-service-worker"
}

variable "loadgen_repository_name" {
  # Nombre del repositorio ECR para la imagen app/loadgen.
  description = "ECR repository name for the load generator image."
  type        = string
  default     = "ticket-service-loadgen"
}

variable "scaler_repository_name" {
  # Nombre del repositorio ECR para la imagen app/scaler.
  description = "ECR repository name for the autoscaler image."
  type        = string
  default     = "ticket-service-scaler"
}

variable "enable_worker_service" {
  # Crea el cluster ECS, task definition y service de workers.
  # Requiere core infra porque necesita ECR, RabbitMQ, PostgreSQL y SQS DLQ.
  description = "Create the real ECS/Fargate worker service. Requires enable_core_infra=true and a pushed worker image."
  type        = bool
  default     = false
}

variable "enable_scaler_service" {
  # Crea el servicio Fargate del autoscaler.
  # Requiere worker service porque el scaler modifica su desired_count.
  description = "Create the ECS/Fargate autoscaler service. Requires enable_core_infra=true, enable_worker_service=true, and pushed scaler image before scaler_desired_count > 0."
  type        = bool
  default     = false
}

variable "worker_desired_count" {
  # Numero de tasks worker que ECS intentara mantener cuando el service exista.
  # Durante pruebas rapidas se cambia con scripts/set-workers-fast.ps1.
  description = "Desired number of ECS worker tasks for the real service."
  type        = number
  default     = 1
}

variable "worker_cpu" {
  # CPU Fargate en unidades ECS. 256 equivale a 0.25 vCPU.
  description = "Fargate CPU units for the worker task."
  type        = string
  default     = "256"
}

variable "worker_memory" {
  # Memoria Fargate en MiB. 512 MiB es el minimo practico para esta task Python.
  description = "Fargate memory MiB for the worker task."
  type        = string
  default     = "512"
}

variable "scaler_desired_count" {
  # Numero de tasks del autoscaler. 0 lo deja apagado para ahorrar coste.
  description = "Desired number of autoscaler tasks. Keep 0 when not actively testing dynamic scaling."
  type        = number
  default     = 0
}

variable "scaler_safe_capacity_per_worker" {
  # C de la formula del enunciado: capacidad segura por worker en msg/s.
  # Medimos ~7.9 req/s, pero usamos 6.5 para no ir al limite.
  description = "Experimentally estimated safe worker capacity in messages/second. Measured C ~= 7.9 req/s; default keeps safety margin."
  type        = number
  default     = 6.5
}

variable "scaler_target_response_time_seconds" {
  # Tr de la formula por backlog: objetivo de drenaje de cola.
  description = "Backlog drain target Tr used by the autoscaler formula."
  type        = number
  default     = 10
}

variable "scaler_poll_seconds" {
  # Frecuencia con la que el autoscaler consulta RabbitMQ Management API.
  description = "Autoscaler RabbitMQ polling interval in seconds."
  type        = number
  default     = 5
}

variable "scaler_scale_down_cooldown_seconds" {
  # Tiempo minimo antes de reducir workers. Evita subir/bajar constantemente.
  description = "Cooldown before reducing workers to avoid flapping."
  type        = number
  default     = 30
}
