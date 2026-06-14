<#
.SYNOPSIS
  Destruye la infraestructura real del Ticket Service en AWS Academy.

.DESCRIPTION
  Explicacion simple:
    Elimina EC2, ECS/Fargate, ECR, SQS, security groups y logs creados por
    Terraform para evitar coste al cerrar AWS Academy.

  Explicacion tecnica:
    Usa los mismos flags enable_* del despliegue para que Terraform conozca todos
    los recursos condicionales que puede haber creado.
#>

[CmdletBinding()]
param(
    [string]$TerraformDir = "infra/terraform",
    [string]$OperatorCidr = "0.0.0.0/32",
    [int]$MaxWorkers = 8
)

$ErrorActionPreference = "Stop"

# Destroy usa enable_*=true para que Terraform conozca todos los recursos
# condicionales posibles. Si algun servicio estaba apagado con desired=0, aun asi
# su definicion ECS/ECR/EC2 puede existir y debe entrar en el destroy.
terraform "-chdir=$TerraformDir" destroy -auto-approve `
    -var enable_core_infra=true `
    -var enable_worker_service=true `
    -var enable_scaler_service=true `
    -var operator_cidr=$OperatorCidr `
    -var worker_desired_count=0 `
    -var scaler_desired_count=0 `
    -var max_workers=$MaxWorkers
exit $LASTEXITCODE
