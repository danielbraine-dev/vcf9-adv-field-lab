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

# Hardcoded VCFA Provider Credentials (from your teardown script)
PROVIDER_USER = "admin"
PROVIDER_PASS = "VMware123!VMware123!"

def get_vcfa_token():
    print(f"Authenticating to VCFA ({VCFA_URL}) using known-good provider auth...")
    auth_url = f"{VCFA_URL}/cloudapi/1.0.0/sessions/provider"
    headers = {"Accept": "application/json;version=40.0"} 
    auth = (f"{PROVIDER_USER}@system", PROVIDER_PASS) 
    
    response = requests.post(auth_url, headers=headers, auth=auth, verify=False)
    response.raise_for_status()
    
    token = response.headers.get("x-vmware-vcloud-access-token")
    if not token:
        raise ValueError("Failed to extract x-vmware-vcloud-access-token!")
    return token

def update_vcfa_prereqs(token):
    # Using the standard Bearer auth, but adding the x-vmware header just in case VCF 9 prefers it
    headers = {
        "Authorization": f"Bearer {token}",
        "x-vmware-vcloud-access-token": token,
        "Accept": "application/json",
        "Content-Type": "application/json"
    }

    # 1. Update IP Space (Using the exact endpoint from your screenshot)
    print("\nEnforcing VCFA IP Space state via /v1/ipSpaces...")
    res = requests.get(f"{VCFA_URL}/v1/ipSpaces", headers=headers, verify=False)
    
    if res.status_code == 200:
        data = res.json()
        # Handle different potential array wrappers gracefully
        spaces = data.get("values", data.get("content", data if isinstance(data, list) else []))
        
        for space in spaces:
            name = space.get("name") or space.get("display_name", "")
            if name in ["us-west-region-Default IP Space", "us-east-region-IP Space"]:
                print(f"Found IP Space: {name}. Updating...")
                
                # Update name fields
                if "name" in space: space["name"] = "us-east-region-IP Space"
                if "display_name" in space: space["display_name"] = "us-east-region-IP Space"
                
                # Update CIDR via generic replacement to handle nested schemas
                space_str = json.dumps(space)
                space_str = space_str.replace("10.1.0.0/28", "10.1.0.0/26")
                updated_space = json.loads(space_str)
                
                space_id = space.get("id")
                put_url = f"{VCFA_URL}/v1/ipSpaces/{space_id}"
                put_res = requests.put(put_url, headers=headers, json=updated_space, verify=False)
                
                if put_res.status_code in [200, 201, 202, 204]:
                    print("[+] VCFA IP Space enforced!")
                else:
                    print(f"[-] Failed to update IP Space. HTTP {put_res.status_code}: {put_res.text}")
    else:
        print(f"[-] Could not fetch VCFA IP Spaces. HTTP {res.status_code}: {res.text}")

    # 2. Update Provider Gateway (Using the exact endpoint from your screenshot)
    print("\nEnforcing VCFA Provider Gateway state via /v1/providerGateways...")
    res = requests.get(f"{VCFA_URL}/v1/providerGateways", headers=headers, verify=False)
    
    if res.status_code == 200:
        data = res.json()
        pgs = data.get("values", data.get("content", data if isinstance(data, list) else []))
        
        for pg in pgs:
            name = pg.get("name") or pg.get("display_name", "")
            if name in ["us-west-region-Default Provider Gateway", "us-east-region-PG"]:
                print(f"Found Provider Gateway: {name}. Updating...")
                
                if "name" in pg: pg["name"] = "us-east-region-PG"
                if "display_name" in pg: pg["display_name"] = "us-east-region-PG"
                
                pg_id = pg.get("id")
                put_url = f"{VCFA_URL}/v1/providerGateways/{pg_id}"
                put_res = requests.put(put_url, headers=headers, json=pg, verify=False)
                
                if put_res.status_code in [200, 201, 202, 204]:
                    print("[+] VCFA Provider Gateway enforced!")
                else:
                    print(f"[-] Failed to update Provider Gateway. HTTP {put_res.status_code}: {put_res.text}")
    else:
        print(f"[-] Could not fetch VCFA Provider Gateways. HTTP {res.status_code}: {res.text}")

def update_nsx_profile():
    print("\nWaiting 15 seconds for VCFA to push changes down to NSX-T...")
    time.sleep(15)
    
    nsx_auth = (NSX_USER, NSX_PASS)
    
    print("Fetching synced IP Space from NSX-T...")
    res = requests.get(f"https://{NSX_HOST}/policy/api/v1/infra/ip-spaces", auth=nsx_auth, verify=False)
    nsx_space_path = None
    if res.status_code == 200:
        for item in res.json().get("results", []):
            if item.get("display_name") == "us-east-region-IP Space":
                nsx_space_path = item.get("path")
                break
    
    if not nsx_space_path:
        print("[-] Failed to find the synced IP Space in NSX-T! VCFA sync may be delayed.")
        return
        
    print("Enforcing NSX-T VPC Profile state...")
    res = requests.get(f"https://{NSX_HOST}/policy/api/v1/orgs/default/projects/default/vpc-connectivity-profiles", auth=nsx_auth, verify=False)
    if res.status_code == 200:
        for profile in res.json().get("results", []):
            if profile.get("display_name") in ["Default VPC Connectivity Profile", "default"]:
                profile["external_ip_space_paths"] = [nsx_space_path]
                
                put_res = requests.put(f"https://{NSX_HOST}/policy/api/v1/orgs/default/projects/default/vpc-connectivity-profiles/{profile['id']}", auth=nsx_auth, json=profile, verify=False)
                if put_res.status_code == 200:
                    print("[+] NSX-T VPC Profile successfully mapped to new IP Space!")
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
