# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Deploys **Flagsmith** (feature flag service) and its **Edge Proxy** to a local Kubernetes cluster using **kind** and **Helm**. A PowerShell automation script (`deploy.ps1`) handles the full lifecycle, and a Pester test suite (`deploy.Tests.ps1`) performs end-to-end verification.

## Key Commands

```powershell
# Full deployment (creates kind cluster, installs Flagsmith + Edge Proxy)
./deploy.ps1

# Skip cluster creation
./deploy.ps1 -SkipCluster

# Manual key entry instead of sync Job
./deploy.ps1 -ManualKeys -ServerSideKey "ser.xxx" -ClientSideKey "xxx"

# Non-interactive (provide token directly)
./deploy.ps1 -OrganisationApiToken "your-token"

# Run Pester tests (full e2e — creates cluster, deploys, asserts flags)
Invoke-Pester ./deploy.Tests.ps1 -Output Detailed
```

Prerequisites: `kind`, `kubectl`, `helm`, `pwsh` (PowerShell).

## Architecture

**Two deployment paths for the Edge Proxy secret:**
1. **Sync Job** (default): A Kubernetes Job (`deploy/sync-edge-proxy-secret-job.yaml`) runs a Python script that calls the Flagsmith Admin API to fetch environment key pairs, then creates/updates the `edge-proxy-config` Secret via the Kubernetes API. Requires an Organisation API Token stored in a separate Secret.
2. **Manual**: User provides server-side and client-side keys directly; the script templates `deploy/edge-proxy-secret.example.yaml` and applies it.

**Helm charts:**
- Flagsmith itself uses the upstream `flagsmith/flagsmith` chart with values from `deploy/flagsmith-values.yaml` (bootstrap enabled with default admin `admin@example.com`).
- Edge Proxy uses a custom local chart at `charts/edge-proxy/` — a simple Deployment + Service that reads config from the `edge-proxy-config` Secret.

**Sync Job internals** (`deploy/sync-edge-proxy-secret-job.yaml`): Contains a ConfigMap with the Python script inline, plus ServiceAccount/Role/RoleBinding for Secret CRUD. Runs in a `python:3.11-alpine` container, installs the `kubernetes` pip package at runtime.

## Gitignored Secrets

`deploy/edge-proxy-secret.yaml` and `deploy/flagsmith-organisation-token.yaml` are gitignored. The `.example.yaml` counterparts are committed as templates.

## Testing Notes

The Pester tests are **sequential and stateful** — each `It` block depends on state from prior blocks (e.g., `$script:OrgToken`, `$script:ClientKey`). The test suite bootstraps admin credentials via Django `manage.py shell`, creates an org token via the API, creates a feature flag, runs the sync Job, and asserts Edge Proxy returns the flag. Tests use non-standard ports (18080 for API, 18000 for Edge Proxy) to avoid conflicts.
