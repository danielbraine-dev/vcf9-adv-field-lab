#!/usr/bin/env python3
import requests
import urllib3
import time
import sys
import json

# Suppress insecure request warnings for the lab environment
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# Variables passed from bash
VCFA_URL = sys.argv[1]
NSX_HOST = sys.argv[2]
NSX_USER = sys.argv[3]
NSX_PASS = sys.argv[4]

# Hardcoded VCFA Provider Credentials
PROVIDER_USER = "admin"
PROVIDER_PASS = "VMware123!VMware123!"

def get_vcfa_token():
    print(f"Authenticating to VCFA ({VCFA_URL}) via legacy provider endpoint...")
    auth_url = f"{VCFA_URL}/cloudapi/1.0.0/sessions/provider"
    
    headers = {"Accept": "application/json;version=40.0"} 
    auth = (f"{PROVIDER_USER}@system", PROVIDER_PASS) 
    
    response = requests.post(auth_url, headers=headers, auth=auth, verify=False)
    if response.status_code != 200:
        print(f"[-] Auth failed: {response.status_code} {response.text}")
        sys.exit(1)
        
    token = response.headers.get("x-vmware-vcloud-access-token")
    if not token:
        raise ValueError("Failed to extract access token!")
    return token

def walk_and_update(obj):
    """
    Recursively traverses the JSON to safely update CIDRs and nested block names
    to avoid VCD database unique constraint violations.
    """
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k == "cidr" and v == "10.1.0.0/28":
                obj[k] = "10.1.0.0/26"
            elif k == "name" and isinstance(v, str) and "us-west" in v:
                obj[k] = v.replace("us-west", "us-east")
            elif isinstance(v, (dict, list)):
                walk_and_update(v)
    elif isinstance(obj, list):
        for item in obj:
            walk_and_update(item)

def update_vcfa_prereqs(token):
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json;version=9.0.0",
        "Content-Type": "application/json;version=9.0.0"
    }

    # 1. Update IP Space
    print("\nEnforcing VCFA IP Space state via /cloudapi/v1/ipSpaces...")
    res = requests.get(f"{VCFA_URL}/cloudapi/v1/ipSpaces", headers=headers, verify=False)
    
    if res.status_code == 200:
        spaces = res.json().get("values", res.json().get("content", []))
        for space in spaces:
            name = space.get("name", space.get("display_name", ""))
            if name in ["us-west-region-Default IP Space", "us-east-region-IP Space"]:
                print(f"Found IP Space: {name}. Updating...")
                
                if "name" in space: space["name"] = "us-east-region-IP Space"
                if "display_name" in space: space["display_name"] = "us-east-region-IP Space"
                
                walk_and_update(space)
                
                put_url = f"{VCFA_URL}/cloudapi/v1/ipSpaces/{space['id']}"
                put_res = requests.put(put_url, headers=headers, json=space, verify=False)
                
                if put_res.status_code in [200, 201, 202, 204]:
                    print("[+] VCFA IP Space enforced!")
                else:
                    print(f"[-] Failed to update IP Space. HTTP {put_res.status_code}: {put_res.text}")
    else:
        print(f"[-] Could not fetch VCFA IP Spaces. HTTP {res.status_code}: {res.text}")

    # 2. Update Provider Gateway
    print("\nEnforcing VCFA Provider Gateway state via /cloudapi/v1/providerGateways...")
    res = requests.get(f"{VCFA_URL}/cloudapi/v1/providerGateways", headers=headers, verify=False)
    
    if res.status_code == 200:
        pgs = res.json().get("values", res.json().get("content", []))
        for pg in pgs:
            name = pg.get("name", pg.get("display_name", ""))
            if name in ["us-west-region-Default Provider Gateway", "us-east-region-PG"]:
                print(f"Found Provider Gateway: {name}. Updating...")
                
                if "name" in pg: pg["name"] = "us-east-region-PG"
                if "display_name" in pg: pg["display_name"] = "us-east-region-PG"
                
                put_url = f"{VCFA_URL}/cloudapi/v1/providerGateways/{pg['id']}"
                put_res = requests.put(put_url, headers=headers, json=pg, verify=False)
                
                if put_res.status_code in [200, 201, 202, 204]:
                    print("[+] VCFA Provider Gateway enforced!")
                else:
                    print(f"[-] Failed to update Provider Gateway. HTTP {put_res.status_code}: {put_res.text}")
    else:
        print(f"[-] Could not fetch VCFA Provider Gateways. HTTP {res.status_code}: {res.text}")

def update_nsx_profile():
    # Bumped to 20 seconds to give VCFA a little extra time to sync the block
    print("\nWaiting 20 seconds for VCFA to push changes down to NSX-T...")
    time.sleep(20)
    
    nsx_auth = (NSX_USER, NSX_PASS)
    
    # FIX: Query ip-blocks instead of ip-spaces!
    print("Fetching synced IP Blocks from NSX-T...")
    res = requests.get(f"https://{NSX_HOST}/policy/api/v1/infra/ip-blocks", auth=nsx_auth, verify=False)
    nsx_block_path = None
    if res.status_code == 200:
        for item in res.json().get("results", []):
            name = item.get("display_name", "")
            # FIX: Use 'in' to ignore the random '-p2aif' suffix
            if "us-east-region" in name:
                nsx_block_path = item.get("path")
                print(f"[+] Found synced NSX-T IP Block: {name}")
                break
    
    if not nsx_block_path:
        print("[-] Failed to find the synced IP Block in NSX-T! VCFA sync may be delayed.")
        return
        
    print("Enforcing NSX-T VPC Profile state...")
    res = requests.get(f"https://{NSX_HOST}/policy/api/v1/orgs/default/projects/default/vpc-connectivity-profiles", auth=nsx_auth, verify=False)
    if res.status_code == 200:
        for profile in res.json().get("results", []):
            if profile.get("display_name") in ["Default VPC Connectivity Profile", "default"]:
                
                # FIX: Map it to external_ipv4_blocks since it's an IP Block, not an IP Space
                profile["external_ipv4_blocks"] = [nsx_block_path]
                
                put_url = f"https://{NSX_HOST}/policy/api/v1/orgs/default/projects/default/vpc-connectivity-profiles/{profile['id']}"
                put_res = requests.put(put_url, auth=nsx_auth, json=profile, verify=False)
                if put_res.status_code == 200:
                    print("[+] NSX-T VPC Profile successfully mapped to the new IP Block!")
                else:
                    print(f"[-] Failed to update NSX-T VPC Profile: {put_res.text}")
                break

if __name__ == "__main__":
    try:
        token = get_vcfa_token()
        update_vcfa_prereqs(token)
        update_nsx_profile()
    except Exception as e:
        print(f"[-] Python Script Error: {e}")
        sys.exit(1)
