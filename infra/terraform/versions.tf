# versions.tf
#
# Objetivo del archivo:
#   Fijar las versiones minimas de Terraform y de los providers usados por la
#   practica. Esto evita que otra maquina ejecute el proyecto con versiones muy
#   antiguas o incompatibles.
#
# Relacion con la arquitectura:
#   Este archivo no crea recursos AWS. Solo declara que Terraform puede usar el
#   provider AWS para EC2/ECS/ECR/SQS/CloudWatch y el provider random para generar
#   credenciales temporales de RabbitMQ y PostgreSQL.

terraform {
  # Version minima del binario Terraform. La configuracion usa sintaxis moderna
  # de Terraform 1.x, por eso no se permite ejecutar con versiones anteriores.
  required_version = ">= 1.6.0"

  # Lista de providers externos que Terraform debe descargar durante init.
  required_providers {
    # Provider AWS: gestiona todos los servicios cloud usados en la practica.
    aws = {
      # Namespace oficial del provider AWS en el registry de HashiCorp.
      source = "hashicorp/aws"
      # Permitimos cualquier version 6.x compatible. El lock file fija la version
      # concreta resuelta localmente para reproducibilidad.
      version = "~> 6.0"
    }

    # Provider random: genera passwords sin hardcodearlas en el repositorio.
    random = {
      # Namespace oficial del provider random.
      source = "hashicorp/random"
      # Version 3.x compatible con random_password.
      version = "~> 3.7"
    }
  }
}
