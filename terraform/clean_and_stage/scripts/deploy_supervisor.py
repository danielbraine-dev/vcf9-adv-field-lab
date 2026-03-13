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

    # 4. Zone Discovery
    print(f"Searching for Zone: {ZONE_NAME}")
    search_paths = [
        "/api/vcenter/namespace-management/zones",
        "/api/vcenter/consumption-domains/zones",
        "/api/vcenter/topology/zones"
    ]
    
    found_zones_log = []
    for path in search_paths:
        resp = api_get(path, token)
        if resp:
            # Handle different list structures (some wrap in 'zones', some are raw lists)
            z_list = resp.get("zones", resp) if isinstance(resp, dict) else resp
            if isinstance(z_list, list):
                for z in z_list:
                    if isinstance(z, dict):
                        z_name = z.get("name")
                        z_id = z.get("zone")
                        found_zones_log.append(f"{z_name} ({z_id}) at {path}")
                        if z_name == ZONE_NAME:
                            morefs["zone"] = z_id
                            print(f"[+] Found Zone ID: {z_id} via {path}")
                            break
        if "zone" in morefs: break

    if "zone" not in morefs:
        print(f"[-] Could not find zone '{ZONE_NAME}'.")
        print(f"[*] Discovery Log - Zones seen: {found_zones_log if found_zones_log else 'None'}")
        # FALLBACK: If we know the name and the cluster is associated, 
        # sometimes the name IS the ID in the enable spec. Let's try it as a last resort.
        print("[!] Falling back to using the Zone Name as the ID...")
        morefs["zone"] = ZONE_NAME
            
    if not all(k in morefs for k in ["cluster", "policy", "network", "zone"]):
        print(f"[-] Missing MoRefs! Current state: {morefs}")
        sys.exit(1)
        
    return morefs

def deploy_supervisor(token, morefs):
    print(f"\nTriggering Supervisor enable (Cluster: {morefs['cluster']}, Zone: {morefs['zone']})...")
    
    payload = {
        "zone": morefs["zone"],
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

    url = f"https://{VC_HOST}/api/vcenter/namespace-management/clusters/{morefs['cluster']}?action=enable"
    headers = {"vmware-api-session-id": token, "Content-Type": "application/json"}
    
    res = requests.post(url, headers=headers, json=payload, verify=False)
    
    if res.status_code in [200, 201, 202, 204]:
        print("[+] SUCCESS! Supervisor deployment triggered!")
    else:
        print(f"[-] FAILED. HTTP {res.status_code}")
        print(res.text)
        sys.exit(1)

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
