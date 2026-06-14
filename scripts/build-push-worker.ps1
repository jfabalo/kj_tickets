<#
.SYNOPSIS
  Construye y sube la imagen Docker del worker real a ECR.

.DESCRIPTION
  Explicacion simple:
    Si cambiamos `app/worker`, este script recompila el contenedor y lo publica
    en el repositorio ECR que usa el ECS service de workers.

  Explicacion tecnica:
    Lee `worker_repository_url`, `account_id` y `region` desde Terraform. Hace
    login en ECR con AWS CLI, etiqueta la imagen local como `<repo>:<tag>` y la
    sube. La task definition usa normalmente el tag `latest`.
#>

[CmdletBinding()]
param(
    [string]$TerraformDir = "infra/terraform",
    [string]$Tag = "latest"
)

$ErrorActionPreference = "Stop"

# El repositorio ECR lo crea Terraform. No hardcodeamos account/region porque las
# credenciales temporales de AWS Academy pueden cambiar entre sesiones.
$repo = terraform "-chdir=$TerraformDir" output -raw worker_repository_url 2>$null
if ($LASTEXITCODE -ne 0 -or -not $repo) {
    throw "worker_repository_url is not available. Apply Terraform core infra first."
}

$account = terraform "-chdir=$TerraformDir" output -raw account_id
$region = terraform "-chdir=$TerraformDir" output -raw region
$registry = "$account.dkr.ecr.$region.amazonaws.com"

# Build local: Docker Desktop construye la imagen desde app/worker/Dockerfile.
Write-Host "Building worker image..." -ForegroundColor Cyan
docker build -t ticket-service-worker:local app/worker
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "Logging into ECR $registry..." -ForegroundColor Cyan
# ECR usa password temporal obtenido por AWS CLI; no se guarda en ficheros.
$pass = aws ecr get-login-password --region $region
docker login --username AWS --password $pass $registry
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$image = "$repo`:$Tag"
Write-Host "Pushing $image..." -ForegroundColor Cyan
# Etiquetamos la imagen local con la URL completa que ECS usara en task definition.
docker tag ticket-service-worker:local $image
docker push $image
exit $LASTEXITCODE
