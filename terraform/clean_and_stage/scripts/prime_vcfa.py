import requests
import json
import urllib3
import sys

# Suppress self-signed cert warnings
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

NSX_MANAGER = "nsx-wld01-a.site-a.vcf.lab"
SUPERVISOR_NAME = "wld01-supervisor"
REGION_NAME = "us-east"
ORG_NAME = "Cloud-Org-A"
PROVIDER_GATEWAY_NAME = "us-east-region-PG"

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
    
    url = f"{VCFA_URL}/cloudapi/vcf/nsxManagers"
    
    params = {
        "page": 1,
        "pageSize": 25
    }
    
    headers = {
        "Authorization": f"Bearer {token}",
        # Adding the version header just in case VCFA gets picky
        "Accept": "application/json;version=9.0.0" 
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
    
    url = f"{VCFA_URL}/cloudapi/vcf/supervisors"
    
    params = {
        "page": 1,
        "pageSize": 25
    }
    
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json;version=9.0.0" 
    }
    
    res = requests.get(url, headers=headers, params=params, verify=False)
    
    if res.status_code == 200:
        supervisors = res.json().get("values", [])
        
        for s in supervisors:
            if s.get("name") == supervisor_name:
                # THE FIX: Targeting the specific 'supervisorId' key from the schema
                urn = s.get("supervisorId")
                print(f"[+] Found explicit Supervisor URN: {urn}")
                return urn
                
        # Lab Fallback
        if len(supervisors) == 1:
            urn = supervisors[0].get("supervisorId")
            print(f"[+] Defaulting to the only registered Supervisor URN: {urn}")
            return urn
            
        print(f"[-] Supervisor '{supervisor_name}' not found in API response.")
        return None
    else:
        print(f"[-] Failed to fetch Supervisors: {res.status_code} {res.text}")
        return None
        
        
def get_region_id(token, region_name):
    print(f"\n[*] Fetching URN for Region: {region_name}...")
    url = f"{VCFA_URL}/cloudapi/vcf/regions"
    
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json;version=9.0.0"
    }
    
    res = requests.get(url, headers=headers, verify=False)
    
    if res.status_code == 200:
        regions = res.json().get("values", [])
        for r in regions:
            if r.get("name") == region_name:
                urn = r.get("id")
                print(f"[+] Found Region URN: {urn}")
                return urn
        print(f"[-] Region '{region_name}' not found.")
        return None
    else:
        print(f"[-] Failed to fetch Regions: {res.status_code} {res.text}")
        return None

def get_provider_gateway_id(token, gateway_name):
    print(f"\n[*] Fetching URN for Provider Gateway (Tier-0) via VCF CloudAPI...")
    
    url = f"{VCFA_URL}/cloudapi/vcf/providerGateways"
    
    params = {
        "page": 1,
        "pageSize": 25
    }
    
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json;version=9.0.0"
    }
    
    res = requests.get(url, headers=headers, params=params, verify=False)
    
    if res.status_code == 200:
        gateways = res.json().get("values", [])
        
        for gw in gateways:
            if gw.get("name") == gateway_name:
                urn = gw.get("id")
                print(f"[+] Found explicit Provider Gateway URN: {urn}")
                return urn
                
        # Lab Fallback: If naming is slightly off but there is only one T0 registered
        if len(gateways) == 1:
            urn = gateways[0].get("id")
            print(f"[+] Defaulting to the only registered Provider Gateway URN: {urn}")
            return urn
            
        print(f"[-] Provider Gateway '{gateway_name}' not found in API response.")
        return None
    else:
        print(f"[-] Failed to fetch Provider Gateways: {res.status_code} {res.text}")
        return None

def get_org_admin_role_id(token, org_id):
    print(f"\n[*] Fetching URN for 'Organization Administrator' Role...")
    
    # We must query the roles specific to this tenant
    url = f"{VCFA_URL}/cloudapi/1.0.0/roles"
    
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json;version=9.0.0",
        # We must set the context to the tenant to see the tenant's roles
        "X-VMWARE-VCLOUD-TENANT-CONTEXT": org_id 
    }
    
    # We can use FIQL to filter directly for the role name to save processing
    params = {
        "filter": "name==Organization Administrator"
    }
    
    res = requests.get(url, headers=headers, params=params, verify=False)
    
    if res.status_code == 200:
        roles = res.json().get("values", [])
        if roles:
            role_urn = roles[0].get("id")
            print(f"[+] Found Role URN: {role_urn}")
            return role_urn
            
        print("[-] Role 'Organization Administrator' not found in tenant.")
        return None
    else:
        print(f"[-] Failed to fetch Roles: {res.status_code} {res.text}")
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
        "description": "VCF 9 Region for us-east",
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
        "name": ORG_NAME,
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
        "orgNameForLogs": "cldorg-A" 
    }
    
    # Settings endpoints in VCFA typically use PUT
    res = requests.put(url, headers=headers, json=payload, verify=False)
    
    if res.status_code in [200, 201, 202, 204]:
        print("[+] Org Networking Tenancy successfully enabled.")
    else:
        print(f"[-] Failed to enable Org networking: {res.status_code} {res.text}")
        sys.exit(1)

def configure_regional_networking(token, org_id, region_urn, gw_urn):
    print(f"\n[4] Binding Regional Networking (VPC Setup)...")
    
    url = f"{VCFA_URL}/cloudapi/vcf/regionalNetworkingSettings"
    
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json;version=9.0.0",
        "Content-Type": "application/json;version=9.0.0"
    }

    PROVIDER_GATEWAY_NAME = "wld01-t0-gw" 
    
    payload = {
        # Leaving 'name' unset per doc to let VCFA auto-generate it
        "regionRef": {
            "name": "us-east",
            "id": region_urn
        },
        "orgRef": {
            "name": ORG_NAME,
            "id": org_id
        },
        "providerGatewayRef": {
            "name": PROVIDER_GATEWAY_NAME,
            "id": gw_urn
        }
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
        "Content-Type": "application/json;version=9.0.0",
    }
    
    # An empty quotaPoolDefinitions array generally translates to "No Limits" in VCFA
    quota_payload = {
        "name": "Quota-Cloud-Org-A",
        "description": "Cluster-available regional quota for sovereign tenant",
        "orgID": org_id,
        "quotaPoolDefinitions": [
            {
            "resourceType": "cpu",
            "quota": 30000,
            "quotaResourceUnit": "MHz"
            },
            {
            "resourceType": "memory",
            "quota": 88064,
            "quotaResourceUnit": "MB"
            },
            {
            "resourceType": "storage",
            "quota": 2306048,
            "quotaResourceUnit": "MB"
            }
        ]
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

def create_org_admin(token, org_id, role_urn):
    print(f"\n[6] Creating First User with Org Admin Role...")
    
    user_url = f"{VCFA_URL}/cloudapi/1.0.0/users"
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json;version=9.0.0",
        "Content-Type": "application/json;version=9.0.0",
        # Ensure we are creating the user INSIDE the tenant context
        "X-VMWARE-VCLOUD-TENANT-CONTEXT": org_id
    }
    
    user_payload = {
        "username": "cloud-org-a_admin",
        "password": "VMware123!VMware123!", 
        "fullName": "Cloud Org A Administrator",
        "orgEntityRef": {
            "id": org_id
        },
        "enabled": True,
        "providerType": "LOCAL",
        # THE FIX: Assigning the role at the exact moment of creation
        "roleEntityRefs": [
            {
                "name": "Organization Administrator",
                "id": role_urn
            }
        ]
    }
    
    user_res = requests.post(user_url, headers=headers, json=user_payload, verify=False)
    
    if user_res.status_code in [200, 201]:
        user_urn = user_res.json().get("id")
        print(f"[+] User 'cloud-org-a_admin' successfully created and elevated!")
    else:
        print(f"[-] Failed to create user: {user_res.status_code} {user_res.text}")
        sys.exit(1)
        
if __name__ == "__main__":
    try:
        token = get_vcfa_token()
        
        # --- INFRASTRUCTURE URN LOOKUPS ---
        nsx_urn = get_nsx_manager_id(token, NSX_MANAGER)
        supervisor_urn = get_supervisor_id(token, "wld01-supervisor")
        
        if not nsx_urn or not supervisor_urn:
            print("[-] Missing core infrastructure URNs. Halting.")
            sys.exit(1)
            
        # Step 1: Define Region
        # TEMP create_vcf_region(token, nsx_urn, supervisor_urn)
        
        # --- REGION & TENANT LOOKUPS ---
        region_urn = get_region_id(token, REGION_NAME)
        
        # TEMP create_tenant_org_base(token)
        org_urn = get_org_id(token, ORG_NAME)
        
        # In a VCF lab, the Tier-0 is usually named based on the workload domain
        gw_urn = get_provider_gateway_id(token, PROVIDER_GATEWAY_NAME)
        
        if org_urn and region_urn and gw_urn:
            # Step 2: Network Tenancy & Binding
            # TEMP configure_org_networking_tenancy(token, org_urn)
            # TEMP configure_regional_networking(token, org_urn, region_urn, gw_urn)
            
            # Step 3: Quota Orchestration
            configure_org_quota(token, org_urn)
            
            # Step 4: User & Role Orchestration
            role_urn = get_org_admin_role_id(token, org_urn)
            if role_urn:
                # TEMP create_org_admin(token, org_urn, role_urn)
            else:
                print("[-] Could not find Org Admin role. Halting User Creation.")
                sys.exit(1)
            
            print(f"\n[✔] SUCCESS: Step 10 VCFA Priming is 100% Complete.")
            
        else:
            print(f"[-] Automation halted. Missing URNs for Org, Region, or Gateway.")
            sys.exit(1)
            
    except Exception as e:
        print(f"[-] Python Script Error: {e}")
        sys.exit(1)
