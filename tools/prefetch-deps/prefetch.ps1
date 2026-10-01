# Descarga a tu ~/.m2 todas las dependencias Maven de los microservicios de TripBus.
# Uso (PowerShell, desde esta carpeta):   powershell -ExecutionPolicy Bypass -File .\prefetch.ps1
$ErrorActionPreference = "Stop"

# 1) Encontrar un JDK 21 (JAVA_HOME, o el que IntelliJ descarga en ~/.jdks)
if (-not $env:JAVA_HOME -or -not (Test-Path "$env:JAVA_HOME\bin\java.exe")) {
    $jdk = Get-ChildItem "$env:USERPROFILE\.jdks" -Directory -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -match '21' } | Select-Object -First 1
    if ($jdk) { $env:JAVA_HOME = $jdk.FullName }
}
Write-Host "JAVA_HOME = $env:JAVA_HOME"

# 2) Encontrar Maven: el del PATH, o el que viene incluido en IntelliJ IDEA
$mvn = (Get-Command mvn -ErrorAction SilentlyContinue).Source
if (-not $mvn) {
    $candidates = @(
        "$env:ProgramFiles\JetBrains\*\plugins\maven\lib\maven3\bin\mvn.cmd",
        "$env:LOCALAPPDATA\Programs\*IntelliJ*\plugins\maven\lib\maven3\bin\mvn.cmd",
        "$env:LOCALAPPDATA\JetBrains\Toolbox\apps\*\*\*\plugins\maven\lib\maven3\bin\mvn.cmd"
    )
    foreach ($c in $candidates) {
        $found = Get-ChildItem $c -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($found) { $mvn = $found.FullName; break }
    }
}
if (-not $mvn) { throw "No encontré Maven. Instálalo o abre este pom.xml en IntelliJ y ejecuta 'verify'." }
Write-Host "Maven = $mvn"

& $mvn -B verify
if ($LASTEXITCODE -ne 0) { throw "Maven terminó con error" }
Write-Host "Listo: dependencias descargadas en $env:USERPROFILE\.m2\repository"
