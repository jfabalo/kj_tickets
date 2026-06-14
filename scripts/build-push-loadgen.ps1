<#
.SYNOPSIS
  Construye y sube la imagen Docker del load generator a ECR.

.DESCRIPTION
  Explicacion simple:
    Si cambiamos `app/loadgen`, este script recompila el contenedor y lo publica
    en el repositorio ECR que usa ECS/Fargate.

  Explicacion tecnica:
    Lee `loadgen_repository_url`, `account_id` y `region` desde Terraform. Hace
    login en ECR con AWS CLI, etiqueta la imagen local como `<repo>:<tag>` y la
    sube. La task definition usa normalmente el tag `latest`.
#>

[CmdletBinding()]
param(
    [string]$TerraformDir = "infra/terraform",
    [string]$Tag = "latest"
)

$ErrorActionPreference = "Stop"

# Terraform expone el repo ECR real para evitar copiar URLs manualmente.
$repo = terraform "-chdir=$TerraformDir" output -raw loadgen_repository_url 2>$null
if ($LASTEXITCODE -ne 0 -or -not $repo) {
    throw "loadgen_repository_url is not available. Apply Terraform core infra first."
}

$account = terraform "-chdir=$TerraformDir" output -raw account_id
$region = terraform "-chdir=$TerraformDir" output -raw region
$registry = "$account.dkr.ecr.$region.amazonaws.com"

# Build local de la task one-shot que genera carga desde AWS/Fargate.
Write-Host "Building loadgen image..." -ForegroundColor Cyan
docker build -t ticket-service-loadgen:local app/loadgen
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host "Logging into ECR $registry..." -ForegroundColor Cyan
# Login temporal contra ECR usando las credenciales AWS Academy actuales.
$pass = aws ecr get-login-password --region $region
docker login --username AWS --password $pass $registry
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$image = "$repo`:$Tag"
Write-Host "Pushing $image..." -ForegroundColor Cyan
# ECS descargara esta imagen cuando run-loadgen-aws.ps1 lance la task.
docker tag ticket-service-loadgen:local $image
docker push $image
exit $LASTEXITCODE
