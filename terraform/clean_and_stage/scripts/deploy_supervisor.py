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
    
    clusters = api_get("/api/vcenter/cluster", token)
    for c in clusters:
        if c.get("name") == CLUSTER_NAME:
            morefs["cluster"] = c.get("cluster")
            
    policies = api_get("/api/vcenter/storage/policies", token)
    for p in policies:
        if p.get("name") == POLICY_NAME:
            morefs["policy"] = p.get("policy")
            
    networks = api_get("/api/vcenter/network", token)
    for n in networks:
        if n.get("name") == MGMT_NET_NAME:
            morefs["network"] = n.get("network")
            
    if not all(k in morefs for k in ["cluster", "policy", "network"]):
        print(f"[-] Failed to resolve all MoRefs! Found: {morefs}")
        sys.exit(1)
        
    return morefs

def deploy_supervisor(token, morefs):
    print("\nConstructing VCF 9 V2 Supervisor Payload...")
    
    # We are now using the V2 structure to support pre-zoned clusters
    payload = {
        "cluster": morefs["cluster"],
        "name": "wld01-sup",
        
        "control_plane": {
            "size_hint": "SMALL",
            "network_provider": "NSXT_VPC", 
            "master_management_network": {
                "network": morefs["network"],
                "mode": "STATICRANGE",
                "address_range": {
                    "starting_address": "10.1.1.85",
                    "address_count": 11,
                    "subnet_mask": "255.255.255.0",
                    "gateway": "10.1.1.1"
                }
            },
            "master_DNS_names": ["10.1.1.1"],
            "master_DNS_search_domains": ["site-a.vcf.lab"],
            "master_NTP_servers": ["10.1.1.1"],
            "worker_DNS": ["10.1.1.1"],
            "master_storage_policy": morefs["policy"],
            "ephemeral_storage_policy": morefs["policy"],
            "image_storage": {
                "storage_policy": morefs["policy"]
            }
        },
        
        "workloads": {
            "service_cidr": {
                "address": "10.96.0.0",
                "prefix": 23
            },
            "nsxt_vpc_network_spec": {
                "project": "Default",
                "vpc_connectivity_profile": "Default VPC Connectivity Profile",
                "private_cidrs": [{
                    "address": "172.16.201.0",
                    "prefix": 24
                }],
                "dns_servers": ["10.1.1.1"],
                "ntp_servers": ["10.1.1.1"]
            }
        }
    }

    print("Submitting Payload to Modern V2 vCenter API...")
    # The new endpoint designed specifically for VCF 9 and Zoned Architectures
    url = f"https://{VC_HOST}/api/vcenter/namespace-management/supervisors"
    headers = {
        "vmware-api-session-id": token,
        "Content-Type": "application/json"
    }
    
    res = requests.post(url, headers=headers, json=payload, verify=False)
    
    if res.status_code in [200, 201, 202, 204]:
        print("[+] SUCCESS! Supervisor deployment triggered!")
        return res.json() if res.text else None
    elif res.status_code == 400 and "already enabled" in res.text.lower():
        print("[*] Supervisor is already enabled or currently deploying.")
        return None
    else:
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
