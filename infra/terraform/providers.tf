# providers.tf
#
# Objetivo del archivo:
#   Configurar el provider AWS que usara Terraform para hablar con AWS Academy.
#
# Importante:
#   Las credenciales NO se guardan aqui. Terraform lee AWS_ACCESS_KEY_ID,
#   AWS_SECRET_ACCESS_KEY y AWS_SESSION_TOKEN desde la sesion de PowerShell,
#   normalmente cargadas con scripts/set-academy-env.ps1.

provider "aws" {
  # Region donde se crean todos los recursos. En AWS Academy usamos us-east-1
  # salvo que el laboratorio indique otra region.
  region = var.aws_region

  # Etiquetas aplicadas automaticamente a todos los recursos que soporten tags.
  # Sirven para identificar el coste y borrar recursos de esta practica.
  default_tags {
    tags = {
      # Nombre logico del proyecto, usado para filtrar en consola AWS.
      Project = var.project_name
      # Entorno de despliegue. Aqui lo usamos como "academy".
      Environment = var.environment
      # Marca explicita de que Terraform es el propietario del recurso.
      ManagedBy = "terraform"
      # Ayuda a distinguir recursos del laboratorio frente a recursos personales.
      Lab = "aws-academy"
    }
  }
}
