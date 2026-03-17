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

    # CLEANUP: Scrub bad keys we might have injected previously
    target_space.pop("display_name", None); target_space.pop("ipBlocks", None) 
    target_pg.pop("display_name", None); target_pg.pop("ipBlocks", None)

    # Helper function to push changes, wait for VCD locks to clear, and fetch fresh state
    def push_space_update(space_obj, step_desc):
        print(f"  {step_desc}")
        r = requests.put(f"{ip_spaces_url}/{space_obj['id']}", headers=headers, json=space_obj, verify=False)
        if r.status_code not in [200, 201, 202, 204]:
            print(f"  [-] Failed: {r.text}"); sys.exit(1)
        print("  [zZz] Waiting 15 seconds for VCD backend to unlock the entity...")
        time.sleep(15)
        # MUST return a fresh object to get the latest database 'etag'/version
        return requests.get(f"{ip_spaces_url}/{space_obj['id']}", headers=headers, verify=False).json()

    # 1. Update Provider Gateway Name
    print("\nEnforcing Provider Gateway Name...")
    target_pg["name"] = "us-east-region-PG"
    r_pg = requests.put(f"{pg_url}/{target_pg['id']}", headers=headers, json=target_pg, verify=False)
    if r_pg.status_code in [200, 201, 202, 204]: print("  [+] Provider Gateway name updated.")

    # 2. Update IP Space Name First
    print("\nEnforcing IP Space Name...")
    if target_space.get("name") != "us-east-region-IP Space":
        target_space["name"] = "us-east-region-IP Space"
        target_space = push_space_update(target_space, "Updating IP Space Name...")
    else:
        print("  [+] IP Space name is correct.")

    # 3. State-Machine CIDR Logic
    blocks = target_space.get("internalScopeCidrBlocks", [])
    has_26 = any(b.get("cidr") == "10.1.0.0/26" for b in blocks)
    has_28 = any(b.get("cidr") == "10.1.0.0/28" for b in blocks)
    has_dummy = any(b.get("name") == "Dummy-Block" for b in blocks)

    if has_28 or not has_26 or has_dummy:
        print("\n  [!] Reconciling CIDR blocks (Handling VCD locks safely)...")
        
        # Step 1: Inject Dummy (Skip if it already exists from the previous crash!)
        if has_28 and not has_dummy:
            target_space["internalScopeCidrBlocks"].append({"name": "Dummy-Block", "cidr": "192.168.255.0/29"})
            target_space = push_space_update(target_space, "[1/4] Injecting Non-Overlapping Dummy Block...")
        elif has_dummy:
            print("  [1/4] Dummy Block already exists (Recovered from previous run).")

        # Step 2: Purge /28
        if has_28:
            target_space["internalScopeCidrBlocks"] = [b for b in target_space["internalScopeCidrBlocks"] if b.get("cidr") != "10.1.0.0/28"]
            target_space = push_space_update(target_space, "[2/4] Purging the old /28 block...")

        # Step 3: Inject /26
        if not has_26:
            target_space["internalScopeCidrBlocks"].append({"name": "VPC-External-Block", "cidr": "10.1.0.0/26"})
            target_space = push_space_update(target_space, "[3/4] Injecting the correct 10.1.0.0/26 block...")

        # Step 4: Purge Dummy
        has_dummy_now = any(b.get("name") == "Dummy-Block" for b in target_space.get("internalScopeCidrBlocks", []))
        if has_dummy_now:
            target_space["internalScopeCidrBlocks"] = [b for b in target_space["internalScopeCidrBlocks"] if b.get("name") != "Dummy-Block"]
            target_space = push_space_update(target_space, "[4/4] Removing temporary Dummy Block...")

        print("  [+] SUCCESS! IP Space CIDR perfectly resized and reconciled.")
    else:
        print("\n  [+] CIDR blocks are already perfectly configured. No changes needed.")

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
