#!/usr/bin/env python3
import requests
import urllib3
import sys
import json
import time

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

VC_HOST = sys.argv[1]
VC_USER = sys.argv[2]
VC_PASS = sys.argv[3]

CLUSTER_NAME = "cluster-wld01-01a"
POLICY_NAME = "vSAN Default Storage Policy"
MGMT_NET_NAME = "mgmt-vds01-wld01-01a"

def get_vcenter_session():
    print(f"Authenticating to vCenter ({VC_HOST})...")
    url = f"https://{VC_HOST}/api/session"
    res = requests.post(url, auth=(VC_USER, VC_PASS), verify=False)
    res.raise_for_status()
    return res.json()

def api_get(endpoint, token):
    url = f"https://{VC_HOST}{endpoint}"
    headers = {"vmware-api-session-id": token}
    res = requests.get(url, headers=headers, verify=False)
    return res.json() if res.status_code == 200 else None

def lookup_morefs(token):
    print("Dynamically looking up vCenter MoRefs...")
    morefs = {}
    
    resp = api_get("/api/vcenter/cluster", token)
    for c in resp:
        if c.get("name") == CLUSTER_NAME:
            morefs["cluster"] = c.get("cluster")
            
    resp = api_get("/api/vcenter/storage/policies", token)
    for p in resp:
        if p.get("name") == POLICY_NAME:
            morefs["policy"] = p.get("policy")
            
    resp = api_get("/api/vcenter/network", token)
    for n in resp:
        if n.get("name") == MGMT_NET_NAME:
            morefs["network"] = n.get("network")

    return morefs

def deploy_supervisor(token, morefs):
    print(f"\nTriggering V9 Enable on {CLUSTER_NAME}...")
    
    # Strictly following the 9.0 enable_on_compute_cluster_spec discovered
    payload = {
        "name": "wld01-supervisor",
        "control_plane": {
            "size": "SMALL",
            "storage_policy": morefs["policy"],
            "network": {
                "network": morefs["network"],
                "backing": {
                    "network": morefs["network"],
                    "backing": morefs["network"] # Union requirement for portgroup
                },
                "services": {
                    "dns": {
                        "servers": ["10.1.1.1"],
                        "search_domains": ["site-a.vcf.lab"]
                    },
                    "ntp": {
                        "servers": ["10.1.1.1"]
                    }
                },
                "ip_management": {
                    "dhcp_enabled": False,
                    "gateway_address": "10.1.1.1",
                    "ip_assignments": [
                        {
                            "assignee": "KUBERNETES",
                            "ranges": [
                                {
                                    "address": "10.1.1.85",
                                    "count": 11
                                }
                            ]
                        }
                    ]
                }
            }
        },
        "workloads": {
            "network": {
                "network_type": "NSX_VPC",
                "nsx_vpc": {
                    "nsx_project": "Default",
                    "vpc_connectivity_profile": "Default VPC Connectivity Profile",
                    "default_private_cidrs": [
                        {
                            "address": "172.16.201.0",
                            "prefix": 24
                        }
                    ]
                },
                "services": {
                    "dns": {
                        "servers": ["10.1.1.1"],
                        "search_domains": ["site-a.vcf.lab"]
                    }
                }
            },
            "storage": {
                "ephemeral_storage_policy": morefs["policy"],
                "image_storage_policy": morefs["policy"]
            }
        }
    }

    url = f"https://{VC_HOST}/api/vcenter/namespace-management/supervisors/{morefs['cluster']}?action=enable_on_compute_cluster"
    headers = {
        "vmware-api-session-id": token,
        "Content-Type": "application/json"
    }
    
    res = requests.post(url, headers=headers, json=payload, verify=False)
    
    if res.status_code in [200, 201, 202, 204]:
        print("[+] SUCCESS! VCF 9 Supervisor deployment triggered!")
    else:
        print(f"[-] FAILED. HTTP {res.status_code}")
        print(json.dumps(res.json(), indent=2))
        sys.exit(1)

def wait_for_supervisor(token, cluster_id):
    print("\nPolling status until RUNNING (15-20 mins)...")
    url = f"https://{VC_HOST}/api/vcenter/namespace-management/clusters/{cluster_id}"
    headers = {"vmware-api-session-id": token}
    for i in range(60):
        resp = requests.get(url, headers=headers, verify=False)
        if resp.status_code == 200:
            status = resp.json().get("config_status")
            print(f"[{i+1}/60] Status: {status}")
            if status == "RUNNING": return
            if status == "ERROR": sys.exit(1)
        time.sleep(60)

if __name__ == "__main__":
    try:
        token = get_vcenter_session()
        morefs = lookup_morefs(token)
        deploy_supervisor(token, morefs)
        wait_for_supervisor(token, morefs['cluster'])
    except Exception as e:
        print(f"[-] Script Error: {e}")
        sys.exit(1)
