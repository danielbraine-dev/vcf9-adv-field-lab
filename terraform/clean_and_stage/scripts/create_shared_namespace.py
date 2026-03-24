#!/usr/bin/env python3
import sys
import requests
import urllib3
import argparse
import json

# Suppress unverified HTTPS warnings for lab environments
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

def main():
    parser = argparse.ArgumentParser(description="Create a Supervisor Namespace with detailed logging.")
    parser.add_argument("--host", required=True, help="vCenter Hostname/IP")
    parser.add_argument("--user", required=True, help="vCenter Username")
    parser.add_argument("--password", required=True, help="vCenter Password")
    parser.add_argument("--namespace", default="shared-infrastructure", help="Namespace name")
    parser.add_argument("--storage-policy", default="vSAN Default Storage Policy", help="Storage Policy name")
    args = parser.parse_args()

    session = requests.Session()
    session.auth = (args.user, args.password)
    session.verify = False

    # 1. Authenticate
    print(f"[*] Authenticating to vCenter: {args.host}...")
    try:
        res = session.post(f"https://{args.host}/api/session")
        res.raise_for_status()
        session.headers.update({"vmware-api-session-id": res.json()})
        print("[+] Authentication successful.")
    except requests.exceptions.RequestException as e:
        print(f"[-] Auth failed: {e}")
        if e.response is not None: print(e.response.text)
        sys.exit(1)

    # 2. Check existing namespaces
    print(f"[*] Checking if namespace '{args.namespace}' exists...")
    try:
        res = session.get(f"https://{args.host}/api/vcenter/namespaces/instances")
        res.raise_for_status()
        existing = [ns["namespace"] for ns in res.json()]
        if args.namespace in existing:
            print(f"[+] Namespace '{args.namespace}' already exists. Skipping creation.")
            sys.exit(0)
    except requests.exceptions.RequestException as e:
        print(f"[-] Failed to fetch namespaces: {e}")
        if e.response is not None: print(e.response.text)
        sys.exit(1)

    # 3. Get Supervisor Cluster
    print("[*] Fetching Supervisor-enabled Clusters...")
    try:
        # We exclusively query namespace-management to ensure WCP is enabled on the cluster
        res = session.get(f"https://{args.host}/api/vcenter/namespace-management/clusters")
        res.raise_for_status()
        clusters = res.json()
        if not clusters:
            print("[-] No Supervisor-enabled clusters found!")
            sys.exit(1)
        
        cluster_id = clusters[0]["cluster"]
        print(f"[+] Found Supervisor Cluster ID: {cluster_id}")
    except requests.exceptions.RequestException as e:
        print(f"[-] Failed to fetch WCP clusters: {e}")
        if e.response is not None: print(e.response.text)
        sys.exit(1)

    # 4. Get Storage Policy
    print(f"[*] Fetching Storage Policy '{args.storage_policy}'...")
    try:
        res = session.get(f"https://{args.host}/api/vcenter/storage/policies")
        res.raise_for_status()
        policies = res.json()
        policy_id = next((p["policy"] for p in policies if p["name"] == args.storage_policy), None)
        
        if not policy_id:
            print(f"[-] Storage policy '{args.storage_policy}' not found!")
            sys.exit(1)
            
        print(f"[+] Found Storage Policy ID: {policy_id}")
    except requests.exceptions.RequestException as e:
        print(f"[-] Failed to fetch storage policies: {e}")
        if e.response is not None: print(e.response.text)
        sys.exit(1)

    # 5. Create Namespace
    print(f"[*] Creating namespace '{args.namespace}'...")
    payload = {
        "namespace": args.namespace,
        "cluster": cluster_id,
        "storage_specs": [{"policy": policy_id}]
    }
    
    try:
        res = session.post(f"https://{args.host}/api/vcenter/namespaces/instances", json=payload)
        res.raise_for_status()
        print(f"[+] Successfully created Supervisor Namespace: {args.namespace}")
    except requests.exceptions.RequestException as e:
        print(f"[-] Namespace creation failed! HTTP {e.response.status_code if e.response is not None else 'Unknown'}")
        if e.response is not None:
            print("\n--- vCenter API Error Response ---")
            try:
                print(json.dumps(e.response.json(), indent=2))
            except:
                print(e.response.text)
            print("----------------------------------\n")
        sys.exit(1)

if __name__ == "__main__":
    main()
