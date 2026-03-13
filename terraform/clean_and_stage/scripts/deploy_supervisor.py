#!/usr/bin/env python3
import requests
import urllib3
import sys
import json

# Suppress insecure request warnings for the lab environment
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

VC_HOST = sys.argv[1]
VC_USER = sys.argv[2]
VC_PASS = sys.argv[3]

# Lab Specific Names
CLUSTER_NAME = "cluster-wld01-01a"
POLICY_NAME = "vSAN Default Storage Policy"
MGMT_NET_NAME = "mgmt-vds01-wld01-01a"

def api_get(endpoint, token):
    url = f"https://{VC_HOST}{endpoint}"
    res = requests.get(url, headers={"vmware-api-session-id": token}, verify=False)
    res.raise_for_status()
    return res.json()

def get_vcenter_session():
    print(f"Authenticating to vCenter ({VC_HOST})...")
    url = f"https://{VC_HOST}/api/session"
    res = requests.post(url, auth=(VC_USER, VC_PASS), verify=False)
    res.raise_for_status()
    return res.json()

def lookup_morefs(token):
    print("Dynamically looking up vCenter MoRefs...")
    morefs = {}
    
    # 1. Get Cluster ID
    clusters = api_get("/api/vcenter/cluster", token)
    for c in clusters:
        if c.get("name") == CLUSTER_NAME:
            morefs["cluster"] = c.get("cluster")
            
    # 2. Get Storage Policy ID
    policies = api_get("/api/vcenter/storage/policies", token)
    for p in policies:
        if p.get("name") == POLICY_NAME:
            morefs["policy"] = p.get("policy")
            
    # 3. Get Network ID
    networks = api_get("/api/vcenter/network", token)
    for n in networks:
        if n.get("name") == MGMT_NET_NAME:
            morefs["network"] = n.get("network")
            
    if not all(k in morefs for k in ["cluster", "policy", "network"]):
        print(f"[-] Failed to resolve all MoRefs! Found: {morefs}")
        sys.exit(1)
        
    print(f"[+] Lookups Successful: {morefs}")
    return morefs

def deploy_supervisor(token, morefs):
    print("\nConstructing VCF 9 VPC Supervisor Payload...")
    
    # Translated 1:1 from the vsphere_supervisor_v2 schema
    payload = {
        "name": "wld01-sup",
        "control_plane": {
            "size": "SMALL",
            "count": 3,
            "storage_policy": morefs["policy"],
            "network": {
                "backing": {
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
                    "ip_assignment": [{
                        "assignee": "NODE",
                        "range": {
                            "address": "10.1.1.85",
                            "count": 11
                        }
                    }]
                }
            }
        },
        "workloads": {
            "network": {
                "nsx_vpc": {},
                "nsx_project": "default",
                "vpc_connectivity_profile": "default",
                "default_private_cidr": {
                    "address": "172.16.201.0",
                    "prefix": 24
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
                    "ip_assignment": [
                        {
                            "assignee": "SERVICE",
                            "range": {
                                "address": "10.96.0.0",
                                "count": 512
                            }
                        },
                        {
                            "assignee": "EGRESS",
                            "range": {
                                "address": "172.16.101.0",
                                "count": 256
                            }
                        }
                    ]
                }
            },
            "edge": {
                "provider": "NSX"
            },
            "kube_api_server_options": {
                "security": {
                    "certificate_dns_names": ["site-a.vcf.lab"]
                }
            }
        }
    }

    print("Submitting Payload to vCenter API...")
    url = f"https://{VC_HOST}/api/vcenter/namespace-management/clusters/{morefs['cluster']}?action=enable"
    headers = {
        "vmware-api-session-id": token,
        "Content-Type": "application/json"
    }
    
    res = requests.post(url, headers=headers, json=payload, verify=False)
    
    if res.status_code in [200, 201, 202, 204]:
        print("[+] SUCCESS! Supervisor deployment has been triggered natively in vCenter!")
    else:
        # This will catch typos or missing keys instantly without deploying anything
        print(f"[-] FAILED. HTTP {res.status_code}")
        print(json.dumps(res.json(), indent=2))
        sys.exit(1)

if __name__ == "__main__":
    try:
        token = get_vcenter_session()
        morefs = lookup_morefs(token)
        deploy_supervisor(token, morefs)
    except Exception as e:
        print(f"[-] Python Script Error: {e}")
        sys.exit(1)
