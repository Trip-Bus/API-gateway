# Copia de seguridad inmediata de las 6 bases (HT-05) en .\backups\AAAA-MM-DD\<servicio>.dump.
# Usa el contenedor "backups" (el mismo que hace la copia diaria). Uso: scripts\backup-now.ps1 [qa|prod]
param([Parameter(Position = 0)][ValidateSet('qa', 'prod')][string]$Entorno = 'qa')

$C = docker ps -q --filter "label=com.docker.compose.project=tripbus-$Entorno" `
                  --filter "label=com.docker.compose.service=backups" | Select-Object -First 1
if (-not $C) {
    Write-Host "El contenedor backups no está corriendo en tripbus-$Entorno (scripts\$Entorno.ps1 up)." -ForegroundColor Red
    exit 1
}
docker exec $C sh /backup/backup.sh once
exit $LASTEXITCODE
