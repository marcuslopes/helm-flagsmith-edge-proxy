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
.PARAMETER OrganisationApiToken
    Flagsmith Organisation API Token. When provided, the sync Job flow
    uses this token directly instead of creating one via the API.
.PARAMETER AdminEmail
    Bootstrap admin email (default: admin@example.com). Must match
    the bootstrap config in deploy/flagsmith-values.yaml.
.PARAMETER AdminPassword
    Bootstrap admin password. Set via Django manage.py if not already
    configured (default: testpassword123).
.PARAMETER Namespace
    Kubernetes namespace (default: flagsmith).
#>
param(
    [switch]$SkipCluster,
    [switch]$ManualKeys,
    [string]$ServerSideKey,
    [string]$ClientSideKey,
    [string]$OrganisationApiToken,
    [string]$AdminEmail = "admin@example.com",
    [string]$AdminPassword = "testpassword123",
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

    if (-not [string]::IsNullOrWhiteSpace($OrganisationApiToken)) {
        $token = $OrganisationApiToken
        Write-Ok "Using Organisation API Token from parameter"
    } else {
        Write-Step "Creating Organisation API Token via Flagsmith API"

        # Set bootstrap admin password via Django manage.py
        Write-Ok "Setting admin password via Django manage.py"
        $cmd = "from django.contrib.auth import get_user_model; " +
               "User = get_user_model(); " +
               "u = User.objects.get(email='$AdminEmail'); " +
               "u.set_password('$AdminPassword'); " +
               "u.save(); " +
               "print('OK')"
        $output = kubectl -n $Namespace exec deployment/flagsmith-api -c flagsmith-api `
            -- python manage.py shell -c $cmd 2>&1
        if ($output -notcontains "OK") {
            Write-Error "Failed to set admin password: $output"
        }
        Write-Ok "Admin password set"

        # Port-forward the API
        $apiPort = 18080
        $portForward = Start-Process -NoNewWindow -PassThru kubectl `
            -ArgumentList "-n", $Namespace, "port-forward", "svc/flagsmith-api", "${apiPort}:8000"
        Start-Sleep -Seconds 3
        $apiBase = "http://localhost:$apiPort"

        try {
            # Wait for API to be reachable (any HTTP response = up, even 401/403)
            $deadline = (Get-Date).AddSeconds(30)
            $apiReady = $false
            while ((Get-Date) -lt $deadline) {
                try {
                    $null = Invoke-WebRequest -Uri "$apiBase/api/v1/organisations/" -TimeoutSec 3 -UseBasicParsing -ErrorAction Stop
                    $apiReady = $true; break
                } catch {
                    if ($_.Exception.Response) {
                        # Got an HTTP response (e.g. 401/403) — API is up
                        $apiReady = $true; break
                    }
                    Start-Sleep -Seconds 2
                }
            }
            if (-not $apiReady) { Write-Error "Flagsmith API not reachable via port-forward" }

            # Log in
            $loginBody = @{ email = $AdminEmail; password = $AdminPassword } | ConvertTo-Json
            $loginResp = Invoke-RestMethod -Uri "$apiBase/api/v1/auth/login/" `
                -Method Post -ContentType "application/json" -Body $loginBody
            if (-not $loginResp.key) { Write-Error "Admin login failed" }
            $authHeaders = @{ Authorization = "Token $($loginResp.key)" }
            Write-Ok "Logged in as $AdminEmail"

            # Get organisation
            $orgs = Invoke-RestMethod -Uri "$apiBase/api/v1/organisations/" -Headers $authHeaders
            $orgResults = if ($orgs.results) { $orgs.results } else { @($orgs) }
            if (-not $orgResults) { Write-Error "No organisations found" }
            $orgId = $orgResults[0].id

            # Create Organisation API Token
            $tokenBody = @{ name = "deploy-script-token" } | ConvertTo-Json
            $tokenResp = Invoke-RestMethod -Uri "$apiBase/api/v1/organisations/$orgId/master-api-keys/" `
                -Method Post -ContentType "application/json" -Body $tokenBody -Headers $authHeaders
            if (-not $tokenResp.key) { Write-Error "Failed to create Organisation API Token" }
            $token = $tokenResp.key
            Write-Ok "Organisation API Token created"
        } finally {
            Stop-Process -Id $portForward.Id -ErrorAction SilentlyContinue
        }
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

    # Create ConfigMap from the sync script file
    $syncScriptFile = Join-Path $ScriptDir "deploy/scripts/sync-edge-proxy-secret.ps1"
    kubectl create configmap sync-edge-proxy-secret-script `
        --from-file=sync-edge-proxy-secret.ps1=$syncScriptFile `
        -n $Namespace --dry-run=client -o yaml | kubectl apply -f - -n $Namespace
    if ($LASTEXITCODE -ne 0) { Write-Error "Failed to create sync script ConfigMap" }
    Write-Ok "Sync script ConfigMap created"

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
