# Muestra el enlace del túnel rápido de Cloudflare (HT-04) leyendo los logs de cloudflared.
# Uso: scripts\tunnel-url.ps1 [qa|prod]     (qa por defecto; en QA el túnel va con el profile "tunel")
param([Parameter(Position = 0)][ValidateSet('qa', 'prod')][string]$Entorno = 'qa')

$C = docker ps -q --filter "label=com.docker.compose.project=tripbus-$Entorno" `
                  --filter "label=com.docker.compose.service=cloudflared" | Select-Object -First 1
if (-not $C) {
    Write-Host "cloudflared no está corriendo en tripbus-$Entorno." -ForegroundColor Red
    if ($Entorno -eq 'qa') { Write-Host 'Levántalo con COMPOSE_PROFILES=tunel en .env.qa y scripts\qa.ps1 up.' }
    exit 1
}
# El enlace aparece en los logs unos segundos después de arrancar: se espera hasta 30 s.
for ($i = 0; $i -lt 30; $i++) {
    $Logs = (docker logs $C 2>&1) | Out-String
    $M = [regex]::Matches($Logs, 'https://[a-z0-9-]+\.trycloudflare\.com')
    if ($M.Count -gt 0) { Write-Output $M[$M.Count - 1].Value; exit 0 }
    Start-Sleep -Seconds 1
}
if ($Logs -match 'Registered tunnel connection') {
    Write-Host 'Túnel con nombre (CLOUDFLARE_TUNNEL_TOKEN): el enlace es el hostname que configuraste en Cloudflare.'
} else {
    Write-Host "No se encontró el enlace en los logs de cloudflared: revisa  docker logs $C" -ForegroundColor Red
}
exit 1
