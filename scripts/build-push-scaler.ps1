<#
.SYNOPSIS
  Construye y sube la imagen Docker del autoscaler a ECR.

.DESCRIPTION
  Explicacion simple:
    Si cambiamos `app/scaler`, este script recompila el contenedor y lo publica
    en el repositorio ECR que usa el ECS service del scaler.

  Explicacion tecnica:
    Lee `scaler_repository_url`, `account_id` y `region` desde Terraform. Hace
    login en ECR, etiqueta la imagen local y la sube. La task definition usa
    normalmente el tag `latest`.
#>

[CmdletBinding()]
param(
    [string]$TerraformDir = "infra/terraform",
    [string]$Tag = "latest"
)

$ErrorActionPreference = "Stop"

# El repo del scaler existe tras aplicar core infra con Terraform.
$repo = terraform "-chdir=$TerraformDir" output -raw scaler_repository_url 2>$null
if ($LASTEXITCODE -ne 0 -or -not $repo) {
    throw "scaler_repository_url is not available. Apply Terraform core infra after adding scaler first."
}

$account = terraform "-chdir=$TerraformDir" output -raw account_id
$region = terraform "-chdir=$TerraformDir" output -raw region
$registry = "$account.dkr.ecr.$region.amazonaws.com"

# Build local del contenedor que implementa las formulas de autoscaling.
Write-Host "Building scaler image..." -ForegroundColor Cyan
docker build -t ticket-service-scaler:local app/scaler
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "Logging into ECR $registry..." -ForegroundColor Cyan
# Autenticacion corta contra ECR; no persistimos passwords en el proyecto.
$pass = aws ecr get-login-password --region $region
docker login --username AWS --password $pass $registry
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$image = "$repo`:$Tag"
Write-Host "Pushing $image..." -ForegroundColor Cyan
# El ECS service del scaler usa este tag.
docker tag ticket-service-scaler:local $image
docker push $image
exit $LASTEXITCODE

