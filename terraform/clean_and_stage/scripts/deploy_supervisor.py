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
ZONE_NAME = "z-wld-a"

def api_get(endpoint, token):
    url = f"https://{VC_HOST}{endpoint}"
    res = requests.get(url, headers={"vmware-api-session-id": token}, verify=False)
    if res.status_code != 200:
        return None
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
    
    # 1. Cluster
    clusters = api_get("/api/vcenter/cluster", token)
    for c in clusters:
        if c.get("name") == CLUSTER_NAME:
            morefs["cluster"] = c.get("cluster")
            
    # 2. Storage Policy
    policies = api_get("/api/vcenter/storage/policies", token)
    for p in policies:
        if p.get("name") == POLICY_NAME:
            morefs["policy"] = p.get("policy")
            
    # 3. Network
    networks = api_get("/api/vcenter/network", token)
    for n in networks:
        if n.get("name") == MGMT_NET_NAME:
            morefs["network"] = n.get("network")

    # 4. Deep-Search Zone (VCF 9 hidden IDs)
    print(f"Performing Deep-Search for Zone MoRef: {ZONE_NAME}")
    
    # Try the hidden internal zone registry
    zone_data = api_get("/api/vcenter/namespace-management/zones", token)
    if not zone_data:
        # Try finding it via the cluster's own association metadata
        cluster_info = api_get(f"/api/vcenter/namespace-management/clusters/{morefs['cluster']}", token)
        if cluster_info and "zone" in cluster_info:
            morefs["zone"] = cluster_info["zone"]
            print(f"[+] Discovered Zone ID from Cluster Metadata: {morefs['zone']}")

    if "zone" not in morefs:
        # Final stand: Search global folders/tags if needed, 
        # but usually VCF 9 expects the zone ID to match the name if it's not a MoRef.
        # Since 'z-wld-a' failed, let's try to query the available zones list specifically.
        print("[!] Still searching... trying vAPI service dump.")
        # Some VCF 9 builds use this specific lookup
        zone_list = api_get("/api/vcenter/consumption-domains/zones", token)
        if zone_list:
            for z in zone_list.get('zones', []):
                if z.get('name') == ZONE_NAME:
                    morefs["zone"] = z.get('zone')
                    break

    if "zone" not in morefs:
        print(f"[-] Could not find a MoRef for '{ZONE_NAME}'. Attempting to proceed without the zone key to see if vCenter auto-resolves...")
        # If the cluster is 'already associated', sometimes OMITTING the zone 
        # is actually the correct API move because the association is implicit.
        morefs["zone"] = None
            
    if not all(k in morefs for k in ["cluster", "policy", "network"]):
        print(f"[-] Missing basic MoRefs! Current state: {morefs}")
        sys.exit(1)
        
    return morefs

def deploy_supervisor(token, morefs):
    print(f"\nTriggering Supervisor enable (Cluster: {morefs['cluster']})...")
    
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

    # If we found a specific Zone MoRef, add it.
    if morefs.get("zone"):
        payload["zone"] = morefs["zone"]

    url = f"https://{VC_HOST}/api/vcenter/namespace-management/clusters/{morefs['cluster']}?action=enable"
    headers = {"vmware-api-session-id": token, "Content-Type": "application/json"}
    
    res = requests.post(url, headers=headers, json=payload, verify=False)
    
    if res.status_code in [200, 201, 202, 204]:
        print("[+] SUCCESS! Supervisor deployment triggered!")
    else:
        print(f"[-] FAILED. HTTP {res.status_code}")
        print(res.text)
        sys.exit(1)

# ... [wait_for_supervisor remains the same] ...

def wait_for_supervisor(token, cluster_id):
    print("\nPolling for RUNNING status...")
    url = f"https://{VC_HOST}/api/vcenter/namespace-management/clusters/{cluster_id}"
    headers = {"vmware-api-session-id": token}
    
    for i in range(60): 
        res = requests.get(url, headers=headers, verify=False)
        if res.status_code == 200:
            status = res.json().get("config_status")
            print(f"[{i+1}/60] Current Status: {status}")
            if status == "RUNNING":
                print("[+] Supervisor is READY!")
                return
            if status == "ERROR":
                print("[-] Deployment failed!")
                sys.exit(1)
        time.sleep(60)

if __name__ == "__main__":
    try:
        sess_token = get_vcenter_session()
        data = lookup_morefs(sess_token)
        deploy_supervisor(sess_token, data)
        wait_for_supervisor(sess_token, data['cluster'])
    except Exception as e:
        print(f"[-] Script Error: {e}")
        sys.exit(1)
