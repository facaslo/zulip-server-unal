# Apaga el retraso de red del escenario de latencia (Toxiproxy).
# Abre su propio port-forward, quita el retraso, confirma el estado y cierra el port-forward.

$namespace = "zulip"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$toggle = Join-Path $scriptDir "toxiproxy_toggle.py"

Write-Host "Abriendo tunel hacia Toxiproxy..."
$pf = Start-Process -FilePath "kubectl" `
    -ArgumentList "port-forward", "svc/toxiproxy", "-n", $namespace, "8474:8474" `
    -WindowStyle Hidden -PassThru

# Prueba una peticion HTTP real contra Toxiproxy (no solo si el puerto
# acepta conexiones TCP -- kubectl abre el socket local antes de que el
# tunel relaye trafico de verdad, asi que probar solo el TCP da falsos
# positivos). Reintenta hasta 20s.
$ready = $false
for ($i = 0; $i -lt 28; $i++) {
    Start-Sleep -Milliseconds 700
    $code = curl.exe -s -o NUL -w "%{http_code}" --max-time 2 "http://127.0.0.1:8474/version" 2>$null
    if ($code -eq "200") { $ready = $true; break }
}

if (-not $ready) {
    Write-Host ""
    Write-Host "ERROR: el tunel hacia Toxiproxy no respondio en 20 segundos."
    Write-Host "Verifica: kubectl get pods -n $namespace -l app=toxiproxy"
    Stop-Process -Id $pf.Id -Force -ErrorAction SilentlyContinue
    exit 1
}

$success = $false
try {
    python $toggle off
    if ($LASTEXITCODE -eq 0) {
        python $toggle status
        $success = $true
    } else {
        Write-Host "ERROR: el comando de desactivacion termino con un error (ver arriba)."
    }
} catch {
    Write-Host "ERROR al desactivar el retraso: $($_.Exception.Message)"
} finally {
    Write-Host "Cerrando el tunel..."
    Stop-Process -Id $pf.Id -Force -ErrorAction SilentlyContinue
}

Write-Host ""
if ($success) {
    Write-Host "Listo. El retraso esta desactivado; la conexion a RabbitMQ vuelve a la normalidad."
} else {
    Write-Host "No se pudo confirmar que el retraso quedara desactivado. Revisa el error de arriba antes de continuar."
}
