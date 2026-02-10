#!/usr/bin/env python3
"""
Fetch 1-2 environment key pairs from Flagsmith Admin API and create/update
the edge-proxy-config Secret. Requires ORGANISATION_API_TOKEN and
FLAGSMITH_API_URL in the environment; optional NAMESPACE (default: flagsmith).
"""
import os
import sys
import time
import json
import urllib.request
import urllib.error
import ssl

# In-cluster: load service account token and ca. No extra deps for HTTP.
def wait_for_api(base_url: str, token: str, max_attempts: int = 30) -> bool:
    url = f"{base_url.rstrip('/')}/api/v1/projects/"
    req = urllib.request.Request(url, headers={"Authorization": f"Api-Key {token}"})
    for i in range(max_attempts):
        try:
            with urllib.request.urlopen(req, timeout=5, context=ssl.create_default_context()) as r:
                if r.status in (200, 401):  # 401 = API up, token might be wrong
                    return True
        except urllib.error.HTTPError as e:
            if e.code == 401:
                return True
            if e.code >= 500 or e.code == 404:
                pass
        except OSError:
            pass
        time.sleep(2)
    return False

def api_get(base_url: str, path: str, token: str) -> dict:
    url = f"{base_url.rstrip('/')}{path}"
    req = urllib.request.Request(url, headers={"Authorization": f"Api-Key {token}"})
    with urllib.request.urlopen(req, timeout=15, context=ssl.create_default_context()) as r:
        return json.loads(r.read().decode())

def api_post(base_url: str, path: str, token: str, data: dict) -> dict:
    url = f"{base_url.rstrip('/')}{path}"
    body = json.dumps(data).encode()
    req = urllib.request.Request(
        url,
        data=body,
        method="POST",
        headers={
            "Authorization": f"Api-Key {token}",
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=15, context=ssl.create_default_context()) as r:
        return json.loads(r.read().decode())

def main() -> int:
    token = os.environ.get("ORGANISATION_API_TOKEN", "").strip()
    base_url = (os.environ.get("FLAGSMITH_API_URL") or "").strip()
    namespace = os.environ.get("NAMESPACE", "flagsmith")
    max_pairs = int(os.environ.get("MAX_ENV_PAIRS", "2"))

    if not token:
        print("ORGANISATION_API_TOKEN not set; skipping sync (create flagsmith-organisation-token Secret to enable).", file=sys.stderr)
        return 0
    if not base_url:
        print("FLAGSMITH_API_URL not set.", file=sys.stderr)
        return 1

    api_url_for_edge = f"{base_url.rstrip('/')}/api/v1"

    print("Waiting for Flagsmith API...")
    if not wait_for_api(base_url, token):
        print("Flagsmith API not reachable.", file=sys.stderr)
        return 1
    print("Flagsmith API is up.")

    try:
        projects = api_get(base_url, "/api/v1/projects/", token)
    except urllib.error.HTTPError as e:
        print(f"Failed to list projects: {e.code} {e.reason}", file=sys.stderr)
        return 1
    if isinstance(projects, list):
        project_list = projects
    elif isinstance(projects, dict) and isinstance(projects.get("results"), list):
        project_list = projects["results"]
    else:
        project_list = []
    if not project_list:
        print("No projects found; create one in the UI or use bootstrap.", file=sys.stderr)
        return 1
    project_id = project_list[0]["id"]

    try:
        envs_resp = api_get(base_url, f"/api/v1/environments/?project={project_id}", token)
    except urllib.error.HTTPError as e:
        print(f"Failed to list environments: {e.code} {e.reason}", file=sys.stderr)
        return 1
    if isinstance(envs_resp, list):
        envs = envs_resp
    elif isinstance(envs_resp, dict) and isinstance(envs_resp.get("results"), list):
        envs = envs_resp["results"]
    else:
        envs = []
    if not envs:
        try:
            api_post(base_url, "/api/v1/environments/", token, {"name": "Development", "project": project_id})
            envs_resp = api_get(base_url, f"/api/v1/environments/?project={project_id}", token)
            if isinstance(envs_resp, list):
                envs = envs_resp
            elif isinstance(envs_resp, dict) and isinstance(envs_resp.get("results"), list):
                envs = envs_resp["results"]
            else:
                envs = []
        except Exception as e:
            print(f"Could not create default environment: {e}", file=sys.stderr)
            return 1
    if not envs:
        print("No environments found.", file=sys.stderr)
        return 1

    pairs = []
    for env in envs[:max_pairs]:
        client_key = env.get("api_key")
        if not client_key:
            continue
        server_key = None
        try:
            keys_resp = api_get(base_url, f"/api/v1/environments/{client_key}/api-keys/", token)
            if isinstance(keys_resp, list):
                key_list = keys_resp
            elif isinstance(keys_resp, dict) and isinstance(keys_resp.get("results"), list):
                key_list = keys_resp["results"]
            elif isinstance(keys_resp, dict) and keys_resp.get("key"):
                key_list = [keys_resp]
            else:
                key_list = []
            for k in key_list:
                if k.get("active", True) and k.get("key"):
                    server_key = k["key"]
                    break
            if not server_key:
                created = api_post(base_url, f"/api/v1/environments/{client_key}/api-keys/", token, {"name": "auto-created"})
                if created.get("key"):
                    server_key = created["key"]
        except Exception:
            pass
        if server_key:
            pairs.append({"server_side_key": server_key, "client_side_key": client_key})

    if not pairs:
        print("No environment key pairs collected.", file=sys.stderr)
        return 1

    env_pairs_json = json.dumps(pairs)
    secret_data = {
        "API_URL": api_url_for_edge,
        "ENVIRONMENT_KEY_PAIRS": env_pairs_json,
    }

    try:
        from kubernetes import client, config
        config.load_incluster_config()
        v1 = client.CoreV1Api()
        from kubernetes.client.rest import ApiException
        body = client.V1Secret(
            metadata=client.V1ObjectMeta(name="edge-proxy-config", namespace=namespace),
            type="Opaque",
            string_data=secret_data,
        )
        try:
            v1.replace_namespaced_secret("edge-proxy-config", namespace, body)
            print("Updated Secret edge-proxy-config.")
        except ApiException as e:
            if e.status == 404:
                v1.create_namespaced_secret(namespace, body)
                print("Created Secret edge-proxy-config.")
            else:
                raise
    except ImportError:
        print("kubernetes module not found; writing Secret manifest to stdout.", file=sys.stderr)
        import base64
        out = {
            "apiVersion": "v1",
            "kind": "Secret",
            "metadata": {"name": "edge-proxy-config", "namespace": namespace},
            "type": "Opaque",
            "data": {
                k: base64.b64encode(v.encode()).decode() for k, v in secret_data.items()
            },
        }
        print("---")
        print(json.dumps(out, indent=2))
        return 0
    except Exception as e:
        print(f"Failed to create/update Secret: {e}", file=sys.stderr)
        return 1

    return 0

if __name__ == "__main__":
    sys.exit(main())
