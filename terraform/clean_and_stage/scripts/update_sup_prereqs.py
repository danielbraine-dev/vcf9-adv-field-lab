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

def update_vcfa_prereqs(token):
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json;version=9.0.0",
        "Content-Type": "application/json;version=9.0.0"
    }

    print("\nStarting IP Block Replacement Workflow...")

    # API Endpoints
    ip_spaces_url = f"{VCFA_URL}/cloudapi/v1/ipSpaces"
    pg_url = f"{VCFA_URL}/cloudapi/v1/providerGateways"

    # Fetch existing configurations
    spaces = requests.get(ip_spaces_url, headers=headers, verify=False).json().get("values", [])
    pgs = requests.get(pg_url, headers=headers, verify=False).json().get("values", [])

    # Locate our specific targets
    target_space = next((s for s in spaces if "us-east-region" in s.get("name", "") or "us-west" in s.get("name", "")), None)
    target_pg = next((p for p in pgs if "us-east-region" in p.get("name", "") or "us-west" in p.get("name", "")), None)

    if not target_space or not target_pg:
        print("[-] Could not find target IP Space or Provider Gateway!")
        return

    # Standardize top-level names 
    target_space["name"] = "us-east-region-IP Space"
    target_space["display_name"] = "us-east-region-IP Space"
    target_pg["name"] = "us-east-region-PG"
    target_pg["display_name"] = "us-east-region-PG"

    # Print what the API actually sees right now
    print("\n--- Current IP Blocks Detected ---")
    needs_rebuild = False
    for b in target_space.get("ipBlocks", []):
        print(f"  Found Block -> Name: '{b.get('name')}', CIDR: '{b.get('cidr')}'")
        # TARGET BY CIDR: If it's not our desired /26, trigger the rebuild
        if b.get("cidr") != "10.1.0.0/26":
            needs_rebuild = True
    print("----------------------------------\n")

    if needs_rebuild:
        print("  [!] Incorrect CIDR detected. Executing Detach -> Delete -> Recreate -> Attach sequence.")

        # 1. DETACH FROM PG (Filter out anything that isn't the /26)
        print("  [1/4] Detaching old block from Provider Gateway...")
        target_pg["ipBlocks"] = [b for b in target_pg.get("ipBlocks", []) if b.get("cidr") == "10.1.0.0/26"]
        requests.put(f"{pg_url}/{target_pg['id']}", headers=headers, json=target_pg, verify=False)

        # 2. DELETE FROM IP SPACE 
        print("  [2/4] Deleting old block from IP Space...")
        target_space["ipBlocks"] = [b for b in target_space.get("ipBlocks", []) if b.get("cidr") == "10.1.0.0/26"]
        requests.put(f"{ip_spaces_url}/{target_space['id']}", headers=headers, json=target_space, verify=False)

        # 3. RECREATE IN IP SPACE
        print("  [3/4] Creating new 10.1.0.0/26 block in IP Space...")
        target_space["ipBlocks"].append({"name": "VPC-External-Block", "cidr": "10.1.0.0/26"})
        requests.put(f"{ip_spaces_url}/{target_space['id']}", headers=headers, json=target_space, verify=False)

        # Fetch the IP space fresh to grab the newly generated database ID
        fresh_space = requests.get(f"{ip_spaces_url}/{target_space['id']}", headers=headers, verify=False).json()
        new_block = next((b for b in fresh_space.get("ipBlocks", []) if b.get("cidr") == "10.1.0.0/26"), None)

        if not new_block:
            print("[-] Failed to find the newly created block ID!")
            sys.exit(1)

        # 4. ATTACH TO PG
        print("  [4/4] Attaching new block (with new ID) to Provider Gateway...")
        target_pg["ipBlocks"].append(new_block) 
        res = requests.put(f"{pg_url}/{target_pg['id']}", headers=headers, json=target_pg, verify=False)
        
        if res.status_code in [200, 201, 202, 204]:
            print("[+] SUCCESS! IP Space and Provider Gateway fully rebuilt and enforced!")
        else:
            print(f"[-] Final PG update failed: {res.text}")
    else:
        print("  [!] CIDR is already correct. Enforcing top-level names...")
        requests.put(f"{ip_spaces_url}/{target_space['id']}", headers=headers, json=target_space, verify=False)
        requests.put(f"{pg_url}/{target_pg['id']}", headers=headers, json=target_pg, verify=False)
        print("[+] Names enforced successfully.")

def update_nsx_profile():
    print("\nWaiting 20 seconds for VCFA to push changes down to NSX-T...")
    time.sleep(20)
    
    nsx_auth = (NSX_USER, NSX_PASS)
    
    print("Fetching synced IP Blocks from NSX-T...")
    res = requests.get(f"https://{NSX_HOST}/policy/api/v1/infra/ip-blocks", auth=nsx_auth, verify=False)
    nsx_block_path = None
    if res.status_code == 200:
        for item in res.json().get("results", []):
            name = item.get("display_name", "")
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
                
                profile["external_ip_blocks"] = [nsx_block_path]
                
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
