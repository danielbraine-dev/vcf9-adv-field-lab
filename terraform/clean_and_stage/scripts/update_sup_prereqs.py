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

    # Fetch the "lite" summaries
    spaces = requests.get(ip_spaces_url, headers=headers, verify=False).json().get("values", [])
    pgs = requests.get(pg_url, headers=headers, verify=False).json().get("values", [])

    space_summary = next((s for s in spaces if "us-east-region" in s.get("name", "") or "us-west" in s.get("name", "")), None)
    pg_summary = next((p for p in pgs if "us-east-region" in p.get("name", "") or "us-west" in p.get("name", "")), None)

    if not space_summary or not pg_summary:
        print("[-] Could not find target IP Space or Provider Gateway summaries!")
        return

    # Fetch the FULL objects using their direct IDs
    print(f"Fetching full objects for Space ({space_summary['id']}) and PG ({pg_summary['id']})...")
    target_space = requests.get(f"{ip_spaces_url}/{space_summary['id']}", headers=headers, verify=False).json()
    target_pg = requests.get(f"{pg_url}/{pg_summary['id']}", headers=headers, verify=False).json()

    # THE FIX: Standardize top-level names AND purge display_name if it exists
    target_space["name"] = "us-east-region-IP Space"
    target_space.pop("display_name", None)
    
    target_pg["name"] = "us-east-region-PG"
    target_pg.pop("display_name", None)

    if "ipBlocks" not in target_space: target_space["ipBlocks"] = []
    if "ipBlocks" not in target_pg: target_pg["ipBlocks"] = []

    # Print what the API actually sees right now
    print("\n--- Current IP Blocks in IP Space ---")
    correct_block_found = False
    for b in target_space["ipBlocks"]:
        print(f"  Found Block -> Name: '{b.get('name')}', CIDR: '{b.get('cidr')}'")
        if b.get("cidr") == "10.1.0.0/26":
            correct_block_found = True
    print("-------------------------------------\n")

    if not correct_block_found:
        print("  [!] Correct /26 block is MISSING. Executing rebuild sequence...")

        # 1. DETACH FROM PG
        print("  [1/4] Detaching old blocks from Provider Gateway...")
        target_pg["ipBlocks"] = [b for b in target_pg["ipBlocks"] if b.get("cidr") == "10.1.0.0/26"]
        r1 = requests.put(f"{pg_url}/{target_pg['id']}", headers=headers, json=target_pg, verify=False)
        if r1.status_code not in [200, 201, 202, 204]: print(f"[-] PG Detach Error: {r1.text}")

        # 2. DELETE FROM IP SPACE 
        print("  [2/4] Deleting old blocks from IP Space...")
        target_space["ipBlocks"] = [b for b in target_space["ipBlocks"] if b.get("cidr") == "10.1.0.0/26"]
        r2 = requests.put(f"{ip_spaces_url}/{target_space['id']}", headers=headers, json=target_space, verify=False)
        if r2.status_code not in [200, 201, 202, 204]: print(f"[-] IP Space Delete Error: {r2.text}")

        # 3. RECREATE IN IP SPACE
        print("  [3/4] Creating new 10.1.0.0/26 block in IP Space...")
        target_space["ipBlocks"].append({"name": "VPC-External-Block", "cidr": "10.1.0.0/26"})
        r3 = requests.put(f"{ip_spaces_url}/{target_space['id']}", headers=headers, json=target_space, verify=False)
        if r3.status_code not in [200, 201, 202, 204]: 
            print(f"[-] IP Space Recreate Error: {r3.text}")
            sys.exit(1)

        # Fetch the IP space fresh to grab the newly generated database ID
        fresh_space = requests.get(f"{ip_spaces_url}/{target_space['id']}", headers=headers, verify=False).json()
        new_block = next((b for b in fresh_space.get("ipBlocks", []) if b.get("cidr") == "10.1.0.0/26"), None)

        if not new_block:
            print("[-] Failed to find the newly created block ID after PUT!")
            sys.exit(1)

        # 4. ATTACH TO PG
        print("  [4/4] Attaching new block to Provider Gateway...")
        target_pg["ipBlocks"].append(new_block) 
        r4 = requests.put(f"{pg_url}/{target_pg['id']}", headers=headers, json=target_pg, verify=False)
        
        if r4.status_code in [200, 201, 202, 204]:
            print("[+] SUCCESS! IP Space and Provider Gateway fully rebuilt and enforced!")
        else:
            print(f"[-] Final PG update failed: {r4.text}")
            sys.exit(1)
    else:
        print("  [!] CIDR is correctly set to /26. Enforcing top-level names...")
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
