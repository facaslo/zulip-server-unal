# Provoca y revierte el incidente de caída de RabbitMQ.
#
# Uso: ./rabbitmq-crash.ps1 status
#      ./rabbitmq-crash.ps1 crash [-Yes]
#      ./rabbitmq-crash.ps1 restore
#
# crash deja RabbitMQ en 0 réplicas, y tumba Zulip de verdad: cerca de 50 s
# después, /health falla y el Pod sale del balanceador.  Sigue caído hasta
# ejecutar restore o hasta el siguiente terraform apply, que lo restablece.
# Sus errores cuentan en la historia de los SLI de 30 días.
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet('status', 'crash', 'restore')]
    [string]$Action,

    [switch]$Yes
)

$ErrorActionPreference = 'Stop'

$Project = if ($env:GCP_PROJECT) { $env:GCP_PROJECT } else { 'proyecto-zulip-unal' }
$Cluster = if ($env:GKE_CLUSTER) { $env:GKE_CLUSTER } else { 'zulip' }
$Location = if ($env:GKE_LOCATION) { $env:GKE_LOCATION } else { 'us-east1-b' }
$Namespace = if ($env:ZULIP_NAMESPACE) { $env:ZULIP_NAMESPACE } else { 'zulip' }
$ZulipUrl = if ($env:ZULIP_URL) { $env:ZULIP_URL } else { 'https://136.108.58.125' }

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

function Invoke-Kubectl {
    $output = kubectl --context $context -n $Namespace @args
    if ($LASTEXITCODE -ne 0) {
        throw "kubectl falló: $($args -join ' ')"
    }
    return $output
}

function Get-UtcTime {
    return [DateTime]::UtcNow.ToString('HH:mm:ss') + 'Z'
}

# curl.exe y no el alias de PowerShell: acepta el certificado autofirmado
# también en Windows PowerShell 5.1.
$curl = if (Get-Command curl.exe -ErrorAction SilentlyContinue) { 'curl.exe' } else { 'curl' }

function Get-LoginCode {
    $discard = [IO.Path]::GetTempFileName()
    try {
        return & $curl -k -s -m 5 -o $discard -w '%{http_code}' "$ZulipUrl/login/"
    } finally {
        Remove-Item $discard -ErrorAction SilentlyContinue
    }
}

switch ($Action) {
    'status' {
        $desired = Invoke-Kubectl get deploy rabbitmq -o 'jsonpath={.spec.replicas}'
        $ready = Invoke-Kubectl get deploy rabbitmq -o 'jsonpath={.status.readyReplicas}'
        if (-not $ready) { $ready = '0' }
        $zulip = Invoke-Kubectl get deploy zulip -o 'jsonpath={.status.availableReplicas}'
        Write-Output "RabbitMQ: $ready/$desired réplicas listas"
        Write-Output "Zulip:    $zulip réplicas disponibles"
        Write-Output "Login:    HTTP $(Get-LoginCode) en $ZulipUrl/login/"
    }

    'crash' {
        if ((Invoke-Kubectl get deploy rabbitmq -o 'jsonpath={.spec.replicas}') -eq '0') {
            Write-Output 'RabbitMQ ya está en 0 réplicas; no se cambió nada.'
            exit 0
        }
        if (-not $Yes) {
            Write-Output 'Esto tumba Zulip para todos sus usuarios hasta ejecutar restore.'
            if ((Read-Host "Escribe 'rabbitmq' para continuar") -ne 'rabbitmq') {
                Write-Output 'Cancelado: no se cambió nada.'
                exit 1
            }
        }

        Invoke-Kubectl scale deploy rabbitmq --replicas=0 | Out-Null
        Write-Output "RabbitMQ caído a las $(Get-UtcTime)."
        Write-Output ''
        Write-Output 'Qué observar:'
        Write-Output '  - Saturación: el widget de RabbitMQ pasa a Caído.'
        Write-Output '  - Explore, Cloud Trace: HasLabel:error.type muestra las publicaciones fallidas.'
        Write-Output '  - La alerta de caídas de Cloud Monitoring tardó unos 4,5 min en el ensayo.'
        Write-Output 'Sin tráfico de mensajes no habrá errores ni trazas que observar.'
        Write-Output "Para revertir: $PSCommandPath restore"
    }

    'restore' {
        $started = Get-Date
        Invoke-Kubectl scale deploy rabbitmq --replicas=1 | Out-Null
        Invoke-Kubectl rollout status deploy/rabbitmq --timeout=180s | Out-Null
        $elapsed = [int]((Get-Date) - $started).TotalSeconds
        Write-Output "RabbitMQ listo a las $(Get-UtcTime), tras $elapsed s."

        $code = ''
        foreach ($attempt in 1..60) {
            $code = Get-LoginCode
            if ($code -eq '200') { break }
            Start-Sleep -Seconds 5
        }
        if ($code -ne '200') {
            throw "Zulip no respondió 200 en $ZulipUrl/login/ (último código: $code)."
        }
        $elapsed = [int]((Get-Date) - $started).TotalSeconds
        Write-Output "Zulip responde a las $(Get-UtcTime), tras $elapsed s."
    }
}
