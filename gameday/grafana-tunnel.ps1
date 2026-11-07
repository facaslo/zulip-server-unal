# Abre un túnel a Grafana en http://localhost:3000 (Ctrl+C para cerrarlo).
#
# Uso: ./grafana-tunnel.ps1 [-LocalPort 3000]
#
# Muestra el usuario y la contraseña de Grafana, leída de Secret Manager,
# solo si la salida es una terminal; así no queda en logs ni archivos.
param(
    [int]$LocalPort = 3000
)

$ErrorActionPreference = 'Stop'

$Project = if ($env:GCP_PROJECT) { $env:GCP_PROJECT } else { 'proyecto-zulip-unal' }
$Cluster = if ($env:GKE_CLUSTER) { $env:GKE_CLUSTER } else { 'zulip' }
$Location = if ($env:GKE_LOCATION) { $env:GKE_LOCATION } else { 'us-east1-b' }
$GrafanaSecret = if ($env:GRAFANA_SECRET) { $env:GRAFANA_SECRET } else { 'zulip-grafana-admin-password' }

if (-not (Get-Command gcloud -ErrorAction SilentlyContinue)) {
    $sdkBin = Join-Path (Join-Path $HOME 'google-cloud-sdk') 'bin'
    $env:PATH = $sdkBin + [IO.Path]::PathSeparator + $env:PATH
}

gcloud container clusters get-credentials $Cluster `
    --location $Location --project $Project --quiet
if ($LASTEXITCODE -ne 0) {
    throw 'gcloud no pudo obtener las credenciales del clúster.'
}

$context = "gke_${Project}_${Location}_${Cluster}"

kubectl --context $context --request-timeout=10s get --raw /healthz *> $null
if ($LASTEXITCODE -ne 0) {
    throw 'No se pudo conectar con el clúster. Si tu IP no está autorizada, ejecuta add-my-ip.ps1.'
}

Write-Output "Grafana: http://localhost:$LocalPort"
Write-Output 'Usuario: admin'
if ([Console]::IsOutputRedirected) {
    Write-Output 'Contraseña: no se muestra porque la salida no es una terminal.'
} else {
    $password = gcloud secrets versions access latest `
        --secret $GrafanaSecret --project $Project
    if ($LASTEXITCODE -eq 0) {
        Write-Output "Contraseña: $password"
    } else {
        Write-Warning "No se pudo leer la contraseña del secreto $GrafanaSecret; el túnel se abre igual."
    }
}

# kubectl port-forward termina cuando se pierde la conexión con el Pod.
# Se reconecta, salvo que falle varias veces seguidas apenas arranca,
# como cuando el puerto local está ocupado.
$quickFailures = 0
while ($quickFailures -lt 5) {
    $startedAt = Get-Date
    kubectl --context $context -n monitoring port-forward `
        --address 127.0.0.1 svc/grafana "${LocalPort}:3000"

    if (((Get-Date) - $startedAt).TotalSeconds -lt 10) {
        $quickFailures++
    } else {
        $quickFailures = 0
    }
    Write-Warning 'Túnel cerrado; reconectando...'
    Start-Sleep -Seconds 2
}

throw "El túnel falló $quickFailures veces seguidas; revisa el error de kubectl."
