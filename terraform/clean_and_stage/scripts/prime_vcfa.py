import requests
import json
import urllib3
import sys
import time

# Suppress self-signed cert warnings
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

NSX_MANAGER = "nsx-wld01-a.site-a.vcf.lab"
SUPERVISOR_NAME = "wld01-supervisor"
ZONE_NAME ="z-wld-a"
REGION_NAME = "us-east"
ORG_NAME = "Cloud-Org-A"
PROVIDER_GATEWAY_NAME = "us-east-region-PG"
POLICY_NAME = "vSAN Default Storage Policy"

# VCFA Provider Credentials
VCFA_URL = "https://auto-a.site-a.vcf.lab"
PROVIDER_USER = "admin"
PROVIDER_PASS = "VMware123!VMware123!"

###################
# Helper Functions#
###################

def get_vcfa_token():
    print(f"Authenticating to VCFA ({VCFA_URL})")
    auth_url = f"{VCFA_URL}/cloudapi/1.0.0/sessions/provider"
    
    headers = {"Accept": "application/json;version=9.0.0"} 
    auth = (f"{PROVIDER_USER}@system", PROVIDER_PASS) 
    
    response = requests.post(auth_url, headers=headers, auth=auth, verify=False)
    if response.status_code != 200:
        print(f"[-] Auth failed: {response.status_code} {response.text}")
        sys.exit(1)
        
    token = response.headers.get("x-vmware-vcloud-access-token")
    if not token:
        raise ValueError("Failed to extract access token!")
    return token

def get_tenant_token(vcfa_url, tenant_user, tenant_pass, tenant_org):
    print(f"\n[*] Authenticating to VCFA as Tenant Admin ({tenant_user}@{tenant_org})...")
    
    auth_url = f"https://{vcfa_url}/cloudapi/1.0.0/sessions"
    
    headers = {"Accept": "application/json;version=9.0.0"} 
    auth = (f"{tenant_user}@{tenant_org}", tenant_pass) 
    
    response = requests.post(auth_url, headers=headers, auth=auth, verify=False)
    if response.status_code == 200:
        token = response.headers.get("x-vmware-vcloud-access-token")
        print("[+] Tenant authentication successful!")
        return token
    else:
        print(f"[-] Tenant Auth failed: {response.status_code} {response.text}")
        return None

def get_org_id(token, org_name):
    print(f"\n[*] Fetching URN for Tenant: {org_name}...")
    
    url = f"{VCFA_URL}/cloudapi/1.0.0/orgs"
    
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json;version=9.0.0"
    }
    
    res = requests.get(url, headers=headers, verify=False)
    
    if res.status_code == 200:
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
    params = {"page": 1, "pageSize": 25}
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json;version=9.0.0" 
    }
    
    res = requests.get(url, headers=headers, params=params, verify=False)
    
    if res.status_code == 200:
        managers = res.json().get("values", [])
        for m in managers:
            if m.get("name") == nsx_hostname or nsx_hostname in m.get("url", ""):
                urn = m.get("id")
                print(f"[+] Found explicit NSX Manager URN: {urn}")
                return urn
                
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
    params = {"page": 1, "pageSize": 25}
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json;version=9.0.0" 
    }
    
    res = requests.get(url, headers=headers, params=params, verify=False)
    
    if res.status_code == 200:
        supervisors = res.json().get("values", [])
        for s in supervisors:
            if s.get("name") == supervisor_name:
                urn = s.get("supervisorId")
                print(f"[+] Found explicit Supervisor URN: {urn}")
                return urn
                
        if len(supervisors) == 1:
            urn = supervisors[0].get("supervisorId")
            print(f"[+] Defaulting to the only registered Supervisor URN: {urn}")
            return urn
            
        print(f"[-] Supervisor '{supervisor_name}' not found in API response.")
        return None
    else:
        print(f"[-] Failed to fetch Supervisors: {res.status_code} {res.text}")
        return None
        
def get_zone_id(token, zone_name):
    print(f"\n[*] Fetching URN for Zone: {zone_name}...")
    url = f"{VCFA_URL}/cloudapi/vcf/zones"
    params = {"page": 1, "pageSize": 25}
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json;version=9.0.0"
    }
    
    res = requests.get(url, headers=headers, params=params, verify=False)
    
    if res.status_code == 200:
        zones = res.json().get("values", [])
        for z in zones:
            if z.get("name") == zone_name:
                urn = z.get("id")
                print(f"[+] Found Zone URN: {urn}")
                return urn
                
        if len(zones) == 1:
            urn = zones[0].get("id")
            print(f"[+] Defaulting to the only registered Zone URN: {urn}")
            return urn
            
        print(f"[-] Zone '{zone_name}' not found.")
        return None
    else:
        print(f"[-] Failed to fetch Zones: {res.status_code} {res.text}")
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
    params = {"page": 1, "pageSize": 25}
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
                
        if len(gateways) == 1:
            urn = gateways[0].get("id")
            print(f"[+] Defaulting to the only registered Provider Gateway URN: {urn}")
            return urn
            
        print(f"[-] Provider Gateway '{gateway_name}' not found in API response.")
        return None
    else:
        print(f"[-] Failed to fetch Provider Gateways: {res.status_code} {res.text}")
        return None

def get_vdc_id(token, vdc_name):
    print(f"[*] Waiting for VDC '{vdc_name}' to become READY (This may take a minute)...", end="", flush=True)
    url = f"{VCFA_URL}/cloudapi/vcf/virtualDatacenters"
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json;version=9.0.0"
    }
    
    max_retries = 24
    for attempt in range(max_retries):
        res = requests.get(url, headers=headers, verify=False)
        if res.status_code == 200:
            vdcs = res.json().get("values", [])
            for vdc in vdcs:
                if vdc.get("name") == vdc_name:
                    status = vdc.get("status", "UNKNOWN")
                    if status in ["READY", "NORMAL"]:
                        urn = vdc.get("id")
                        print(f"\n[+] VDC is {status}! URN: {urn}")
                        return urn
                    else:
                        print(".", end="", flush=True)
                        break 
        time.sleep(5)
        
    print(f"\n[-] VDC '{vdc_name}' did not reach READY state in time. Check VCFA UI.")
    return None

def get_region_storage_policy_id(token, policy_name):
    print(f"\n[*] Fetching URN for Region Storage Policy: {policy_name}...")
    url = f"{VCFA_URL}/cloudapi/vcf/regionStoragePolicies"
    params = {"page": 1, "pageSize": 25}
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json;version=9.0.0"
    }
    
    res = requests.get(url, headers=headers, params=params, verify=False)
    if res.status_code == 200:
        policies = res.json().get("values", [])
        for p in policies:
            if p.get("name") == policy_name:
                urn = p.get("id")
                print(f"[+] Found Region Storage Policy URN: {urn}")
                return urn
                
        if len(policies) == 1:
            urn = policies[0].get("id")
            print(f"[+] Defaulting to the only registered Storage Policy URN: {urn}")
            return urn
            
        print(f"[-] Storage Policy '{policy_name}' not found.")
        return None
    else:
        print(f"[-] Failed to fetch Region Storage Policies: {res.status_code} {res.text}")
        return None    

def get_all_vm_classes(token):
    print(f"\n[*] Fetching all available VM Classes via VCF CloudAPI...")
    url = f"{VCFA_URL}/cloudapi/vcf/virtualMachineClasses"
    params = {"page": 1, "pageSize": 128}
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json;version=9.0.0" 
    }
    
    res = requests.get(url, headers=headers, params=params, verify=False)
    if res.status_code == 200:
        classes = res.json().get("values", [])
        print(f"[+] Found {len(classes)} VM Classes available for binding.")
        return classes
    else:
        print(f"[-] Failed to fetch VM Classes: {res.status_code} {res.text}")
        return []

def get_org_admin_role_id(token, org_id):
    print(f"\n[*] Fetching URN for 'Organization Administrator' Role...")
    url = f"{VCFA_URL}/cloudapi/1.0.0/roles"
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json;version=9.0.0",
        "X-VMWARE-VCLOUD-TENANT-CONTEXT": org_id 
    }
    params = {"filter": "name==Organization Administrator"}
    
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
# Creation Functions #
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
        "nsxManager": {"name": NSX_MANAGER, "id": nsx_urn},
        "supervisors": [{"name": "wld01-supervisor", "id": supervisor_urn}],
        "storagePolicies": ["vSAN Default Storage Policy"]
    }
    
    res = requests.post(url, headers=headers, json=payload, verify=False)
    
    if res.status_code in [200, 201, 202, 204]:
        print("[+] Region 'us-east' successfully defined in VCFA.")
    elif res.status_code == 400 and ("already associated" in res.text or "already exists" in res.text.lower()):
        print("[~] Region 'us-east' already exists. Skipping creation.")
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
    elif res.status_code == 400 and ("already exists" in res.text.lower() or "duplicate" in res.text.lower()):
        print("[~] Base Tenant 'Cloud Org A' already exists. Skipping creation.")
    else:
        print(f"[-] Failed to create base tenant: {res.status_code} {res.text}")
        sys.exit(1)

def configure_org_networking_tenancy(token, org_id):
    print(f"\n[3] Enabling NSX Network Tenancy for Org...")
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
    
    res = requests.put(url, headers=headers, json=payload, verify=False)
    
    if res.status_code in [200, 201, 202, 204]:
        print("[+] Org Networking Tenancy successfully enabled.")
    else:
        print(f"[~] Warning: Org Networking Tenancy might already be locked (HTTP {res.status_code}). Skipping.")

def configure_regional_networking(token, org_id, region_urn, gw_urn):
    print(f"\n[4] Binding Regional Networking (VPC Setup)...")
    url = f"{VCFA_URL}/cloudapi/vcf/regionalNetworkingSettings"
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json;version=9.0.0",
        "Content-Type": "application/json;version=9.0.0"
    }

    payload = {
        "regionRef": {"name": "us-east", "id": region_urn},
        "orgRef": {"name": ORG_NAME, "id": org_id},
        "providerGatewayRef": {"name": PROVIDER_GATEWAY_NAME, "id": gw_urn}
    }
    
    res = requests.post(url, headers=headers, json=payload, verify=False)
    
    if res.status_code in [200, 201, 202, 204]:
        print(f"[+] Regional Networking bound to Provider Gateway: {PROVIDER_GATEWAY_NAME}")
    elif res.status_code in [400, 403, 409]:
        print(f"[~] Regional Networking already bound or conflicting (HTTP {res.status_code}). Skipping.")
    else:
        print(f"[-] Failed to bind regional networking: {res.status_code} {res.text}")

def create_virtual_datacenter(token, org_urn, region_urn, supervisor_urn, zone_urn):
    print(f"\n[5A] Slicing Supervisor Resources (Creating Virtual Datacenter)...")
    url = f"{VCFA_URL}/cloudapi/vcf/virtualDatacenters"
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json;version=9.0.0",
        "Content-Type": "application/json;version=9.0.0"
    }
    
    VDC_NAME = "Cloud-Org-A-VDC"
    
    payload = {
        "name": VDC_NAME,
        "description": "VDC Resource boundary for Cloud Org A",
        "org": {"id": org_urn},
        "region": {"id": region_urn},
        "supervisors": [{"id": supervisor_urn}],
        "zoneResourceAllocation": [
            {
                "zone": {"id": zone_urn},
                "resourceAllocation": {
                    "cpuLimitMHz": 30000,
                    "memoryLimitMiB": 88064,
                    "cpuReservationMHz": 0,
                    "memoryReservationMiB": 0
                }
            }
        ]
    }
    
    res = requests.post(url, headers=headers, json=payload, verify=False)
    
    if res.status_code in [200, 201, 202, 204]:
        print(f"[+] VDC Creation Task Accepted (HTTP {res.status_code}).")
    elif res.status_code in [400, 403, 409] and "already exists" in res.text.lower():
        print(f"[~] VDC '{VDC_NAME}' already exists. Skipping creation.")
    else:
        print(f"[!] VDC Creation returned HTTP {res.status_code}. It may already exist. Proceeding...")
        
    return VDC_NAME

def create_vdc_storage_policy(token, vdc_urn, policy_urn):
    print(f"\n[5B] Binding vSAN Storage Policy to VDC...")
    url = f"{VCFA_URL}/cloudapi/vcf/virtualDatacenterStoragePolicies"
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json;version=9.0.0",
        "Content-Type": "application/json;version=9.0.0"
    }
    
    payload = {
        "values": [
            {
                "name": "Cloud-Org-A-vSAN-Policy",
                "virtualDatacenter": {"id": vdc_urn},
                "regionStoragePolicy": {"id": policy_urn},
                "storageLimitMiB": 2306048 
            }
        ]
    }
    
    res = requests.post(url, headers=headers, json=payload, verify=False)
    
    if res.status_code in [200, 201, 202, 204]:
        print("[+] Storage Policy successfully bound to VDC!")
    else:
        print(f"[~] Storage Policy binding returned HTTP {res.status_code} (Likely already bound). Skipping.")

def enable_all_vdc_vm_classes(token, vdc_urn, available_classes):
    print(f"\n[5C] Binding all VM Classes to Virtual Datacenter...")
    url = f"{VCFA_URL}/cloudapi/v1/virtualDatacenters/{vdc_urn}/virtualMachineClasses"
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json;version=9.0.0",
        "Content-Type": "application/json;version=9.0.0"
    }
    
    payload = {
        "values": [{"id": c.get("id")} for c in available_classes]
    }
    
    res = requests.put(url, headers=headers, json=payload, verify=False)
    
    if res.status_code in [200, 201, 202, 204]:
        print("[+] Successfully enabled all VM Classes on the VDC!")
    else:
        print(f"[~] VM Classes binding returned HTTP {res.status_code} (Likely already bound). Skipping.")

def create_org_admin(token, org_id, role_urn):
    print(f"\n[6] Creating First User with Org Admin Role...")
    user_url = f"{VCFA_URL}/cloudapi/1.0.0/users"
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json;version=9.0.0",
        "Content-Type": "application/json;version=9.0.0",
        "X-VMWARE-VCLOUD-TENANT-CONTEXT": org_id
    }
    
    user_payload = {
        "username": "cloud-org-a_admin",
        "password": "VMware123!VMware123!", 
        "fullName": "Cloud Org A Administrator",
        "orgEntityRef": {"id": org_id},
        "enabled": True,
        "providerType": "LOCAL",
        "roleEntityRefs": [{"name": "Organization Administrator", "id": role_urn}]
    }
    
    user_res = requests.post(user_url, headers=headers, json=user_payload, verify=False)
    
    if user_res.status_code in [200, 201]:
        print(f"[+] User 'cloud-org-a_admin' successfully created and elevated!")
    elif user_res.status_code in [400, 403, 409] and "already exists" in user_res.text.lower():
        print(f"[~] User 'cloud-org-a_admin' already exists. Skipping.")
    else:
        print(f"[~] Failed to create user (HTTP {user_res.status_code}). They may already exist.")
        
def configure_and_sync_ldap(vcfa_url, token, org_id, ldap_ip, ldap_password):
    print(f"\n[*] Configuring Custom OpenLDAP Directory for Tenant...")
    org_uuid = org_id.split(':')[-1]
    api_url = f"https://{vcfa_url}/api/admin/org/{org_uuid}/settings/ldap" 
    
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/*+json;version=9.0.0",
        "Content-Type": "application/*+json",
        "X-vCloud-Authorization": ORG_NAME,
        "X-VMWARE-VCLOUD-AUTH-CONTEXT": ORG_NAME,
        "X-VMWARE-VCLOUD-TENANT-CONTEXT": org_uuid
    }

    ldap_payload = {
        "customOrgLdapSettings": {
            "authenticationMechanism": "SIMPLE",
            "connectorType": "OPEN_LDAP",
            "customUiButtonLabel": None,
            "groupAttributes": {
                "backLinkIdentifier": "",
                "groupName": "cn",
                "membership": "member",
                "membershipIdentifier": "dn",
                "objectClass": "groupOfNames",
                "objectIdentifier": "cn",
                "vCloudExtension": []
            },
            "hostName": ldap_ip,
            "isGroupSearchBaseEnabled": False,
            "isSsl": False,
            "password": ldap_password,
            "port": 389,
            "searchBase": "ou=Cloud Org A,dc=vcf,dc=lab",
            "userAttributes": {
                "email": "mail",
                "fullName": "displayName",
                "givenName": "givenName",
                "groupBackLinkIdentifier": "",
                "groupMembershipIdentifier": "dn",
                "objectClass": "inetOrgPerson",
                "objectIdentifier": "entryUUID",
                "surname": "sn",
                "telephone": "telephoneNumber",
                "userName": "uid",
                "vCloudExtension": []
            },
            "userName": "cn=admin,dc=vcf,dc=lab",
            "vCloudExtension": []
        },
        "link": [],
        "orgLdapMode": "CUSTOM",
        "vCloudExtension": []
    }

    try:
        response = requests.put(api_url, headers=headers, json=ldap_payload, verify=False)
        response.raise_for_status()
        print(f"[+] Tenant LDAP settings saved successfully (HTTP 200)!")
        
        print(f"[*] Triggering Directory Sync to import Users and Groups...")
        sync_url = f"https://{vcfa_url}/cloudapi/1.0.0/ldap/sync"
        sync_headers = {
            "Authorization": f"Bearer {token}",
            "Accept": "application/json;version=41.0.0-alpha",
            "Content-Type": "application/json",
            "X-VMWARE-VCLOUD-AUTH-CONTEXT": "Cloud-Org-A",
            "X-VMWARE-VCLOUD-TENANT-CONTEXT": org_uuid
        }
        
        try:
            sync_resp = requests.post(sync_url, headers=sync_headers, verify=False)
            if sync_resp.status_code in [200, 202, 204]:
                print("[+] Sync triggered successfully. Waiting 15 seconds for VCFA to process objects...")
                time.sleep(15)
            else:
                print(f"[!] Warning: Sync endpoint returned {sync_resp.status_code}. You may need to click 'Sync' manually.")
                time.sleep(5)
        except Exception as sync_e:
            print(f"[!] Warning: API auto-sync failed ({sync_e}).")
            time.sleep(5)
            
    except requests.exceptions.RequestException as e:
        print(f"[-] FATAL: Could not configure LDAP via API: {e}")

def import_org_groups(vcfa_url, token, org_id):
    print(f"\n[*] Importing LDAP Groups into Tenant Organization...")
    org_uuid = org_id.split(':')[-1]
    
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/json;version=9.0.0",
        "Content-Type": "application/json",
        "X-VMWARE-VCLOUD-AUTH-CONTEXT": "Cloud-Org-A",
        "X-VMWARE-VCLOUD-TENANT-CONTEXT": org_uuid
    }

    roles_url = f"https://{vcfa_url}/cloudapi/1.0.0/roles"
    role_urn = "urn:vcloud:role:a649ae37-4c6a-5cd3-a0a1-cea773358ee4" 
    
    res = requests.get(roles_url, headers=headers, params={"filter": "name==Organization User"}, verify=False)
    if res.status_code == 200 and res.json().get("values"):
        role_urn = res.json()["values"][0]["id"]

    groups_to_import = [
        "tenant123_project_admin", "tenant123_project_adv_user", "tenant123_project_user",
        "tenant456_project_admin", "tenant456_project_adv_user", "tenant456_project_user"
    ]
    
    groups_url = f"https://{vcfa_url}/cloudapi/1.0.0/groups"
    
    for group in groups_to_import:
        payload = {
            "description": "Imported via Automation",
            "name": group,
            "providerType": "LDAP",
            "roleEntityRefs": [{"id": role_urn, "name": "Organization User"}]
        }
        post_res = requests.post(groups_url, headers=headers, json=payload, verify=False)
        
        if post_res.status_code in [200, 201, 202]:
            print(f"    [+] Imported group: {group}")
        elif post_res.status_code == 400 and "already exists" in post_res.text.lower():
            print(f"    [~] Group already imported: {group}")
        else:
            print(f"    [-] Failed to import {group}: {post_res.status_code} {post_res.text}")

def assign_project_roles(vcfa_url, tenant_token):
    print(f"\n[*] Assigning Groups to Projects as Tenant Admin...")
    headers = {
        "Authorization": f"Bearer {tenant_token}",
        "Content-Type": "application/json"
    }

    projects_url = f"https://{vcfa_url}/project-service/api/projects"
    
    try:
        resp = requests.get(projects_url, headers=headers, verify=False)
        resp.raise_for_status()
    except requests.exceptions.RequestException as e:
        print(f"[-] Failed to fetch projects: {e}")
        return

    projects = resp.json().get("content", [])
    
    tenant_mappings = {
        "tenant-123": [
            {"email": "tenant123_project_admin@", "role": "administrator", "type": "group"},
            {"email": "tenant123_project_adv_user@", "role": "advanced_user", "type": "group"},
            {"email": "tenant123_project_user@", "role": "user", "type": "group"}
        ],
        "tenant-456": [
            {"email": "tenant456_project_admin@", "role": "administrator", "type": "group"},
            {"email": "tenant456_project_adv_user@", "role": "advanced_user", "type": "group"},
            {"email": "tenant456_project_user@", "role": "user", "type": "group"}
        ]
    }

    safe_mappings = {k.lower(): v for k, v in tenant_mappings.items()}

    for proj in projects:
        proj_name = proj.get("name", "")
        proj_id = proj.get("id")
        
        if proj_name.lower() in safe_mappings:
            print(f"    -> Match Found! Patching roles for project: {proj_name}")
            patch_url = f"https://{vcfa_url}/project-service/api/projects/{proj_id}/principals"
            
            patch_payload = {
                "modify": safe_mappings[proj_name.lower()],
                "remove": []
            }
            
            patch_resp = requests.patch(patch_url, headers=headers, json=patch_payload, verify=False)
            
            if patch_resp.status_code in [200, 204]:
                print(f"       [+] Success: Assigned roles for {proj_name}")
            else:
                print(f"       [!] Failed to patch {proj_name}: HTTP {patch_resp.status_code}")
     
if __name__ == "__main__":
    try:
        if len(sys.argv) > 1:
            ldap_ip = sys.argv[1]
            print(f"[*] Received LDAP VIP from Bash: {ldap_ip}")
        else:
            print("[-] No LDAP IP provided! Halting execution.")
            sys.exit(1)
        
        token = get_vcfa_token()
        
        # --- INFRASTRUCTURE URN LOOKUPS ---
        nsx_urn = get_nsx_manager_id(token, NSX_MANAGER)
        supervisor_urn = get_supervisor_id(token, "wld01-supervisor")
        
        if not nsx_urn or not supervisor_urn:
            print("[-] Missing core infrastructure URNs. Halting.")
            sys.exit(1)
            
        # ==============================================================
        # THE FIX: Check-Then-Act Logic for Core Deployments
        # ==============================================================
        
        # Step 1: Define Region (Idempotent Check)
        region_urn = get_region_id(token, REGION_NAME)
        if not region_urn:
            create_vcf_region(token, nsx_urn, supervisor_urn)
            region_urn = get_region_id(token, REGION_NAME) # Fetch again to get the new URN
            
        # Step 2: Create Tenant Org (Idempotent Check)
        org_urn = get_org_id(token, ORG_NAME)
        if not org_urn:
            create_tenant_org_base(token)
            org_urn = get_org_id(token, ORG_NAME) # Fetch again to get the new URN
        
        # Provider Gateway Lookup
        gw_urn = get_provider_gateway_id(token, PROVIDER_GATEWAY_NAME)
        
        if org_urn and region_urn and gw_urn:
            
            # Step 3: Network Tenancy & Binding (Now strictly soft-failing)
            configure_org_networking_tenancy(token, org_urn)
            configure_regional_networking(token, org_urn, region_urn, gw_urn)
            
            # Step 4: Regional Quota - VDC Creation
            zone_urn = get_zone_id(token, ZONE_NAME)
            
            if not zone_urn:
                print("[-] Could not retrieve Zone URN. Halting VDC Creation.")
                sys.exit(1)
                
            vdc_name = create_virtual_datacenter(token, org_urn, region_urn, supervisor_urn, zone_urn)
            
            # This safely loops until the VDC exists AND is ready
            vdc_urn = get_vdc_id(token, vdc_name)
            
            if vdc_urn:
                policy_urn = get_region_storage_policy_id(token, POLICY_NAME)
                if not policy_urn:
                    print("[-] Could not retrieve Storage Policy URN. Halting.")
                    sys.exit(1)
                    
                create_vdc_storage_policy(token, vdc_urn, policy_urn)

                all_classes = get_all_vm_classes(token)
                if all_classes:
                    enable_all_vdc_vm_classes(token, vdc_urn, all_classes)
                else:
                    print("[-] No VM classes found to bind, or fetch failed.")
                    sys.exit(1)
            else:
                print("[-] Could not retrieve VDC URN. Storage and Compute mapping aborted.")
                sys.exit(1)
            
            # Step 5: User & Role Orchestration
            role_urn = get_org_admin_role_id(token, org_urn)
            if role_urn:
                create_org_admin(token, org_urn, role_urn)
            else:
                print("[-] Could not find Org Admin role. Halting User Creation.")
                sys.exit(1)
            
            # Step 6: Configure and Sync LDAP for example Org
            print(f"\n[*] Executing LDAP Integration for Tenants...")
            clean_vcfa_fqdn = VCFA_URL.replace("https://", "")
            configure_and_sync_ldap(clean_vcfa_fqdn, token, org_urn, ldap_ip, "VMware123!")
            import_org_groups(clean_vcfa_fqdn, token, org_urn)
            
            tenant_token = get_tenant_token(VCFA_URL.replace("https://", ""), "cloud-org-a_admin", "VMware123!VMware123!", "Cloud-Org-A")
            
            if tenant_token:
                # Patch the Projects (Using the Tenant Token!)
                assign_project_roles(VCFA_URL.replace("https://", ""), tenant_token)
                print(f"\n[✔] SUCCESS: Step 12 VCFA Priming is 100% Complete.")
            else:
                print("\n[-] FATAL: Could not authenticate as Tenant Admin to assign project roles.")
                sys.exit(1)

        else:
            print(f"[-] Automation halted. Missing URNs for Org, Region, or Gateway.")
            sys.exit(1)

    except Exception as e:
        print(f"[-] Python Script Error: {e}")
        sys.exit(1)
