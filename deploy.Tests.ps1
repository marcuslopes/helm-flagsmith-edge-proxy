<#
.SYNOPSIS
    Pester tests for Flagsmith + Edge Proxy end-to-end deployment on kind.
.DESCRIPTION
    Deploys Flagsmith and Edge Proxy to a kind cluster, creates an Organisation
    API Token and a feature flag via the Flagsmith API, runs the sync Job, and
    verifies that Edge Proxy returns the created flag.
#>

BeforeDiscovery {
    # Pester 5 discovery phase — nothing needed here
}

Describe "Flagsmith + Edge Proxy deployment" -Tag "e2e" {

    BeforeAll {
        $script:Namespace = "flagsmith"
        $script:ScriptDir = $PSScriptRoot
        $script:PortForwardJobs = @()
        $script:OrgToken = $null
        $script:ClientKey = $null
        $script:FlagName = "test-flag-$(Get-Random -Minimum 1000 -Maximum 9999)"
        $script:AdminEmail = "admin@example.com"
        $script:AdminPassword = "testpassword123"
        $script:FlagsmithApiPort = 18080
        $script:EdgeProxyPort = 18000

        function Wait-ForUrl {
            param([string]$Url, [int]$TimeoutSeconds = 30)
            $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
            while ((Get-Date) -lt $deadline) {
                try {
                    $null = Invoke-RestMethod -Uri $Url -TimeoutSec 3 -ErrorAction Stop
                    return $true
                } catch {
                    Start-Sleep -Seconds 2
                }
            }
            return $false
        }

        function Start-PortForward {
            param([string]$Service, [int]$LocalPort, [int]$RemotePort)
            $job = Start-Job -ScriptBlock {
                param($ns, $svc, $lp, $rp)
                kubectl -n $ns port-forward "svc/$svc" "${lp}:${rp}" 2>&1
            } -ArgumentList $script:Namespace, $Service, $LocalPort, $RemotePort
            $script:PortForwardJobs += $job
            Start-Sleep -Seconds 3
            return $job
        }
    }

    It "Should have prerequisites installed" {
        foreach ($cmd in @("kubectl", "helm", "kind")) {
            Get-Command $cmd -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty -Because "'$cmd' must be installed"
        }
    }

    It "Should create a kind cluster" {
        $existing = kind get clusters 2>&1
        if ($existing -notmatch "^kind$") {
            kind create cluster
            $LASTEXITCODE | Should -Be 0 -Because "kind cluster creation must succeed"
        }
        kubectl cluster-info --context kind-kind 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0 -Because "kind cluster must be reachable"
    }

    It "Should install Flagsmith via Helm" {
        helm repo add flagsmith https://flagsmith.github.io/flagsmith-charts/ 2>&1 | Out-Null
        helm repo update 2>&1 | Out-Null

        $flagsmithValues = Join-Path $script:ScriptDir "deploy/flagsmith-values.yaml"
        helm upgrade --install flagsmith flagsmith/flagsmith `
            -n $script:Namespace --create-namespace `
            -f $flagsmithValues 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0 -Because "Flagsmith Helm install must succeed"
    }

    It "Should wait for Flagsmith pods to be ready" {
        Write-Host "        Waiting up to 5 min for Flagsmith deployments (image pulls may be slow)..." -ForegroundColor Yellow
        $output = kubectl -n $script:Namespace wait --for=condition=available `
            deployment/flagsmith deployment/flagsmith-api --timeout=300s 2>&1
        Write-Host "        $output" -ForegroundColor Gray
        $LASTEXITCODE | Should -Be 0 -Because "Flagsmith deployments must become available"
    }

    It "Should set bootstrap admin password" {
        # The Flagsmith bootstrap creates the admin user without a password.
        # Set one via Django management command so the test can log in via API.
        Write-Host "        Setting admin password via Django manage.py..." -ForegroundColor Yellow
        $cmd = "from django.contrib.auth import get_user_model; " +
               "User = get_user_model(); " +
               "u = User.objects.get(email='$($script:AdminEmail)'); " +
               "u.set_password('$($script:AdminPassword)'); " +
               "u.save(); " +
               "print('OK')"
        $output = kubectl -n $script:Namespace exec deployment/flagsmith-api -c flagsmith-api `
            -- python manage.py shell -c $cmd 2>&1
        Write-Host "        $output" -ForegroundColor Gray
        $output | Should -Contain "OK" -Because "password must be set successfully"
    }

    It "Should obtain an Organisation API Token from Flagsmith" {
        # Port-forward the Flagsmith API
        $null = Start-PortForward -Service "flagsmith-api" -LocalPort $script:FlagsmithApiPort -RemotePort 8000

        $apiBase = "http://localhost:$($script:FlagsmithApiPort)"
        Wait-ForUrl -Url "$apiBase/api/v1/organisations/" -TimeoutSeconds 30 | Out-Null

        # Log in with bootstrap admin credentials
        $loginBody = @{
            email    = $script:AdminEmail
            password = $script:AdminPassword
        } | ConvertTo-Json

        $loginResp = Invoke-RestMethod -Uri "$apiBase/api/v1/auth/login/" `
            -Method Post -ContentType "application/json" -Body $loginBody
        $loginResp.key | Should -Not -BeNullOrEmpty -Because "admin login must return an auth token"
        $script:AuthToken = $loginResp.key

        # Get the organisation
        $orgs = Invoke-RestMethod -Uri "$apiBase/api/v1/organisations/" `
            -Headers @{ Authorization = "Token $($script:AuthToken)" }
        $orgResults = if ($orgs.results) { $orgs.results } else { @($orgs) }
        $orgResults | Should -Not -BeNullOrEmpty -Because "at least one organisation must exist"
        $script:OrgId = $orgResults[0].id

        # Create a Master API Key (Organisation API Token)
        $tokenBody = @{ name = "pester-test-token" } | ConvertTo-Json
        $tokenResp = Invoke-RestMethod -Uri "$apiBase/api/v1/organisations/$($script:OrgId)/master-api-keys/" `
            -Method Post -ContentType "application/json" -Body $tokenBody `
            -Headers @{ Authorization = "Token $($script:AuthToken)" }
        $tokenResp.key | Should -Not -BeNullOrEmpty -Because "master API key creation must return a key"
        $script:OrgToken = $tokenResp.key
        Write-Host "        Organisation API Token created: $($tokenResp.prefix)..." -ForegroundColor Gray
    }

    It "Should create a feature flag in Flagsmith" {
        $apiBase = "http://localhost:$($script:FlagsmithApiPort)"
        $headers = @{ Authorization = "Token $($script:AuthToken)" }

        # Get projects (returns a plain list, not paginated)
        $projects = Invoke-RestMethod -Uri "$apiBase/api/v1/projects/" -Headers $headers
        $projectList = if ($projects -is [array]) { $projects } else { @($projects) }
        $projectList | Should -Not -BeNullOrEmpty -Because "at least one project must exist"
        $projectId = $projectList[0].id

        # Create an environment (bootstrap does not create one)
        $envBody = @{ name = "Development"; project = $projectId } | ConvertTo-Json
        $envResp = Invoke-RestMethod -Uri "$apiBase/api/v1/environments/" `
            -Method Post -ContentType "application/json" -Body $envBody -Headers $headers
        $envResp.api_key | Should -Not -BeNullOrEmpty -Because "environment must have a client-side key"
        $script:ClientKey = $envResp.api_key
        Write-Host "        Environment created, client key: $($script:ClientKey)" -ForegroundColor Gray

        # Create feature flag
        $flagBody = @{
            name            = $script:FlagName
            project         = $projectId
            type            = "FLAG"
            default_enabled = $true
        } | ConvertTo-Json
        $flagResp = Invoke-RestMethod -Uri "$apiBase/api/v1/projects/$projectId/features/" `
            -Method Post -ContentType "application/json" -Body $flagBody -Headers $headers
        $flagResp.name | Should -Be $script:FlagName -Because "the created flag name must match"
        Write-Host "        Feature flag '$($script:FlagName)' created" -ForegroundColor Gray
    }

    It "Should populate Edge Proxy secret via sync Job" {
        $script:OrgToken | Should -Not -BeNullOrEmpty -Because "OrgToken must be set from a prior test"

        # Apply the organisation token secret using deploy.ps1's non-interactive path
        $tokenExampleFile = Join-Path $script:ScriptDir "deploy/flagsmith-organisation-token.example.yaml"
        $tokenSecretFile = Join-Path $script:ScriptDir "deploy/flagsmith-organisation-token.yaml"
        $content = Get-Content $tokenExampleFile -Raw
        $content = $content -replace "YOUR_ORGANISATION_API_TOKEN", $script:OrgToken
        $content | Set-Content $tokenSecretFile -NoNewline

        kubectl apply -f $tokenSecretFile -n $script:Namespace 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0 -Because "organisation token secret must be applied"

        # Delete previous job run if it exists
        kubectl delete job sync-edge-proxy-secret -n $script:Namespace --ignore-not-found 2>&1 | Out-Null

        # Create ConfigMap from the sync script file
        $syncScriptFile = Join-Path $script:ScriptDir "deploy/scripts/sync-edge-proxy-secret.ps1"
        kubectl create configmap sync-edge-proxy-secret-script `
            --from-file=sync-edge-proxy-secret.ps1=$syncScriptFile `
            -n $script:Namespace --dry-run=client -o yaml | kubectl apply -f - -n $script:Namespace 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0 -Because "sync script ConfigMap must be created"

        # Apply sync job
        $syncJobFile = Join-Path $script:ScriptDir "deploy/sync-edge-proxy-secret-job.yaml"
        kubectl apply -f $syncJobFile -n $script:Namespace 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0 -Because "sync job must be applied"

        # Wait for completion
        Write-Host "        Waiting up to 2 min for sync job..." -ForegroundColor Yellow
        $output = kubectl -n $script:Namespace wait --for=condition=complete job/sync-edge-proxy-secret --timeout=120s 2>&1
        Write-Host "        $output" -ForegroundColor Gray
        $LASTEXITCODE | Should -Be 0 -Because "sync job must complete successfully"
    }

    It "Should install Edge Proxy" {
        $edgeProxyValues = Join-Path $script:ScriptDir "deploy/edge-proxy-values.yaml"
        $chartPath = Join-Path $script:ScriptDir "charts/edge-proxy"
        helm upgrade --install edge-proxy $chartPath `
            -n $script:Namespace `
            -f $edgeProxyValues 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0 -Because "Edge Proxy Helm install must succeed"
    }

    It "Should wait for Edge Proxy to be ready" {
        Write-Host "        Waiting up to 2 min for Edge Proxy deployment..." -ForegroundColor Yellow
        $output = kubectl -n $script:Namespace wait --for=condition=available deployment/edge-proxy --timeout=120s 2>&1
        Write-Host "        $output" -ForegroundColor Gray
        $LASTEXITCODE | Should -Be 0 -Because "Edge Proxy deployment must become available"
    }

    It "Should retrieve flags from Edge Proxy" {
        $script:ClientKey | Should -Not -BeNullOrEmpty -Because "ClientKey must be set from a prior test"

        # Port-forward edge-proxy
        $null = Start-PortForward -Service "edge-proxy" -LocalPort $script:EdgeProxyPort -RemotePort 8000

        $epBase = "http://localhost:$($script:EdgeProxyPort)"
        $ready = Wait-ForUrl -Url "$epBase/proxy/health" -TimeoutSeconds 30
        $ready | Should -BeTrue -Because "Edge Proxy must be reachable"

        # Retrieve flags
        $flags = Invoke-RestMethod -Uri "$epBase/api/v1/flags/" `
            -Headers @{ "X-Environment-Key" = $script:ClientKey }

        $flags | Should -Not -BeNullOrEmpty -Because "Edge Proxy must return flags"
        $flagNames = $flags | ForEach-Object { $_.feature.name }
        $flagNames | Should -Contain $script:FlagName -Because "the feature flag we created must be present"
    }

    AfterAll {
        # Clean up port-forward jobs
        foreach ($job in $script:PortForwardJobs) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }

        # Clean up generated secret file
        $tokenSecretFile = Join-Path $script:ScriptDir "deploy/flagsmith-organisation-token.yaml"
        if (Test-Path $tokenSecretFile) {
            Remove-Item $tokenSecretFile -ErrorAction SilentlyContinue
        }
    }
}
