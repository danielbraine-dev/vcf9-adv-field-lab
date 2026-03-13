#!/usr/bin/env python3
import requests
import urllib3
import sys
import json
import time

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
    print("\nConstructing Zone-Aware VCF 9 EnableSpec Payload...")
    
    payload = {
        "zone": "z-wld-a", # Crucial for VCF 9 pre-zoned clusters
        "size_hint": "SMALL",
        "service_cidr": {
            "address": "10.96.0.0",
            "prefix": 23
        },
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

    print("Submitting Payload to vCenter Enable API...")
    url = f"https://{VC_HOST}/api/vcenter/namespace-management/clusters/{morefs['cluster']}?action=enable"
    headers = {
        "vmware-api-session-id": token,
        "Content-Type": "application/json"
    }
    
    res = requests.post(url, headers=headers, json=payload, verify=False)
    
    if res.status_code in [200, 201, 202, 204]:
        print("[+] SUCCESS! Supervisor deployment triggered!")
    elif res.status_code == 400 and "already enabled" in res.text.lower():
        print("[*] Supervisor is already enabled or currently deploying. Moving to poll...")
    else:
        print(f"[-] FAILED. HTTP {res.status_code}")
        try:
            print(json.dumps(res.json(), indent=2))
        except:
            print(res.text)
        sys.exit(1)

def wait_for_supervisor(token, cluster_id):
    print("\nPolling vCenter for Supervisor status (BLOCKING)...")
    url = f"https://{VC_HOST}/api/vcenter/namespace-management/clusters/{cluster_id}"
    headers = {"vmware-api-session-id": token}
    
    # 45-minute timeout (Supervisor deployment is slow)
    for i in range(45):
        res = requests.get(url, headers=headers, verify=False)
        if res.status_code == 200:
            status = res.json().get("config_status", "UNKNOWN")
            if status == "RUNNING":
                print("\n[+] Supervisor is UP and RUNNING!")
                return
            elif status == "ERROR":
                print("\n[-] Supervisor hit an ERROR state. Check vCenter UI.")
                sys.exit(1)
            else:
                print(f"[{i+1}/45] Status: {status}... waiting 60s")
        time.sleep(60)
    
    print("[-] Timeout waiting for Supervisor.")
    sys.exit(1)

if __name__ == "__main__":
    try:
        token = get_vcenter_session()
        morefs = lookup_morefs(token)
        deploy_supervisor(token, morefs)
        wait_for_supervisor(token, morefs['cluster'])
    except Exception as e:
        print(f"[-] Script Error: {e}")
        sys.exit(1)
