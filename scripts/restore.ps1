# Restaura la copia de UNA base (HT-05). REEMPLAZA los datos actuales de esa base.
# Uso: scripts\restore.ps1 <servicio> <archivo.dump> [qa|prod]
#   servicio: identity | catalog | seat-inventory | booking | fleet | offers
#   ej.:      scripts\restore.ps1 catalog backups\2026-11-09\catalog.dump
# Detén antes el servicio dueño de la base y arráncalo después.
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('identity', 'catalog', 'seat-inventory', 'booking', 'fleet', 'offers')][string]$Servicio,
    [Parameter(Mandatory = $true, Position = 1)][string]$Archivo,
    [Parameter(Position = 2)][ValidateSet('qa', 'prod')][string]$Entorno = 'qa'
)
$Bases = @{ 'identity' = 'identity-db'; 'catalog' = 'catalog-db'; 'seat-inventory' = 'seat-inventory-db';
            'booking' = 'booking-db'; 'fleet' = 'fleet-db'; 'offers' = 'offers-db' }
$Db = $Bases[$Servicio]
if (-not (Test-Path $Archivo)) { Write-Host "No existe el archivo $Archivo" -ForegroundColor Red; exit 1 }
$C = docker ps -q --filter "label=com.docker.compose.project=tripbus-$Entorno" `
                  --filter "label=com.docker.compose.service=$Db" | Select-Object -First 1
if (-not $C) { Write-Host "La base $Db no está corriendo en tripbus-$Entorno." -ForegroundColor Red; exit 1 }

Write-Host "Vas a REEMPLAZAR la base de $Servicio ($Db, tripbus-$Entorno) con $Archivo."
$Ok = Read-Host "Escribe el nombre del servicio ($Servicio) para confirmar"
if ($Ok -ne $Servicio) { Write-Host 'Cancelado.'; exit 1 }

# PowerShell no pasa binarios por la tubería: se copia el archivo al contenedor y se restaura desde allí.
docker cp $Archivo "${C}:/tmp/restaurar.dump"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
docker exec $C sh -c 'pg_restore --clean --if-exists --no-owner --exit-on-error -U "$POSTGRES_USER" -d "$POSTGRES_DB" /tmp/restaurar.dump; r=$?; rm -f /tmp/restaurar.dump; exit $r'
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Host "Restaurada la base de $Servicio desde $Archivo. Reinicia el servicio dueño de la base."
