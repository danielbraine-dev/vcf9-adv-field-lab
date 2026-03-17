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

    print("\nStarting IP Space CIDR Correction Workflow...")

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

    # ---------------------------------------------------------
    # CLEANUP: Scrub bad keys we might have injected previously
    # ---------------------------------------------------------
    target_space.pop("display_name", None)
    target_space.pop("ipBlocks", None) 
    
    target_pg.pop("display_name", None)
    target_pg.pop("ipBlocks", None)

    # 1. Update Provider Gateway Name
    print("Enforcing Provider Gateway Name...")
    target_pg["name"] = "us-east-region-PG"
    r_pg = requests.put(f"{pg_url}/{target_pg['id']}", headers=headers, json=target_pg, verify=False)
    if r_pg.status_code in [200, 201, 202, 204]:
        print("  [+] Provider Gateway name updated successfully.")
    else:
        print(f"  [-] PG Update Error: {r_pg.text}")

    # 2. Update IP Space Name & Internal CIDR Blocks
    print("\nEnforcing IP Space and sizing CIDR...")
    target_space["name"] = "us-east-region-IP Space"
    
    # THE FIX: Target the real VCF 9 array
    cidr_updated = False
    if "internalScopeCidrBlocks" in target_space:
        for block in target_space["internalScopeCidrBlocks"]:
            print(f"  Found Block -> Name: '{block.get('name')}', CIDR: '{block.get('cidr')}'")
            if block.get("cidr") != "10.1.0.0/26":
                print("  [!] Incorrect CIDR detected. Resizing to 10.1.0.0/26...")
                block["cidr"] = "10.1.0.0/26"
                cidr_updated = True

    r_space = requests.put(f"{ip_spaces_url}/{target_space['id']}", headers=headers, json=target_space, verify=False)
    if r_space.status_code in [200, 201, 202, 204]:
        print("  [+] IP Space updated successfully.")
        if cidr_updated:
            print("  [+] Block CIDR successfully resized to /26.")
    else:
        print(f"  [-] IP Space Update Error: {r_space.text}")
        sys.exit(1)

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
