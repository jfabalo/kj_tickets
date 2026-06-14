<#
.SYNOPSIS
  Loads temporary AWS Academy / Learner Lab credentials into the current PowerShell session.

.DESCRIPTION
  Explicacion simple:
  Carga las credenciales temporales de AWS Academy para que AWS CLI y Terraform
  puedan operar en esta terminal. Hay que ejecutarlo con dot-sourcing para que
  las variables queden en la sesion actual.

  Explicacion tecnica:
  Acepta formatos tipo export, $Env:... o clave=valor. Solo escribe variables
  de entorno de proceso; no persiste secretos en disco. Opcionalmente valida con
  aws sts get-caller-identity.

  AWS Academy credentials are temporary. Run this script with dot-sourcing so the environment
  variables remain available in the current shell:

    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
    . .\scripts\set-academy-env.ps1 -CredentialsFile .\aws-academy-credentials.txt

  Or paste the credentials block directly:

    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
    . .\scripts\set-academy-env.ps1 -Paste

  Accepted input formats:
    export AWS_ACCESS_KEY_ID=...
    export AWS_SECRET_ACCESS_KEY=...
    export AWS_SESSION_TOKEN=...

    $Env:AWS_ACCESS_KEY_ID="..."
    $Env:AWS_SECRET_ACCESS_KEY="..."
    $Env:AWS_SESSION_TOKEN="..."

    AWS_ACCESS_KEY_ID=...
    AWS_SECRET_ACCESS_KEY=...
    AWS_SESSION_TOKEN=...

  The script only sets environment variables for the current PowerShell process.
  It does not write credentials to disk unless you explicitly save them in your own file.
#>

[CmdletBinding(DefaultParameterSetName = 'Paste')]
param(
    [Parameter(ParameterSetName = 'File')]
    [string]$CredentialsFile,

    [Parameter(ParameterSetName = 'Direct')]
    [string]$AccessKeyId,

    [Parameter(ParameterSetName = 'Direct')]
    [string]$SecretAccessKey,

    [Parameter(ParameterSetName = 'Direct')]
    [string]$SessionToken,

    [string]$Region = 'us-east-1',

    [Parameter(ParameterSetName = 'Paste')]
    [switch]$Paste,

    [switch]$SkipValidation
)

function Set-AwsEnvValue {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value
    )

    # Scope Process: la credencial vive solo en esta terminal, no en Windows ni perfil AWS.
    [Environment]::SetEnvironmentVariable($Name, $Value, 'Process')
}

function Get-CredentialMapFromText {
    param([Parameter(Mandatory = $true)][string]$Text)

    $map = @{}
    $wanted = @(
        'AWS_ACCESS_KEY_ID',
        'AWS_SECRET_ACCESS_KEY',
        'AWS_SESSION_TOKEN',
        'AWS_DEFAULT_REGION',
        'AWS_REGION'
    )

    foreach ($line in ($Text -split "`r?`n")) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#')) {
            continue
        }

        foreach ($name in $wanted) {
            # AWS Academy permite copiar credenciales en varios formatos. Aceptar
            # export, $Env: y KEY=VALUE evita editar a mano el bloque.
            $patterns = @(
                "^export\s+$name\s*=\s*(.+)$",
                "^\`$Env:$name\s*=\s*(.+)$",
                "^$name\s*=\s*(.+)$"
            )

            foreach ($pattern in $patterns) {
                if ($trimmed -match $pattern) {
                    $value = $Matches[1].Trim()
                    $value = $value.Trim('''').Trim('"')
                    $map[$name] = $value
                }
            }
        }
    }

    return $map
}

function Read-PastedCredentials {
    Write-Host 'Paste the AWS Academy credentials block. Finish with an empty line.' -ForegroundColor Cyan
    $lines = New-Object System.Collections.Generic.List[string]

    while ($true) {
        $line = Read-Host
        if ([string]::IsNullOrWhiteSpace($line)) {
            break
        }
        $lines.Add($line)
    }

    return ($lines -join "`n")
}

if ($PSCmdlet.ParameterSetName -eq 'File') {
    # Camino habitual: archivo local ignorado por Git.
    if (-not (Test-Path -LiteralPath $CredentialsFile)) {
        throw "Credentials file not found: $CredentialsFile"
    }
    $text = Get-Content -Raw -LiteralPath $CredentialsFile
    $map = Get-CredentialMapFromText -Text $text
}
elseif ($PSCmdlet.ParameterSetName -eq 'Direct') {
    # Camino util para automatizacion sin crear archivo temporal.
    $map = @{
        AWS_ACCESS_KEY_ID = $AccessKeyId
        AWS_SECRET_ACCESS_KEY = $SecretAccessKey
        AWS_SESSION_TOKEN = $SessionToken
    }
}
else {
    # Camino interactivo: pegar el bloque completo del Learner Lab.
    $text = Read-PastedCredentials
    $map = Get-CredentialMapFromText -Text $text
}

$required = @('AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'AWS_SESSION_TOKEN')
$missing = @($required | Where-Object { -not $map.ContainsKey($_) -or [string]::IsNullOrWhiteSpace($map[$_]) })

if ($missing.Count -gt 0) {
    throw "Missing required credential values: $($missing -join ', ')"
}

Set-AwsEnvValue -Name 'AWS_ACCESS_KEY_ID' -Value $map['AWS_ACCESS_KEY_ID']
Set-AwsEnvValue -Name 'AWS_SECRET_ACCESS_KEY' -Value $map['AWS_SECRET_ACCESS_KEY']
Set-AwsEnvValue -Name 'AWS_SESSION_TOKEN' -Value $map['AWS_SESSION_TOKEN']
Set-AwsEnvValue -Name 'AWS_DEFAULT_REGION' -Value $Region
Set-AwsEnvValue -Name 'AWS_REGION' -Value $Region

if ($map.ContainsKey('AWS_DEFAULT_REGION') -and $map['AWS_DEFAULT_REGION']) {
    # Si el bloque pegado trae region, respetamos ese valor sobre el default.
    Set-AwsEnvValue -Name 'AWS_DEFAULT_REGION' -Value $map['AWS_DEFAULT_REGION']
}

if ($map.ContainsKey('AWS_REGION') -and $map['AWS_REGION']) {
    Set-AwsEnvValue -Name 'AWS_REGION' -Value $map['AWS_REGION']
}

Write-Host "AWS Academy credentials loaded for this PowerShell session." -ForegroundColor Green
Write-Host "Region: $env:AWS_REGION" -ForegroundColor Green

if (-not $SkipValidation) {
    # STS detecta credenciales caducadas o mal pegadas antes de lanzar Terraform.
    $aws = Get-Command aws -ErrorAction SilentlyContinue
    if (-not $aws) {
        Write-Warning 'AWS CLI not found in PATH. Credentials were loaded, but validation was skipped.'
        return
    }

    Write-Host 'Validating credentials with aws sts get-caller-identity...' -ForegroundColor Cyan
    aws sts get-caller-identity

    if ($LASTEXITCODE -ne 0) {
        throw 'AWS credential validation failed.'
    }
}

