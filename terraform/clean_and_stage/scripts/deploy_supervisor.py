#!/usr/bin/env python3
import requests
import urllib3
import sys
import json
import time
import ssl
import socket

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

VC_HOST = sys.argv[1]
VC_USER = sys.argv[2]
VC_PASS = sys.argv[3]

CLUSTER_NAME = "cluster-wld01-01a"
POLICY_NAME = "vSAN Default Storage Policy"
MGMT_NET_NAME = "mgmt-vds01-wld01-01a"

def get_avi_cert(host, port=443):
    print(f"Dynamically fetching SSL certificate from Avi Controller ({host})...")
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    try:
        with socket.create_connection((host, port), timeout=5) as sock:
            with context.wrap_socket(sock, server_hostname=host) as ssock:
                cert_der = ssock.getpeercert(binary_form=True)
                return ssl.DER_cert_to_PEM_cert(cert_der)
    except Exception as e:
        print(f"[-] Failed to fetch Avi cert: {e}")
        sys.exit(1)

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
    
    # Dynamically fetch the cert again just to be safe
    avi_cert = get_avi_cert("10.1.1.200")
    
    payload = {
        "name": "wld01-supervisor",
        "zone": "z-wld-a",
        "control_plane": {
            "count": 1,
            "network": {
                "network": morefs["network"],
                "backing": {
                    "backing": "NETWORK",
                    "network": morefs["network"]
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
                    "gateway_address": "10.1.1.1/24",
                    "ip_assignments": [
                        {
                            "assignee": "NODE",
                            "ranges": [
                                {
                                    "address": "10.1.1.85",
                                    "count": 10
                                }
                            ]
                        }
                    ]
                }
            },
            "size": "SMALL",
            "storage_policy": morefs["policy"]
        },
        "workloads": {
            "network": {
                "network_type": "NSX_VPC",
                "nsx_vpc": {
                    "nsx_project": "/orgs/default/projects/default",
                    "default_private_cidrs": [
                        {
                            "address": "172.16.201.0",
                            "prefix": 24
                        }
                    ]
                },
                "ip_management": {
                    "dhcp_enabled": False,
                "ip_assignments": [
                        {
                            "assignee": "SERVICE",
                            "ranges": [{"address": "10.96.0.0", "count": 512}]
                        }
                    ]
                }
            },
            "edge": {
                "provider": "NSX_REGISTERED_AVI",
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
