# Entorno QA (tu PC): compila los 8 servicios desde el código y publica todos los puertos.
# Uso: scripts\qa.ps1 up | down | ps | logs [servicio] | config
param(
    [Parameter(Position = 0)][string]$Comando,
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Resto
)
# Sin ErrorActionPreference=Stop: docker compose escribe su progreso en stderr y PowerShell 5.1 lo
# convertiría en error terminante al redirigir la salida. Se valida con el código de salida.
Set-Location (Split-Path -Parent $PSScriptRoot)

$EnvFile = '.env.qa'
if (-not (Test-Path $EnvFile)) {
    Write-Host "Falta $EnvFile. Créalo con:  cp .env.qa.example .env.qa" -ForegroundColor Red; exit 1
}
$Base = @('compose', '-p', 'tripbus-qa', '--env-file', $EnvFile, '-f', 'docker-compose.yml', '-f', 'docker-compose.qa.yml')

switch ($Comando) {
    'up'     { & docker @Base up -d --build }
    'down'   { & docker @Base down }          # conserva los datos (volúmenes)
    'ps'     { & docker @Base ps }
    'logs'   { & docker @Base logs -f --tail=200 @Resto }
    'config' { & docker @Base config }
    default  { Write-Host 'Uso: scripts\qa.ps1 up | down | ps | logs [servicio] | config'; exit 1 }
}
exit $LASTEXITCODE
