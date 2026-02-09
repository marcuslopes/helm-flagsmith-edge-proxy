<#
.SYNOPSIS
    Deploy Flagsmith and Edge Proxy to a local kind cluster.
.DESCRIPTION
    Automates the full deployment: kind cluster creation, Flagsmith install,
    Edge Proxy secret setup, and Edge Proxy Helm install.
.PARAMETER SkipCluster
    Skip kind cluster creation (use existing cluster).
.PARAMETER ManualKeys
    Use manual key entry instead of the sync Job.
.PARAMETER ServerSideKey
    Server-side environment key (for -ManualKeys).
.PARAMETER ClientSideKey
    Client-side environment key (for -ManualKeys).
.PARAMETER Namespace
    Kubernetes namespace (default: flagsmith).
#>
param(
    [switch]$SkipCluster,
    [switch]$ManualKeys,
    [string]$ServerSideKey,
    [string]$ClientSideKey,
    [string]$Namespace = "flagsmith"
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "    $msg" -ForegroundColor Yellow }

# --- Prerequisite checks ---
Write-Step "Checking prerequisites"
foreach ($cmd in @("kubectl", "helm", "kind")) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Write-Error "'$cmd' is not installed or not in PATH."
    }
    Write-Ok "$cmd found"
}

# --- 1. Kind cluster ---
if (-not $SkipCluster) {
    Write-Step "Creating kind cluster"
    $existing = kind get clusters 2>&1
    if ($existing -match "^kind$") {
        Write-Warn "kind cluster 'kind' already exists, skipping creation"
    } else {
        kind create cluster
        if ($LASTEXITCODE -ne 0) { Write-Error "Failed to create kind cluster" }
    }
} else {
    Write-Step "Skipping kind cluster creation (-SkipCluster)"
}

kubectl cluster-info --context kind-kind
if ($LASTEXITCODE -ne 0) { Write-Error "Cannot connect to kind cluster" }
Write-Ok "Cluster is reachable"

# --- 2. Install Flagsmith ---
Write-Step "Installing Flagsmith via Helm"
helm repo add flagsmith https://flagsmith.github.io/flagsmith-charts/ 2>&1 | Out-Null
helm repo update | Out-Null
Write-Ok "Helm repo updated"

$flagsmithValues = Join-Path $ScriptDir "deploy/flagsmith-values.yaml"
helm upgrade --install flagsmith flagsmith/flagsmith `
    -n $Namespace --create-namespace `
    -f $flagsmithValues
if ($LASTEXITCODE -ne 0) { Write-Error "Flagsmith Helm install failed" }
Write-Ok "Flagsmith release installed/upgraded"

Write-Step "Waiting for Flagsmith pods to be ready (this may take a few minutes)"
kubectl -n $Namespace wait --for=condition=available deployment --all --timeout=300s
if ($LASTEXITCODE -ne 0) {
    Write-Warn "Not all deployments are available yet. Check with: kubectl -n $Namespace get pods"
} else {
    Write-Ok "All Flagsmith deployments available"
}

# --- 3. Edge Proxy Secret ---
if ($ManualKeys) {
    Write-Step "Creating Edge Proxy secret (manual keys)"
    if (-not $ServerSideKey -or -not $ClientSideKey) {
        Write-Error "When using -ManualKeys, provide -ServerSideKey and -ClientSideKey"
    }

    $secretFile = Join-Path $ScriptDir "deploy/edge-proxy-secret.yaml"
    $exampleFile = Join-Path $ScriptDir "deploy/edge-proxy-secret.example.yaml"
    $content = Get-Content $exampleFile -Raw
    $content = $content -replace "ser\.YOUR_SERVER_SIDE_KEY", $ServerSideKey
    $content = $content -replace "YOUR_CLIENT_SIDE_KEY", $ClientSideKey
    $content | Set-Content $secretFile -NoNewline
    kubectl apply -f $secretFile -n $Namespace
    if ($LASTEXITCODE -ne 0) { Write-Error "Failed to apply edge-proxy-config secret" }
    Write-Ok "Edge Proxy secret applied"
} else {
    Write-Step "Setting up Edge Proxy secret via sync Job"
    Write-Warn "You need an Organisation API Token from the Flagsmith UI."
    Write-Warn "If you haven't created one yet, the script will port-forward so you can."

    # Port-forward Flagsmith frontend briefly so user can get the token
    Write-Host ""
    $token = Read-Host "Enter your Flagsmith Organisation API Token (or press Enter to port-forward and create one)"

    if ([string]::IsNullOrWhiteSpace($token)) {
        Write-Step "Port-forwarding Flagsmith frontend to localhost:8080"
        $portForward = Start-Process -NoNewWindow -PassThru kubectl `
            -ArgumentList "-n", $Namespace, "port-forward", "svc/flagsmith-frontend", "8080:8080"
        Write-Ok "Port-forward started (PID $($portForward.Id))"
        Write-Host "    Open http://localhost:8080 in your browser" -ForegroundColor Yellow
        Write-Host "    Log in -> Organisation -> API Keys -> Create Token" -ForegroundColor Yellow
        Write-Host ""
        $token = Read-Host "Paste your Organisation API Token here"
        Stop-Process -Id $portForward.Id -ErrorAction SilentlyContinue
        Write-Ok "Port-forward stopped"
    }

    if ([string]::IsNullOrWhiteSpace($token)) {
        Write-Error "No token provided. Cannot run sync Job."
    }

    # Create the organisation token secret
    $tokenSecretFile = Join-Path $ScriptDir "deploy/flagsmith-organisation-token.yaml"
    $tokenExampleFile = Join-Path $ScriptDir "deploy/flagsmith-organisation-token.example.yaml"
    $content = Get-Content $tokenExampleFile -Raw
    $content = $content -replace "YOUR_ORGANISATION_API_TOKEN", $token
    $content | Set-Content $tokenSecretFile -NoNewline
    kubectl apply -f $tokenSecretFile -n $Namespace
    if ($LASTEXITCODE -ne 0) { Write-Error "Failed to apply organisation token secret" }
    Write-Ok "Organisation token secret applied"

    # Delete previous job run if it exists (jobs are immutable)
    kubectl delete job sync-edge-proxy-secret -n $Namespace --ignore-not-found 2>&1 | Out-Null

    # Apply sync job
    $syncJobFile = Join-Path $ScriptDir "deploy/sync-edge-proxy-secret-job.yaml"
    kubectl apply -f $syncJobFile -n $Namespace
    if ($LASTEXITCODE -ne 0) { Write-Error "Failed to apply sync job" }

    Write-Step "Waiting for sync Job to complete"
    kubectl -n $Namespace wait --for=condition=complete job/sync-edge-proxy-secret --timeout=120s
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "Sync job did not complete. Check logs:"
        Write-Warn "  kubectl -n $Namespace logs job/sync-edge-proxy-secret"
    } else {
        Write-Ok "Sync Job completed - edge-proxy-config secret created"
    }
}

# --- 4. Install Edge Proxy ---
Write-Step "Installing Edge Proxy via Helm"
$edgeProxyValues = Join-Path $ScriptDir "deploy/edge-proxy-values.yaml"
helm upgrade --install edge-proxy (Join-Path $ScriptDir "charts/edge-proxy") `
    -n $Namespace `
    -f $edgeProxyValues
if ($LASTEXITCODE -ne 0) { Write-Error "Edge Proxy Helm install failed" }
Write-Ok "Edge Proxy release installed/upgraded"

Write-Step "Waiting for Edge Proxy to be ready"
kubectl -n $Namespace wait --for=condition=available deployment/edge-proxy --timeout=120s
if ($LASTEXITCODE -ne 0) {
    Write-Warn "Edge Proxy not ready yet. It needs valid keys to start."
    Write-Warn "Check: kubectl -n $Namespace get pods -l app.kubernetes.io/name=edge-proxy"
} else {
    Write-Ok "Edge Proxy is running"
}

# --- Done ---
Write-Step "Deployment complete!"
Write-Host ""
Write-Host "  To test Edge Proxy:" -ForegroundColor White
Write-Host "    kubectl -n $Namespace port-forward svc/edge-proxy 8000:8000" -ForegroundColor Gray
Write-Host "    curl -H 'X-Environment-Key: <YOUR_CLIENT_SIDE_KEY>' http://localhost:8000/api/v1/flags/" -ForegroundColor Gray
Write-Host ""
Write-Host "  To access Flagsmith UI:" -ForegroundColor White
Write-Host "    kubectl -n $Namespace port-forward svc/flagsmith-frontend 8080:8080" -ForegroundColor Gray
Write-Host "    Open http://localhost:8080" -ForegroundColor Gray
Write-Host ""
