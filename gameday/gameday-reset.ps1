# Deja el entorno listo para una corrida del GameDay.
#
# Uso: ./gameday-reset.ps1
#
# Quita los toxics de Toxiproxy, asegura una réplica de RabbitMQ, espera
# a que Zulip responda e imprime enlaces a los dashboards desde este
# momento. No borra métricas ni logs: los paneles de 30 días siguen
# incluyendo las corridas anteriores.
#
# Ojo: si hay una falla inyectada a propósito, este script la revierte.

$ErrorActionPreference = 'Stop'

$Project = if ($env:GCP_PROJECT) { $env:GCP_PROJECT } else { 'proyecto-zulip-unal' }
$Cluster = if ($env:GKE_CLUSTER) { $env:GKE_CLUSTER } else { 'zulip' }
$Location = if ($env:GKE_LOCATION) { $env:GKE_LOCATION } else { 'us-east1-b' }
$Namespace = if ($env:ZULIP_NAMESPACE) { $env:ZULIP_NAMESPACE } else { 'zulip' }
$ZulipUrl = if ($env:ZULIP_URL) { $env:ZULIP_URL } else { 'https://136.108.58.125' }
$GrafanaUrl = if ($env:GRAFANA_URL) { $env:GRAFANA_URL } else { 'http://localhost:3000' }
$ToxiproxyPort = if ($env:TOXIPROXY_LOCAL_PORT) { $env:TOXIPROXY_LOCAL_PORT } else { '18474' }

if (-not (Get-Command gcloud -ErrorAction SilentlyContinue)) {
    $sdkBin = Join-Path (Join-Path $HOME 'google-cloud-sdk') 'bin'
    $env:PATH = $sdkBin + [IO.Path]::PathSeparator + $env:PATH
}

gcloud container clusters get-credentials $Cluster `
    --location $Location --project $Project --quiet *> $null
if ($LASTEXITCODE -ne 0) {
    throw 'gcloud no pudo obtener las credenciales del clúster.'
}

$context = "gke_${Project}_${Location}_${Cluster}"

kubectl --context $context --request-timeout=10s get --raw /healthz *> $null
if ($LASTEXITCODE -ne 0) {
    throw 'No se pudo conectar con el clúster. Si tu IP no está autorizada, ejecuta add-my-ip.ps1.'
}

function Reset-Toxiproxy {
    kubectl --context $context -n $Namespace get svc toxiproxy *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-Output 'Toxiproxy: no está desplegado; no hay nada que quitar.'
        return
    }

    $log = [IO.Path]::GetTempFileName()
    $portForward = Start-Process kubectl -PassThru -NoNewWindow `
        -RedirectStandardOutput $log `
        -ArgumentList '--context', $context, '-n', $Namespace, 'port-forward', 'svc/toxiproxy', "${ToxiproxyPort}:8474"
    try {
        $base = "http://127.0.0.1:$ToxiproxyPort"
        foreach ($attempt in 1..15) {
            try {
                Invoke-RestMethod -Uri "$base/version" -TimeoutSec 2 | Out-Null
                break
            } catch {
                Start-Sleep -Seconds 1
            }
        }

        # /reset quita todos los toxics y vuelve a habilitar los proxies.
        Invoke-RestMethod -Method Post -Uri "$base/reset" -TimeoutSec 10 | Out-Null
        Write-Output 'Toxiproxy: toxics quitados y proxies habilitados.'
    } finally {
        Stop-Process -Id $portForward.Id -ErrorAction SilentlyContinue
        Remove-Item $log -ErrorAction SilentlyContinue
    }
}

Reset-Toxiproxy

kubectl --context $context -n $Namespace scale deploy rabbitmq --replicas=1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'No se pudo escalar RabbitMQ.' }
kubectl --context $context -n $Namespace rollout status deploy/rabbitmq --timeout=180s | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'RabbitMQ no quedó listo.' }
Write-Output 'RabbitMQ: listo.'

kubectl --context $context -n $Namespace rollout status deploy/zulip --timeout=300s | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Zulip no quedó listo.' }

# curl.exe y no el alias de PowerShell: acepta el certificado autofirmado
# también en Windows PowerShell 5.1.
$curl = if (Get-Command curl.exe -ErrorAction SilentlyContinue) { 'curl.exe' } else { 'curl' }
$discard = [IO.Path]::GetTempFileName()
$code = ''
try {
    foreach ($attempt in 1..60) {
        $code = & $curl -k -s -m 5 -o $discard -w '%{http_code}' "$ZulipUrl/login/"
        if ($code -eq '200') { break }
        Start-Sleep -Seconds 5
    }
} finally {
    Remove-Item $discard -ErrorAction SilentlyContinue
}
if ($code -ne '200') {
    throw "Zulip no respondió 200 en $ZulipUrl/login/ (último código: $code)."
}
Write-Output "Zulip: responde en $ZulipUrl/login/."

$startMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$startTime = [DateTime]::UtcNow.ToString('HH:mm:ss')
Write-Output ''
Write-Output "Corrida iniciada a las ${startTime}Z. Dashboards desde este momento:"
Write-Output "  $GrafanaUrl/d/zulip-slo?from=$startMs&to=now"
Write-Output "  $GrafanaUrl/d/zulip-saturation?from=$startMs&to=now"
Write-Output "En el SLO, usa la fila 'Rango seleccionado': los paneles de 30 días incluyen la historia."
Write-Output 'Las métricas tardan hasta un minuto en aparecer.'
