import requests
import json
import urllib3

# Suppress self-signed cert warnings
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

VC_HOST = "vc-wld01-a.site-a.vcf.lab"
NSX_MANAGER = "nsx-wld01-a.site-a.vcf.lab"

# Variables passed from bash
VCFA_URL = sys.argv[1]

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
  
def create_vcf_region(token):
    print(f"\n[1] Defining Region: us-east...")
    url = f"https://{VC_HOST}/api/vcenter/consumption-domains/regions"
    
    payload = {
        "name": "us-east",
        "local_manager": NSX_MANAGER,
        # We associate the supervisor we just stood up
        "supervisors": ["wld01-supervisor"] 
    }
    
    headers = {"vmware-api-session-id": token, "Content-Type": "application/json"}
    res = requests.post(url, headers=headers, json=payload, verify=False)
    
    if res.status_code in [200, 201, 204]:
        print("[+] Region 'us-east' successfully defined.")
    else:
        print(f"[-] Failed to create region: {res.text}")

def create_tenant_org(token):
    print(f"\n[2] Creating Tenant Organization: Cloud Org A...")
    url = f"https://{VC_HOST}/api/vcenter/consumption-domains/tenants"
    
    # Fetching all VM Classes to satisfy the 'all enabled' requirement
    vm_classes = requests.get(
        f"https://{VC_HOST}/api/vcenter/namespace-management/vm-classes", 
        headers={"vmware-api-session-id": token}, 
        verify=False
    ).json()
    class_names = [c['class'] for c in vm_classes]

    payload = {
        "name": "Cloud Org A",
        "region": "us-east",
        "zone": "z-wld-a",
        "supervisor": "wld01-supervisor",
        "network_log_name": "cldorg-A",
        "resource_config": {
            "vm_classes": class_names,
            "storage_policies": ["vSAN Default Storage Policy"],
            # Regional quota: no limits (-1 or empty in VCF 9)
            "quotas": [] 
        },
        "initial_admin": {
            "username": "cloud-org-a_admin",
            "password": "VMware123!VMware123!",
            "role": "ORGANIZATION_ADMIN"
        }
    }
    
    headers = {"vmware-api-session-id": token, "Content-Type": "application/json"}
    res = requests.post(url, headers=headers, json=payload, verify=False)
    
    if res.status_code in [200, 201, 204]:
        print("[+] Tenant 'Cloud Org A' is now active.")
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
