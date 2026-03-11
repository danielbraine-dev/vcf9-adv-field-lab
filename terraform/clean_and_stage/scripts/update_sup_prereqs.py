#!/usr/bin/env python3
import requests
import urllib3
import time
import sys
import json
import re

# Suppress insecure request warnings for the lab environment
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# Variables passed from bash
VCFA_URL = sys.argv[1]
NSX_HOST = sys.argv[2]
NSX_USER = sys.argv[3]
NSX_PASS = sys.argv[4]
TFVARS_PATH = sys.argv[5]

# Hardcoded VCFA Provider Credentials (from your teardown script)
PROVIDER_USER = "admin"
PROVIDER_PASS = "VMware123!VMware123!"

def get_vcfa_token():
    print(f"Authenticating to VCFA/VCD ({VCFA_URL})...")
    auth_url = f"{VCFA_URL}/cloudapi/1.0.0/sessions/provider"
    headers = {"Accept": "application/json;version=37.0"}
    auth = (f"{PROVIDER_USER}@system", PROVIDER_PASS)
    
    response = requests.post(auth_url, headers=headers, auth=auth, verify=False)
    response.raise_for_status()
    
    # VCD sometimes uses lowercase or uppercase for this header
    token = response.headers.get("x-vmware-vcloud-access-token") or response.headers.get("X-VMWARE-VCLOUD-ACCESS-TOKEN")
    if not token:
        raise ValueError("Failed to extract x-vmware-vcloud-access-token from response headers.")
    return token

def update_tfvars(token):
    print("Injecting valid VCFA token into terraform.tfvars...")
    with open(TFVARS_PATH, "r") as f:
        content = f.read()
    
    # Regex replace the placeholder (or old token) with the newly minted one
    content = re.sub(r'vcfa_token\s*=\s*".*"', f'vcfa_token       = "{token}"', content)
    
    with open(TFVARS_PATH, "w") as f:
        f.write(content)

def update_vcfa_prereqs(token):
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json;version=37.0",
        "Content-Type": "application/json;version=37.0"
    }

    # 1. Update IP Space
    print("\nEnforcing VCFA IP Space state...")
    res = requests.get(f"{VCFA_URL}/cloudapi/1.0.0/networkIpSpaces", headers=headers, verify=False)
    if res.status_code == 200:
        spaces = res.json().get("values", [])
        for space in spaces:
            if space.get("name") in ["us-west-region-Default IP Space", "us-east-region-IP Space"]:
                print(f"Found IP Space: {space.get('name')}. Updating...")
                space["name"] = "us-east-region-IP Space"
                
                # Brute force string replace handles nested CIDR structures flawlessly
                space_json = json.dumps(space)
                space_json = space_json.replace("10.1.0.0/28", "10.1.0.0/26")
                updated_space = json.loads(space_json)
                
                put_res = requests.put(f"{VCFA_URL}/cloudapi/1.0.0/networkIpSpaces/{space['id']}", headers=headers, json=updated_space, verify=False)
                if put_res.status_code in [200, 202, 204]:
                    print("[+] VCFA IP Space enforced (us-east-region-IP Space, 10.1.0.0/26).")
                else:
                    print(f"[-] Failed to update IP Space: {put_res.text}")
    else:
        print("[-] Could not fetch VCFA IP Spaces.")

    # 2. Update Provider Gateway
    print("\nEnforcing VCFA Provider Gateway state...")
    res = requests.get(f"{VCFA_URL}/cloudapi/1.0.0/providerGateways", headers=headers, verify=False)
    if res.status_code == 200:
        pgs = res.json().get("values", [])
        for pg in pgs:
            if pg.get("name") in ["us-west-region-Default Provider Gateway", "us-east-region-PG"]:
                print(f"Found Provider Gateway: {pg.get('name')}. Updating...")
                pg["name"] = "us-east-region-PG"
                
                put_res = requests.put(f"{VCFA_URL}/cloudapi/1.0.0/providerGateways/{pg['id']}", headers=headers, json=pg, verify=False)
                if put_res.status_code in [200, 202, 204]:
                    print("[+] VCFA Provider Gateway enforced (us-east-region-PG).")
                else:
                    print(f"[-] Failed to update Provider Gateway: {put_res.text}")
    else:
        print("[-] Could not fetch VCFA Provider Gateways.")

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
        sys.exit(1)
        
    print("\nEnforcing NSX-T VPC Profile state...")
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
        update_tfvars(token)
        update_vcfa_prereqs(token)
        update_nsx_profile()
    except Exception as e:
        print(f"[-] Python Script Error: {e}")
        sys.exit(1)
