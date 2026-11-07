# Prende el retraso de red del escenario de latencia (Toxiproxy).
# Abre su propio port-forward, aplica el retraso, confirma el estado y cierra el port-forward.

$ErrorActionPreference = "Stop"
$namespace = "zulip"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$toggle = Join-Path $scriptDir "toxiproxy_toggle.py"

Write-Host "Abriendo tunel hacia Toxiproxy..."
$pf = Start-Process -FilePath "kubectl" `
    -ArgumentList "port-forward", "svc/toxiproxy", "-n", $namespace, "8474:8474" `
    -WindowStyle Hidden -PassThru
Start-Sleep -Seconds 3

try {
    python $toggle on --latency-ms 3000 --jitter-ms 500
    python $toggle status
} finally {
    Write-Host "Cerrando el tunel..."
    Stop-Process -Id $pf.Id -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "Listo. El retraso esta activo (3000ms +/- 500ms) sobre la conexion a RabbitMQ."
