import requests
import json
import urllib3
import sys

# Suppress self-signed cert warnings
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

NSX_MANAGER = "nsx-wld01-a.site-a.vcf.lab"

# VCFA Provider Credentials
VCFA_URL = "https://auto-a.site-a.vcf.lab"
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

def create_vcf_region(token):
    print(f"\n[1] Defining Region: us-east...")
    
    url = f"{VCFA_URL}/cloudapi/vcf/regions"
    
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json;version=9.0.0",
        "Content-Type": "application/json;version=9.0.0"
    }
    
    payload = {
        "name": "us-east",
        "nsxManager": {
            "name": NSX_MANAGER
            # Note: If the API strictly demands the ID alongside the name, 
            # we will need to add a quick GET call to fetch the NSX Manager URN first.
        },
        "supervisors": [
            {
                "name": "wld01-supervisor"
            }
        ],
        "storagePolicies": [
            "vSAN Default Storage Policy"
        ]
    }
    
    res = requests.post(url, headers=headers, json=payload, verify=False)
    
    if res.status_code in [200, 201, 202, 204]:
        print("[+] Region 'us-east' successfully defined in VCFA.")
    else:
        print(f"[-] Failed to create region: {res.status_code} {res.text}")
        sys.exit(1)

def create_tenant_org(token):
    print(f"\n[2] Creating Tenant Organization: Cloud Org A...")
    
    # THE FIX: Pointing to VCFA OpenAPI endpoint
    url = f"{VCFA_URL}/cloudapi/1.0.0/orgs"
    
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json;version=40.0",
        "Content-Type": "application/json"
    }

    # Creating an "All Apps" Organization Native to VCF 9
    payload = {
        "name": "Cloud Org A",
        "displayName": "Cloud Org A",
        "description": "Tenant Organization for Cloud Org A",
        # Ensures this creates an "All Apps" Org (VPC/Supervisor), not a legacy "VM Apps" Org
        "isClassicTenant": False, 
        "networkLogName": "cldorg-A",
        "regionConfiguration": [
            {
                "region": "us-east",
                "zones": ["z-wld-a"],
                "supervisor": "wld01-supervisor",
                # VCFA 9 allows passing 'ALL' so we don't need a separate API call to vCenter to list classes
                "vmClasses": ["ALL"], 
                "storagePolicies": ["vSAN Default Storage Policy"],
                "quotas": [] # Empty array defines "No Limits"
            }
        ],
        "initialAdmin": {
            "username": "cloud-org-a_admin",
            "password": "VMware123!VMware123!",
            "role": "ORGANIZATION_ADMIN"
        }
    }
    
    res = requests.post(url, headers=headers, json=payload, verify=False)
    
    if res.status_code in [200, 201, 202, 204]:
        print("[+] Tenant 'Cloud Org A' is now active in VCFA.")
        print(f"[!] Admin User: cloud-org-a_admin")
    else:
        print(f"[-] Failed to create tenant: {res.text}")

if __name__ == "__main__":
    try:
        token = get_vcfa_token()
        create_vcf_region(token)
        create_tenant_org(token)
    except Exception as e:
        print(f"[-] Python Script Error: {e}")
        sys.exit(1)
