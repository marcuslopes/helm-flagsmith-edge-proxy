# Flagsmith and Edge Proxy on kind

Deploy Flagsmith and Edge Proxy to a local Kubernetes cluster (kind) using Helm. Edge Proxy reads its config (Flagsmith API URL and environment keys) from a Kubernetes Secret.

## Prerequisites

- [kind](https://kind.sigs.k8s.io/) (or another local cluster)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Helm 3](https://helm.sh/)
- [PowerShell](https://learn.microsoft.com/en-us/powershell/scripting/install/installing-powershell) (for the automated deploy script)

## Quick start (automated)

The `deploy.ps1` script automates the full deployment end-to-end:

```powershell
# Full deployment — creates kind cluster, prompts for Organisation API Token, deploys everything
./deploy.ps1

# Skip cluster creation if you already have one
./deploy.ps1 -SkipCluster

# Provide keys manually instead of using the sync Job
./deploy.ps1 -ManualKeys -ServerSideKey "ser.xxx" -ClientSideKey "xxx"
```

The script will:
1. Check prerequisites (`kind`, `kubectl`, `helm`)
2. Create a kind cluster (or reuse an existing one)
3. Install Flagsmith and wait for it to be ready
4. Set up the Edge Proxy secret (via sync Job or manual keys)
5. Install the Edge Proxy Helm chart
6. Print instructions for testing

## Manual step-by-step

### 1. Create kind cluster

```bash
kind create cluster
kubectl cluster-info --context kind-kind
```

### 2. Install Flagsmith

```bash
helm repo add flagsmith https://flagsmith.github.io/flagsmith-charts/
helm repo update
helm install flagsmith flagsmith/flagsmith -n flagsmith --create-namespace -f deploy/flagsmith-values.yaml
```

Wait until pods are ready (`kubectl -n flagsmith get pods`). Then (optional) set a proper `api.secretKey` in `deploy/flagsmith-values.yaml` (e.g. `openssl rand -hex 32`) and upgrade if you used the placeholder.

### 3a. Automatically populate Edge Proxy Secret from Flagsmith (recommended)

A sync Job can fetch one or two real environment key pairs from the Flagsmith Admin API and create/update the `edge-proxy-config` Secret. You only need to create an **Organisation API Token** in the UI once and store it in a Secret.

1. **Port-forward the frontend** and open the UI to create the token:
   ```bash
   kubectl -n flagsmith port-forward svc/flagsmith-frontend 8080:8080
   ```
   Open http://localhost:8080, log in (bootstrap creates a default org/project). Go to **Organisation** (sidebar) → **API Keys** → **Create Token**. Copy the token.

2. **Create the Organisation Token Secret**:
   ```bash
   cp deploy/flagsmith-organisation-token.example.yaml deploy/flagsmith-organisation-token.yaml
   # Edit and paste your token into ORGANISATION_API_TOKEN
   kubectl apply -f deploy/flagsmith-organisation-token.yaml -n flagsmith
   ```

3. **Run the sync Job** (it will create an environment if the project has none, then fetch up to 2 env key pairs and write `edge-proxy-config`):
   ```bash
   kubectl apply -f deploy/sync-edge-proxy-secret-job.yaml -n flagsmith
   kubectl -n flagsmith wait --for=condition=complete job/sync-edge-proxy-secret --timeout=120s
   ```

4. Then install Edge Proxy (step 5 below). To pick up the new keys immediately, restart Edge Proxy after the Job succeeds:
   ```bash
   kubectl -n flagsmith rollout restart deployment/edge-proxy
   ```

If you skip this and prefer to set keys manually, use step 3 (manual) below.

### 3. Create Edge Proxy Secret (manual alternative)

Create the Secret from the example and fill in your Flagsmith environment keys:

```bash
cp deploy/edge-proxy-secret.example.yaml deploy/edge-proxy-secret.yaml
# Edit deploy/edge-proxy-secret.yaml: replace YOUR_SERVER_SIDE_KEY and YOUR_CLIENT_SIDE_KEY
# Get keys from Flagsmith UI (see step 4)
kubectl apply -f deploy/edge-proxy-secret.yaml
```

If you don't have keys yet, you can apply the example with placeholders and update the Secret later; Edge Proxy will become ready once it can fetch environment data from Flagsmith.

### 4. Get environment keys from Flagsmith (if needed)

Port-forward the frontend and open the UI:

```bash
kubectl -n flagsmith port-forward svc/flagsmith-frontend 8080:8080
```

Open http://localhost:8080. Log in (bootstrap creates a default org/project). Create or open a project and environment, create a feature flag, then copy the **Server-side key** and **Client-side key** from the environment settings into `deploy/edge-proxy-secret.yaml`. Re-apply the Secret and restart Edge Proxy:

```bash
kubectl apply -f deploy/edge-proxy-secret.yaml
kubectl -n flagsmith rollout restart deployment/edge-proxy
```

### 5. Install Edge Proxy

```bash
helm install edge-proxy ./charts/edge-proxy -n flagsmith -f deploy/edge-proxy-values.yaml
```

### 6. Retrieve a feature flag via Edge Proxy

From the host (with port-forward):

```bash
kubectl -n flagsmith port-forward svc/edge-proxy 8000:8000
curl -H "X-Environment-Key: YOUR_CLIENT_SIDE_KEY" http://localhost:8000/api/v1/flags/
```

Or for identity-specific flags:

```bash
curl -H "X-Environment-Key: YOUR_CLIENT_SIDE_KEY" "http://localhost:8000/api/v1/identities/?identifier=user123"
```

Replace `YOUR_CLIENT_SIDE_KEY` with the client-side environment key from Flagsmith.

## Running the Pester tests

The `deploy.Tests.ps1` file is a [Pester](https://pester.dev/) test suite that performs a full end-to-end deployment and verifies that Edge Proxy returns the expected feature flags. It runs completely non-interactively — no manual token entry required.

```powershell
# Install Pester if needed
Install-Module -Name Pester -Force -SkipPublisherCheck

# Run the tests
Invoke-Pester ./deploy.Tests.ps1 -Output Detailed
```

The test suite will:
1. Verify prerequisites (`kind`, `kubectl`, `helm`)
2. Create a kind cluster
3. Install Flagsmith via Helm and wait for pods
4. Log in with the bootstrap admin credentials and create an Organisation API Token via the API
5. Create a feature flag in the default project/environment
6. Run the sync Job to populate the Edge Proxy secret
7. Install Edge Proxy and wait for it to be ready
8. Retrieve flags from Edge Proxy and assert the created flag is present

## File layout

| Path | Purpose |
|------|--------|
| `deploy/flagsmith-values.yaml` | Helm values for Flagsmith (secretKey, bootstrap) |
| `deploy/edge-proxy-values.yaml` | Helm values for Edge Proxy chart |
| `deploy/edge-proxy-secret.example.yaml` | Example Secret; copy to `edge-proxy-secret.yaml` and fill in keys (manual flow) |
| `deploy/edge-proxy-secret.yaml` | Gitignored; your real Edge Proxy Secret (manual flow) |
| `deploy/flagsmith-organisation-token.example.yaml` | Example Secret for Organisation API Token; copy to `flagsmith-organisation-token.yaml` for sync Job |
| `deploy/flagsmith-organisation-token.yaml` | Gitignored; your Organisation API Token (for sync Job) |
| `deploy/sync-edge-proxy-secret-job.yaml` | Job + RBAC + ConfigMap to fetch env key pairs from Flagsmith and create `edge-proxy-config` |
| `deploy/scripts/sync-edge-proxy-secret.py` | Script (used by Job via ConfigMap) to call Admin API and update Secret |
| `charts/edge-proxy/` | Custom Helm chart for Edge Proxy (Deployment, Service, config from Secret) |
| `deploy.ps1` | PowerShell script to automate the full deployment |
| `deploy.Tests.ps1` | Pester test suite for end-to-end deployment verification |

## Communication

- **Edge Proxy → Flagsmith API**: Uses `API_URL` from the Secret (default: `http://flagsmith-api.flagsmith.svc.cluster.local:8000/api/v1`).
- **You → Edge Proxy**: Use the Edge Proxy service (or port-forward) and send `X-Environment-Key: <client_side_key>` on each request.
