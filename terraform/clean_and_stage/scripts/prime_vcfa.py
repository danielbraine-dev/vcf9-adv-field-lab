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

def create_tenant_org_base(token):
    print(f"\n[2] Creating Base Tenant Organization: Cloud Org A...")
    
    url = f"{VCFA_URL}/cloudapi/1.0.0/orgs"
    
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json;version=9.0.0",
        "Content-Type": "application/json;version=9.0.0"
    }

    # Strict adherence to the provided Org schema
    payload = {
        "name": "Cloud Org A",
        "displayName": "Cloud Org A",
        "description": "Sovereign Tenant Organization",
        "isEnabled": True,
        "isClassicTenant": False 
    }
    
    res = requests.post(url, headers=headers, json=payload, verify=False)
    
    if res.status_code in [200, 201, 202, 204]:
        print("[+] Base Tenant 'Cloud Org A' created successfully.")
        
        # VCFA usually returns the ID in the body or a Location header
        try:
            org_data = res.json()
            org_id = org_data.get("id")
            print(f"[!] Captured Org ID: {org_id}")
            return org_id
        except json.JSONDecodeError:
            print("[!] Check VCFA UI. Org created but couldn't parse ID from response.")
            return None
    else:
        print(f"[-] Failed to create base tenant: {res.status_code} {res.text}")
        sys.exit(1)

def configure_org_networking_tenancy(token, org_id):
    print(f"\n[3] Enabling NSX Network Tenancy for Org...")
    
    # Using the URN to target the specific Org's settings
    url = f"{VCFA_URL}/cloudapi/1.0.0/orgs/{org_id}/networkingSettings"
    
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json",
        "Content-Type": "application/json"
    }

    payload = {
        "networkingTenancyEnabled": True,
        # Fits the exact 8-character constraint for NSX log tagging
        "orgNameForLogs": "cldorg-A" 
    }
    
    # Settings endpoints in VCFA typically use PUT
    res = requests.put(url, headers=headers, json=payload, verify=False)
    
    if res.status_code in [200, 201, 202, 204]:
        print("[+] Org Networking Tenancy successfully enabled.")
    else:
        print(f"[-] Failed to enable Org networking: {res.status_code} {res.text}")
        sys.exit(1)

def configure_regional_networking(token, org_id):
    print(f"\n[4] Binding Regional Networking (VPC Setup)...")
    
    url = f"{VCFA_URL}/cloudapi/vcf/regionalNetworkingSettings"
    
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json",
        "Content-Type": "application/json"
    }

    # Note: VCFA requires mapping the tenant to the underlying Provider Gateway (Tier-0).
    # Assuming standard VCF lab naming for the T0 gateway here.
    PROVIDER_GATEWAY_NAME = "wld01-t0-gw" 
    
    payload = {
        # Leaving 'name' unset per doc to let VCFA auto-generate it
        "regionRef": {
            "name": "us-east"
        },
        "orgRef": {
            "id": org_id
        },
        "providerGatewayRef": {
            "name": PROVIDER_GATEWAY_NAME
        }
        # Omitting serviceEdgeClusterRef to allow the system default
    }
    
    res = requests.post(url, headers=headers, json=payload, verify=False)
    
    if res.status_code in [200, 201, 202, 204]:
        print(f"[+] Regional Networking bound to Provider Gateway: {PROVIDER_GATEWAY_NAME}")
    else:
        print(f"[-] Failed to bind regional networking: {res.status_code} {res.text}")
        sys.exit(1)

if __name__ == "__main__":
    try:
        token = get_vcfa_token()
        # Step 1: Define Region
        create_vcf_region(token)

        # Step 2: Create Base Org
        create_tenant_org_base(token)

        # Step 3: Fetch the verified Org URN
        ORG_NAME = "Cloud Org A"
        org_urn = get_org_id(token, ORG_NAME)
        if org_urn:
            # Step 4: Enable Tenancy on the Org
            configure_org_networking_tenancy(token, org_id)

            # Step 5: Map the Org to the Regional Networking
            configure_regional_networking(token, org_id)

            # Step 6: Create and map regional quota
    
            # Step 7: Create First User
        else:
            print(f"[-] Automation halted. Could not retrieve URN for {ORG_NAME}.")
            sys.exit(1)
            
    except Exception as e:
        print(f"[-] Python Script Error: {e}")
        sys.exit(1)
