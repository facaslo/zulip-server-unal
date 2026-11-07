# Agrega la IP pública actual a la lista de redes autorizadas del clúster.
#
# Uso: ./add-my-ip.ps1 [-DryRun]
#
# La lista se reemplaza completa al actualizarla, así que primero se
# leen las entradas actuales para conservarlas. El cambio es temporal:
# el siguiente terraform apply restablece la lista del secreto
# AUTHORIZED_NETWORKS.
param(
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$Project = if ($env:GCP_PROJECT) { $env:GCP_PROJECT } else { 'proyecto-zulip-unal' }
$Cluster = if ($env:GKE_CLUSTER) { $env:GKE_CLUSTER } else { 'zulip' }
$Location = if ($env:GKE_LOCATION) { $env:GKE_LOCATION } else { 'us-east1-b' }

if (-not (Get-Command gcloud -ErrorAction SilentlyContinue)) {
    $sdkBin = Join-Path (Join-Path $HOME 'google-cloud-sdk') 'bin'
    $env:PATH = $sdkBin + [IO.Path]::PathSeparator + $env:PATH
}

$myIp = ([string](Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 10)).Trim()
if ($myIp -notmatch '^\d+\.\d+\.\d+\.\d+$') {
    throw "No se pudo obtener una IPv4 pública válida: '$myIp'"
}
$myCidr = "$myIp/32"

$current = gcloud container clusters describe $Cluster `
    --location $Location --project $Project `
    --format='value(masterAuthorizedNetworksConfig.cidrBlocks[].cidrBlock.list())'
if ($LASTEXITCODE -ne 0) {
    throw 'gcloud no pudo leer el clúster; no se cambió nada.'
}

# Una lectura vacía sobrescribiría las entradas de todo el equipo.
$current = ([string]$current).Trim()
if (-not $current) {
    throw 'No se pudo leer la lista actual de redes autorizadas; no se cambió nada.'
}

Write-Output "IP actual:         $myCidr"
Write-Output "Lista autorizada:  $current"

if (($current -split ',') -contains $myCidr) {
    Write-Output 'La IP ya está autorizada; no hay nada que cambiar.'
    exit 0
}

$newList = "$current,$myCidr"
if ($DryRun) {
    Write-Output "Simulación; la lista quedaría así: $newList"
    exit 0
}

gcloud container clusters update $Cluster `
    --location $Location --project $Project `
    --enable-master-authorized-networks `
    --master-authorized-networks $newList `
    --quiet
if ($LASTEXITCODE -ne 0) {
    throw 'gcloud no pudo actualizar la lista de redes autorizadas.'
}

Write-Output "Listo. Lista autorizada: $newList"
