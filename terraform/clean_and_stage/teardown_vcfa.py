import requests
import urllib3
import time
import sys

# Suppress insecure request warnings for the lab environment
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# --- Configuration Variables ---
# VCFA Provider
PROVIDER_URL = "https://auto-a.site-a.vcf.lab"
PROVIDER_USER = "admin"
PROVIDER_PASS = "VMware123!VMware123!"

# VCFA Tenant
TENANT_URL = "https://auto-a.site-a.vcf.lab"
TENANT_ORG = "all-apps"
TENANT_USER = "all-apps-admin"
TENANT_PASS = "VMware123!VMware123!"

# vCenter
VCENTER_URL = "https://vc-wld01-a.site-a.vcf.lab"
VCENTER_USER = "administrator@wld.sso"
VCENTER_PASS = "VMware123!VMware123!"
CLUSTER_ID = "cluster-wld01-01a"

# Timers
TIMEOUT_SECONDS = 1200
POLL_INTERVAL = 30

# --- Helper Functions ---

def get_vcfa_provider_token(url, username, password):
    """Authenticate to VCF 9 Provider API and return a bearer token."""
    auth_url = f"{url}/cloudapi/1.0.0/sessions/provider"
    headers = {"Accept": "application/json;version=9.0.0"}
    auth = (f"{username}@system", password) # VCF 9 Provider format
    
    response = requests.post(auth_url, headers=headers, auth=auth, verify=False)
    response.raise_for_status()
    # In VCF 9, the token is returned in this specific header
    return response.headers.get("x-vmware-vcloud-access-token")

def get_vcfa_tenant_token(url, username, password, org_name):
    """Authenticate to VCF 9 Tenant API and return a bearer token."""
    auth_url = f"{url}/cloudapi/1.0.0/sessions"
    headers = {"Accept": "application/json;version=9.0.0"}
    auth = (f"{username}@{org_name}", password) # VCF 9 Tenant format
    
    response = requests.post(auth_url, headers=headers, auth=auth, verify=False)
    response.raise_for_status()
    return response.headers.get("x-vmware-vcloud-access-token")

def get_vcenter_session(url, username, password):
    """Authenticate to vCenter REST API and return a session ID."""
    auth_url = f"{url}/api/session"
    response = requests.post(auth_url, auth=(username, password), verify=False)
    response.raise_for_status()
    return response.json()

def get_resource_id(api_url, headers, target_name, name_key="name"):
    """
    GETs a list of resources and searches for a specific name.
    Returns the UUID if found, or None if it doesn't exist.
    """
    response = requests.get(api_url, headers=headers, verify=False)
    if response.status_code == 404:
        return None
    response.raise_for_status()
    
    data = response.json()
    # Support both IaaS API ("content") and CloudAPI ("values") array structures
    items = data.get("values", data.get("content", data)) if isinstance(data, dict) else data
    
    for item in items:
        if isinstance(item, dict) and item.get(name_key) == target_name:
            return item.get("id")
    return None

def wait_for_deletion(check_url, headers, resource_name):
    """Poll an endpoint until it returns a 404 (Not Found)."""
    print(f"[*] Polling: Waiting for {resource_name} to be completely removed...")
    start_time = time.time()
    
    while (time.time() - start_time) < TIMEOUT_SECONDS:
        response = requests.get(check_url, headers=headers, verify=False)
        if response.status_code == 404:
            print(f"[+] Success: {resource_name} successfully deleted.\n")
            return True
        elif response.status_code >= 400 and response.status_code != 403:
            print(f"[-] Error during polling: {response.status_code} - {response.text}")
            sys.exit(1)
            
        print(f"    [{int(time.time() - start_time)}s elapsed] Still exists. Waiting {POLL_INTERVAL}s...")
        time.sleep(POLL_INTERVAL)
        
    print(f"[-] Timeout Error: {resource_name} was not deleted within {TIMEOUT_SECONDS} seconds.")
    sys.exit(1)

# --- Execution Steps ---

def main():
    print("=== Starting Idempotent VCF 9 & vCenter Teardown ===\n")
    
    # 0. Authenticate
    print("[*] Authenticating to APIs...")
    tenant_token = get_vcfa_tenant_token(TENANT_URL, TENANT_USER, TENANT_PASS, TENANT_ORG)
    provider_token = get_vcfa_provider_token(PROVIDER_URL, PROVIDER_USER, PROVIDER_PASS)
    vc_session = get_vcenter_session(VCENTER_URL, VCENTER_USER, VCENTER_PASS)
    
    tenant_headers = {"Authorization": f"Bearer {tenant_token}", "Content-Type": "application/json"}
    provider_headers = {"Authorization": f"Bearer {provider_token}", "Content-Type": "application/json"}
    vc_headers = {"vmware-api-session-id": vc_session, "Content-Type": "application/json"}
    
    # Required for the new VCF 9 CloudAPI Org endpoints
    cloudapi_provider_headers = provider_headers.copy()
    cloudapi_provider_headers["Accept"] = "application/json;version=40.0"
    
    print("[+] Authentication successful.\n")

    # 1. Remove Tenant Namespace
    print("--- Step 1: Removing Tenant Namespace ---")
    ns_name = "demo-namespace-3qdtf"
    ns_list_url = f"{TENANT_URL}/iaas/api/namespaces"
    ns_id = get_resource_id(ns_list_url, tenant_headers, ns_name)
    
    if ns_id:
        print(f"[*] Found Namespace '{ns_name}' with ID: {ns_id}. Deleting...")
        ns_url = f"{ns_list_url}/{ns_id}"
        requests.delete(ns_url, headers=tenant_headers, verify=False)
        wait_for_deletion(ns_url, tenant_headers, "Tenant Namespace")
    else:
        print(f"[+] Namespace '{ns_name}' not found. Already deleted. Skipping.\n")

    # 2. Remove Content Library
    print("--- Step 2: Removing Content Library ---")
    cl_name = "provider-content-library"
    cl_list_url = f"{PROVIDER_URL}/iaas/api/content-libraries" 
    cl_id = get_resource_id(cl_list_url, provider_headers, cl_name)
    
    if cl_id:
        print(f"[*] Found Content Library '{cl_name}' with ID: {cl_id}. Deleting...")
        cl_url = f"{cl_list_url}/{cl_id}"
        requests.delete(cl_url, headers=provider_headers, verify=False)
        wait_for_deletion(cl_url, provider_headers, "Content Library")
    else:
        print(f"[+] Content Library '{cl_name}' not found. Already deleted. Skipping.\n")

    # 3. Delete Regional Networking Config
    print("--- Step 3: Deleting Regional Networking Config ---")
    net_name = "all-appsus-west-region"
    net_list_url = f"{PROVIDER_URL}/iaas/api/network-profiles"
    net_id = get_resource_id(net_list_url, provider_headers, net_name)
    
    if net_id:
        print(f"[*] Found Regional Networking '{net_name}' with ID: {net_id}. Deleting...")
        net_url = f"{net_list_url}/{net_id}"
        requests.delete(net_url, headers=provider_headers, verify=False)
        wait_for_deletion(net_url, provider_headers, "Regional Networking")
    else:
        print(f"[+] Regional Networking '{net_name}' not found. Already deleted. Skipping.\n")

    # 4. Delete Regional Quota
    print("--- Step 4: Deleting Regional Quota ---")
    quota_name = "us-west-region"
    quota_list_url = f"{PROVIDER_URL}/iaas/api/fabric-compute-reservations"
    quota_id = get_resource_id(quota_list_url, provider_headers, quota_name)
    
    if quota_id:
        print(f"[*] Found Regional Quota '{quota_name}' with ID: {quota_id}. Deleting...")
        quota_url = f"{quota_list_url}/{quota_id}"
        requests.delete(quota_url, headers=provider_headers, verify=False)
        wait_for_deletion(quota_url, provider_headers, "Regional Quota")
    else:
        print(f"[+] Regional Quota '{quota_name}' not found. Already deleted. Skipping.\n")

    # 5. Disable and Delete Tenant Org (VCF 9 CloudAPI)
    print("--- Step 5: Disabling and Deleting Tenant Org ---")
    org_list_url = f"{PROVIDER_URL}/cloudapi/1.0.0/orgs"
    org_id = get_resource_id(org_list_url, cloudapi_provider_headers, TENANT_ORG)
    
    if org_id:
        print(f"[*] Found Tenant Org '{TENANT_ORG}' with ID {org_id}.")
        org_url = f"{org_list_url}/{org_id}"
        
        # In VCF 9 (VCD-based), orgs typically must be disabled before deletion
        org_data = requests.get(org_url, headers=cloudapi_provider_headers, verify=False).json()
        if org_data.get("isEnabled", True):
            print(f"[*] Disabling Tenant Org '{TENANT_ORG}'...")
            org_data["isEnabled"] = False
            requests.put(org_url, headers=cloudapi_provider_headers, json=org_data, verify=False)
            time.sleep(5) # Brief pause to allow disable state to settle
            
        print(f"[*] Deleting Tenant Org '{TENANT_ORG}'...")
        requests.delete(org_url, headers=cloudapi_provider_headers, verify=False)
        wait_for_deletion(org_url, cloudapi_provider_headers, "Tenant Org")
    else:
        print(f"[+] Tenant Org '{TENANT_ORG}' not found. Already deleted. Skipping.\n")

    # 6. Delete vCenter Supervisor
    print("--- Step 6: Deleting vCenter Supervisor ---")
    supervisor_url = f"{VCENTER_URL}/api/vcenter/namespace-management/clusters/{CLUSTER_ID}"
    
    sup_check = requests.get(supervisor_url, headers=vc_headers, verify=False)
    if sup_check.status_code == 200:
        print(f"[*] Found Supervisor on Cluster '{CLUSTER_ID}'. Deleting...")
        requests.delete(supervisor_url, headers=vc_headers, verify=False)
        wait_for_deletion(supervisor_url, vc_headers, "vCenter Supervisor")
    else:
        print(f"[+] Supervisor on Cluster '{CLUSTER_ID}' not found/already removed. Skipping.\n")

    print("=== Teardown complete! Environment is clean and ready for Terraform. ===")

if __name__ == "__main__":
    main()
