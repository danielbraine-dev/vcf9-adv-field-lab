import requests
import json
import urllib3
import sys

# Suppress self-signed cert warnings
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

NSX_MANAGER = "nsx-wld01-a.site-a.vcf.lab"
SUPERVISOR_NAME = "wld01-supervisor"
ORG_NAME = "Cloud Org A"

# VCFA Provider Credentials
VCFA_URL = "https://auto-a.site-a.vcf.lab"
PROVIDER_USER = "admin"
PROVIDER_PASS = "VMware123!VMware123!"

###################
# Helper Functions#
###################

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

def get_org_id(token, org_name):
    print(f"\n[*] Fetching URN for Tenant: {org_name}...")
    
    url = f"{VCFA_URL}/cloudapi/1.0.0/orgs"
    
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json;version=9.0.0"
    }
    
    res = requests.get(url, headers=headers, verify=False)
    
    if res.status_code == 200:
        # VCFA CloudAPI usually wraps collection results in a 'values' array
        orgs = res.json().get("values", [])
        
        for org in orgs:
            if org.get("name") == org_name:
                org_urn = org.get("id")
                print(f"[+] Found Org URN: {org_urn}")
                return org_urn
                
        print(f"[-] Org '{org_name}' not found in the API response.")
        return None
    else:
        print(f"[-] Failed to fetch Orgs: {res.status_code} {res.text}")
        return None
        
def get_nsx_manager_id(token, nsx_hostname):
    print(f"\n[*] Fetching URN for NSX Manager via VCF CloudAPI...")
    
    # THE FIX: Pointing to the strict VCF namespace
    url = f"{VCFA_URL}/cloudapi/vcf/nsxManagers"
    
    # THE FIX: Explicitly passing the required pagination parameters
    params = {
        "page": 1,
        "pageSize": 25
    }
    
    headers = {
        "Authorization": f"Bearer {token}",
        # Adding the version header just in case VCFA gets picky
        "Accept": "application/json;version=40.0" 
    }
    
    res = requests.get(url, headers=headers, params=params, verify=False)
    
    if res.status_code == 200:
        managers = res.json().get("values", [])
        
        for m in managers:
            # Checking both name and URL based on your provided schema
            if m.get("name") == nsx_hostname or nsx_hostname in m.get("url", ""):
                urn = m.get("id")
                print(f"[+] Found explicit NSX Manager URN: {urn}")
                return urn
                
        # Lab Fallback: If naming doesn't perfectly match but there's only one manager registered
        if len(managers) == 1:
            urn = managers[0].get("id")
            print(f"[+] Defaulting to the only registered NSX Manager URN: {urn}")
            return urn
            
        print(f"[-] NSX Manager '{nsx_hostname}' not found in API response.")
        return None
    else:
        print(f"[-] Failed to fetch NSX Managers: {res.status_code} {res.text}")
        return None

def get_supervisor_id(token, supervisor_name):
    print(f"\n[*] Fetching URN for Supervisor via VCF CloudAPI...")
    
    # Pointing to the strict VCF namespace for Supervisors
    url = f"{VCFA_URL}/cloudapi/vcf/supervisors"
    
    # Passing the required pagination parameters
    params = {
        "page": 1,
        "pageSize": 25
    }
    
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json;version=40.0" 
    }
    
    res = requests.get(url, headers=headers, params=params, verify=False)
    
    if res.status_code == 200:
        supervisors = res.json().get("values", [])
        
        for s in supervisors:
            if s.get("name") == supervisor_name:
                urn = s.get("id")
                print(f"[+] Found explicit Supervisor URN: {urn}")
                return urn
                
        # Lab Fallback just in case naming is slightly off
        if len(supervisors) == 1:
            urn = supervisors[0].get("id")
            print(f"[+] Defaulting to the only registered Supervisor URN: {urn}")
            return urn
            
        print(f"[-] Supervisor '{supervisor_name}' not found in API response.")
        return None
    else:
        print(f"[-] Failed to fetch Supervisors: {res.status_code} {res.text}")
        return None
######################
# GP Functions#
######################
def create_vcf_region(token, nsx_urn, supervisor_urn):
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
            "name": NSX_MANAGER,
            "id": nsx_urn
        },
        "supervisors": [
            {
                "name": "wld01-supervisor",
                "id": supervisor_urn
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
        "Accept": "application/json;version=9.0.0",
        "Content-Type": "application/json;version=9.0.0"
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
        "Accept": "application/json;version=9.0.0",
        "Content-Type": "application/json;version=9.0.0"
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
        
def configure_org_quota(token, org_id):
    print(f"\n[5] Defining and Assigning Unlimited Quota Policy...")
    
    # Part A: Create the Quota Policy
    create_url = f"{VCFA_URL}/cloudapi/1.0.0/quotaPolicies"
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json;version=9.0.0",
        "Content-Type": "application/json;version=9.0.0"
    }
    
    # An empty quotaPoolDefinitions array generally translates to "No Limits" in VCFA
    quota_payload = {
        "name": "Unlimited-Quota-Cloud-Org-A",
        "description": "Unlimited regional quota for sovereign tenant",
        "orgId": org_id,
        "quotaPoolDefinitions": []
    }
    
    res = requests.post(create_url, headers=headers, json=quota_payload, verify=False)
    
    if res.status_code in [200, 201]:
        # Extract the new Policy URN
        policy_urn = res.json().get("id")
        print(f"[+] Quota Policy created with URN: {policy_urn}")
    else:
        print(f"[-] Failed to create quota policy: {res.status_code} {res.text}")
        sys.exit(1)

    # Part B: Bind the Quota Policy to the Org
    assign_url = f"{VCFA_URL}/cloudapi/1.0.0/orgs/{org_id}/quotaPolicy"
    
    assign_payload = {
        "quotaPolicyReference": {
            "id": policy_urn
        }
    }
    
    assign_res = requests.put(assign_url, headers=headers, json=assign_payload, verify=False)
    
    if assign_res.status_code in [200, 201, 202, 204]:
        print("[+] Quota Policy successfully bound to Cloud Org A.")
    else:
        print(f"[-] Failed to bind quota policy: {assign_res.status_code} {assign_res.text}")
        sys.exit(1)

def create_org_admin(token, org_id):
    print(f"\n[6] Creating First User and Assigning Roles...")
    
    # Part A: Create the User
    user_url = f"{VCFA_URL}/cloudapi/1.0.0/users"
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json;version=9.0.0",
        "Content-Type": "application/json;version=9.0.0"
    }
    
    user_payload = {
        "username": "cloud-org-a_admin",
        "password": "VMware123!VMware123!", # Meets the >=15 char, upper, lower, special, digit requirement
        "fullName": "Cloud Org A Administrator",
        "orgEntityRef": {
            "id": org_id
        },
        "enabled": True,
        "providerType": "LOCAL"
    }
    
    user_res = requests.post(user_url, headers=headers, json=user_payload, verify=False)
    
    if user_res.status_code in [200, 201]:
        user_urn = user_res.json().get("id")
        print(f"[+] User 'cloud-org-a_admin' created with URN: {user_urn}")
    else:
        print(f"[-] Failed to create user: {user_res.status_code} {user_res.text}")
        sys.exit(1)

    # Part B: Assign the Organization Administrator Role
    # CloudAPI paths usually expect the UUID portion or URL-encoded URNs. 
    # We will strip the "urn:vcloud:user:" prefix to get the raw UUID to be safe in the URL path.
    raw_user_id = user_urn.split(":")[-1]
    raw_org_id = org_id.split(":")[-1]
    
    role_url = f"{VCFA_URL}/cloudapi/1.0.0/users/{raw_user_id}/orgs/{raw_org_id}/roles"
    
    role_payload = {
        "roleNamesToAdd": [
            "Organization Administrator"
        ],
        "roleNamesToRemove": []
    }
    
    # Your schema explicitly states this is a PATCH method
    role_res = requests.patch(role_url, headers=headers, json=role_payload, verify=False)
    
    if role_res.status_code in [200, 201, 202, 204]:
        print("[+] Role 'Organization Administrator' successfully granted!")
    else:
        print(f"[-] Failed to assign role: {role_res.status_code} {role_res.text}")
        sys.exit(1)
        
if __name__ == "__main__":
    try:
        token = get_vcfa_token()
        nsx_urn = get_nsx_manager_id(token, NSX_MANAGER)
        if not nsx_urn:
            print("[-] Automation halted. Could not retrieve NSX Manager URN.")
            sys.exit(1)

        supervisor_urn = get_supervisor_id(token, SUPERVISOR_NAME)
        if not supervisor_urn:
            print("[-] Automation halted. Could not retrieve Supervisor URN.")
            sys.exit(1)
            
        # Step 1: Define Region (VCF 9 EntityReference Schema)
        create_vcf_region(token, nsx_urn)
        
        # Step 2: Create Base Org
        create_tenant_org_base(token)
        
        # Step 3: Fetch the explicit Org URN
        org_urn = get_org_id(token, ORG_NAME)
        
        if org_urn:
            # Step 4: Network Tenancy & T0 Binding
            configure_org_networking_tenancy(token, org_urn)
            configure_regional_networking(token, org_urn)
            
            # Step 5: Quota Orchestration
            configure_org_quota(token, org_urn)
            
            # Step 6: User & Role Orchestration
            create_org_admin(token, org_urn)
            
            print(f"\n[✔] SUCCESS: Step 10 VCFA Priming is 100% Complete.")
            print(f"    Tenant: {ORG_NAME}")
            print(f"    Admin:  cloud-org-a_admin")
            print(f"    Pass:   VMware123!VMware123!")
            
        else:
            print(f"[-] Automation halted. Could not retrieve URN for {ORG_NAME}.")
            sys.exit(1)
            
    except Exception as e:
        print(f"[-] Python Script Error: {e}")
        sys.exit(1)
