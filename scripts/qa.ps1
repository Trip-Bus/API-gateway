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
# Con el profile "observabilidad" (COMPOSE_PROFILES en el entorno o en $EnvFile) se agrega el override que
# activa trazas OTLP y logs JSON en los servicios Java (HT-10).
$Perfiles = $env:COMPOSE_PROFILES
if (-not $Perfiles) {
    $Linea = Select-String -Path $EnvFile -Pattern '^COMPOSE_PROFILES=' | Select-Object -Last 1
    if ($Linea) { $Perfiles = $Linea.Line.Substring('COMPOSE_PROFILES='.Length) }
}
if ($Perfiles -and (($Perfiles -split ',') | ForEach-Object { $_.Trim() }) -match '^(observabilidad|observability)$') {
    $Base += @('-f', 'docker-compose.observabilidad.yml')
}

switch ($Comando) {
    'up'     { & docker @Base up -d --build }
    'down'   { & docker @Base down }          # conserva los datos (volúmenes)
    'ps'     { & docker @Base ps }
    'logs'   { & docker @Base logs -f --tail=200 @Resto }
    'config' { & docker @Base config }
    default  { Write-Host 'Uso: scripts\qa.ps1 up | down | ps | logs [servicio] | config'; exit 1 }
}
exit $LASTEXITCODE
