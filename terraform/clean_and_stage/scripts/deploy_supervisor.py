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
    print("Dynamically looking up basic vCenter MoRefs...")
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

    if not all(k in morefs for k in ["cluster", "policy", "network"]):
        print(f"[-] Missing MoRefs! Found: {morefs}")
        sys.exit(1)
        
    print(f"[+] Found Core IDs: {morefs}")
    return morefs

def deploy_supervisor(token, morefs):
    print(f"\nTriggering V9 Compute Cluster Enable (Cluster: {morefs['cluster']})...")
    
    # We omit the zone key entirely because enable_on_compute_cluster inherits it natively
    payload = {
        "size_hint": "SMALL",
        "service_cidr": {"address": "10.96.0.0", "prefix": 23},
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
        "image_storage": {"storage_policy": morefs["policy"]},
        "nsxt_vpc_network_spec": {
            "project": "Default",
            "vpc_connectivity_profile": "Default VPC Connectivity Profile",
            "private_cidrs": [{"address": "172.16.201.0", "prefix": 24}],
            "dns_servers": ["10.1.1.1"],
            "ntp_servers": ["10.1.1.1"]
        }
    }

    # THE FIX: Hitting the V9 API endpoint discovered in the docs!
    url = f"https://{VC_HOST}/api/vcenter/namespace-management/supervisors/{morefs['cluster']}?action=enable_on_compute_cluster"
    headers = {"vmware-api-session-id": token, "Content-Type": "application/json"}
    
    res = requests.post(url, headers=headers, json=payload, verify=False)
    
    if res.status_code in [200, 201, 202, 204]:
        print("[+] SUCCESS! V9 Supervisor deployment triggered!")
    else:
        print(f"[-] FAILED. HTTP {res.status_code}")
        print(res.text)
        sys.exit(1)

def wait_for_supervisor(token, cluster_id):
    print("\nPolling status until RUNNING (this takes 15-20 mins)...")
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
    token = get_vcenter_session()
    ids = lookup_morefs(token)
    deploy_supervisor(token, ids)
    wait_for_supervisor(token, ids['cluster'])
