#!/usr/bin/env pwsh
<#
.SYNOPSIS
    Fetch all environment key pairs from all Flagsmith projects and create/update
    the edge-proxy-config Secret.
.DESCRIPTION
    Requires ORGANISATION_API_TOKEN and FLAGSMITH_API_URL in the environment;
    optional NAMESPACE (default: flagsmith).
    Uses the in-cluster service account for Kubernetes API access.
#>

$ErrorActionPreference = "Stop"

# --- Configuration from environment ---
$Token       = ($env:ORGANISATION_API_TOKEN ?? "").Trim()
$BaseUrl     = ($env:FLAGSMITH_API_URL ?? "").Trim()
$Namespace   = if ($env:NAMESPACE) { $env:NAMESPACE } else { "flagsmith" }

if (-not $Token) {
    Write-Warning "ORGANISATION_API_TOKEN not set; skipping sync."
    exit 0
}
if (-not $BaseUrl) {
    Write-Error "FLAGSMITH_API_URL not set."
    exit 1
}

$ApiUrlForEdge = $BaseUrl.TrimEnd("/") + "/api/v1"

# --- Helper: Flagsmith API calls ---
function Invoke-FlagsmithApi {
    param(
        [string]$Path,
        [string]$Method = "GET",
        [object]$Body
    )
    $url = $BaseUrl.TrimEnd("/") + $Path
    $params = @{
        Uri         = $url
        Method      = $Method
        Headers     = @{ Authorization = "Api-Key $Token" }
        ContentType = "application/json"
        TimeoutSec  = 15
    }
    if ($Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 10)
    }
    Invoke-RestMethod @params
}

function Get-ResultsList($response) {
    if ($response -is [array]) { return $response }
    if ($response -is [hashtable] -or $response.PSObject.Properties.Name -contains "results") {
        $r = $response.results
        if ($r -is [array]) { return $r }
    }
    return @()
}

# --- Wait for Flagsmith API ---
Write-Host "Waiting for Flagsmith API..."
$maxAttempts = 30
$apiReady = $false
for ($i = 0; $i -lt $maxAttempts; $i++) {
    try {
        $null = Invoke-FlagsmithApi -Path "/api/v1/projects/"
        $apiReady = $true
        break
    } catch {
        $status = $_.Exception.Response.StatusCode.value__
        if ($status -eq 401) {
            $apiReady = $true
            break
        }
        Start-Sleep -Seconds 2
    }
}
if (-not $apiReady) {
    Write-Error "Flagsmith API not reachable."
    exit 1
}
Write-Host "Flagsmith API is up."

# --- List all projects ---
try {
    $projectsResp = Invoke-FlagsmithApi -Path "/api/v1/projects/"
} catch {
    $status = $_.Exception.Response.StatusCode.value__
    Write-Error "Failed to list projects: $status"
    exit 1
}
$projectList = Get-ResultsList $projectsResp
if ($projectList.Count -eq 0) {
    Write-Error "No projects found; create one in the UI or use bootstrap."
    exit 1
}
Write-Host "Found $($projectList.Count) project(s)."

# --- Collect key pairs from all environments across all projects ---
$pairs = @()
foreach ($project in $projectList) {
    $projectId = $project.id
    $projectName = $project.name
    Write-Host "Processing project '$projectName' (id=$projectId)..."

    try {
        $envsResp = Invoke-FlagsmithApi -Path "/api/v1/environments/?project=$projectId"
    } catch {
        Write-Warning "Failed to list environments for project '$projectName'; skipping."
        continue
    }
    $envs = Get-ResultsList $envsResp

    if ($envs.Count -eq 0) {
        Write-Host "  No environments in project '$projectName'; skipping."
        continue
    }

    foreach ($env in $envs) {
        $clientKey = $env.api_key
        if (-not $clientKey) { continue }

        $serverKey = $null
        try {
            $keysResp = Invoke-FlagsmithApi -Path "/api/v1/environments/$clientKey/api-keys/"
            $keyList = Get-ResultsList $keysResp
            if ($keyList.Count -eq 0 -and $keysResp -is [PSCustomObject] -and $keysResp.key) {
                $keyList = @($keysResp)
            }
            foreach ($k in $keyList) {
                $active = if ($null -ne $k.active) { $k.active } else { $true }
                if ($active -and $k.key) {
                    $serverKey = $k.key
                    break
                }
            }
            if (-not $serverKey) {
                $created = Invoke-FlagsmithApi -Path "/api/v1/environments/$clientKey/api-keys/" `
                    -Method POST -Body @{ name = "auto-created" }
                if ($created.key) {
                    $serverKey = $created.key
                }
            }
        } catch {
            # Skip this environment on error
        }

        if ($serverKey) {
            $pairs += @{
                server_side_key = $serverKey
                client_side_key = $clientKey
            }
            Write-Host "  Collected key pair for environment '$($env.name)'"
        }
    }
}

if ($pairs.Count -eq 0) {
    Write-Error "No environment key pairs collected."
    exit 1
}

# --- Build secret data ---
$envPairsJson = ($pairs | ConvertTo-Json -Depth 5 -Compress)
# Ensure it's always a JSON array even with a single pair
if ($pairs.Count -eq 1) {
    $envPairsJson = "[$envPairsJson]"
}

Write-Host "Collected $($pairs.Count) environment key pair(s)."

# --- Create/update Kubernetes Secret via in-cluster API ---
$saTokenPath = "/var/run/secrets/kubernetes.io/serviceaccount/token"
$saCaPath    = "/var/run/secrets/kubernetes.io/serviceaccount/ca.crt"
$k8sHost     = $env:KUBERNETES_SERVICE_HOST
$k8sPort     = $env:KUBERNETES_SERVICE_PORT

if (-not $k8sHost) {
    Write-Error "KUBERNETES_SERVICE_HOST not set; not running in-cluster."
    exit 1
}

$saToken = Get-Content $saTokenPath -Raw
$k8sBase = "https://${k8sHost}:${k8sPort}"
$secretUrl = "$k8sBase/api/v1/namespaces/$Namespace/secrets/edge-proxy-config"

$secretBody = @{
    apiVersion = "v1"
    kind       = "Secret"
    metadata   = @{
        name      = "edge-proxy-config"
        namespace = $Namespace
    }
    type       = "Opaque"
    stringData = @{
        API_URL              = $ApiUrlForEdge
        ENVIRONMENT_KEY_PAIRS = $envPairsJson
    }
} | ConvertTo-Json -Depth 5

$k8sHeaders = @{
    Authorization  = "Bearer $saToken"
    "Content-Type" = "application/json"
}

# Try to replace existing secret, create if 404
try {
    $null = Invoke-RestMethod -Uri $secretUrl -Method Put -Headers $k8sHeaders `
        -Body $secretBody -TimeoutSec 15 `
        -SkipCertificateCheck:$false `
        -SslCaFilePath $saCaPath 2>$null
    Write-Host "Updated Secret edge-proxy-config."
} catch {
    $status = $_.Exception.Response.StatusCode.value__
    if ($status -eq 404) {
        $createUrl = "$k8sBase/api/v1/namespaces/$Namespace/secrets"
        try {
            $null = Invoke-RestMethod -Uri $createUrl -Method Post -Headers $k8sHeaders `
                -Body $secretBody -TimeoutSec 15 `
                -SkipCertificateCheck:$false `
                -SslCaFilePath $saCaPath 2>$null
            Write-Host "Created Secret edge-proxy-config."
        } catch {
            Write-Error "Failed to create Secret: $_"
            exit 1
        }
    } else {
        Write-Error "Failed to update Secret: $_"
        exit 1
    }
}

exit 0
