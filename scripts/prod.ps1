# Entorno PROD con imágenes de GHCR (tag prod), solo publica 18000 (REST y WebSocket /ws).
# Uso: scripts\prod.ps1 pull | up | down | ps | logs [servicio] | config
# Antes de "pull": docker login ghcr.io (las imágenes son privadas, ver README).
param(
    [Parameter(Position = 0)][string]$Comando,
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Resto
)
# Sin ErrorActionPreference=Stop: docker compose escribe su progreso en stderr y PowerShell 5.1 lo
# convertiría en error terminante al redirigir la salida. Se valida con el código de salida.
Set-Location (Split-Path -Parent $PSScriptRoot)

$EnvFile = '.env.prod'
if (-not (Test-Path $EnvFile)) {
    Write-Host "Falta $EnvFile. Créalo con:  cp .env.prod.example .env.prod  y cambia cada CAMBIAR_*" -ForegroundColor Red; exit 1
}
if (Select-String -Path $EnvFile -Pattern 'CAMBIAR' -Quiet) {
    Write-Host "$EnvFile todavía tiene valores CAMBIAR_*: reemplázalos antes de desplegar." -ForegroundColor Red; exit 1
}
$Base = @('compose', '-p', 'tripbus-prod', '--env-file', $EnvFile, '-f', 'docker-compose.yml', '-f', 'docker-compose.prod.yml')

switch ($Comando) {
    'pull'   { & docker @Base pull }
    'up'     { & docker @Base up -d --no-build --remove-orphans; if ($LASTEXITCODE -eq 0) { & docker image prune -f } }
    'down'   { & docker @Base down }          # conserva los datos (volúmenes)
    'ps'     { & docker @Base ps }
    'logs'   { & docker @Base logs -f --tail=200 @Resto }
    'config' { & docker @Base config }
    default  { Write-Host 'Uso: scripts\prod.ps1 pull | up | down | ps | logs [servicio] | config'; exit 1 }
}
exit $LASTEXITCODE
