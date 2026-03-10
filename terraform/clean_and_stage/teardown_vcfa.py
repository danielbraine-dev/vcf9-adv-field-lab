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
    headers = {"Accept": "application/json;version=40.0"} 
    auth = (f"{username}@system", password) 
    
    response = requests.post(auth_url, headers=headers, auth=auth, verify=False)
    response.raise_for_status()
    return response.headers.get("x-vmware-vcloud-access-token")

def get_vcfa_tenant_token(url, username, password, org_name):
    """Authenticate to VCF 9 Tenant API and return a bearer token."""
    auth_url = f"{url}/cloudapi/1.0.0/sessions"
    headers = {"Accept": "application/json;version=40.0"}
    auth = (f"{username}@{org_name}", password) 
    
    response = requests.post(auth_url, headers=headers, auth=auth, verify=False)
    response.raise_for_status()
    return response.headers.get("x-vmware-vcloud-access-token")

def get_vcenter_session(url, username, password):
    """Authenticate to vCenter REST API and return a session ID."""
    auth_url = f"{url}/api/session"
    response = requests.post(auth_url, auth=(username, password), verify=False)
    response.raise_for_status()
    return response.json()

def get_resource_id(api_url, headers, target_name, name_key="name", fallback_headers=None):
    """
    GETs a list of resources. Supports intelligent fallback if a 403 is hit.
    Returns a tuple of (UUID, Successful_Headers).
    """
    active_headers = headers
    response = requests.get(api_url, headers=active_headers, verify=False)
    
    if response.status_code == 403 and fallback_headers:
        active_headers = fallback_headers
        response = requests.get(api_url, headers=active_headers, verify=False)
        
    if response.status_code == 404:
        return None, active_headers
        
    response.raise_for_status()
    
    data = response.json()
    items = data.get("values", data.get("content", data.get("items", data))) if isinstance(data, dict) else data
    
    for item in items:
        if isinstance(item, dict) and item.get(name_key) == target_name:
            return item.get("id"), active_headers
            
    return None, active_headers

def wait_for_deletion_by_list(list_url, headers, target_name, resource_name, name_key="name"):
    """Poll the list endpoint until the resource name is no longer found."""
    print(f"[*] Polling: Waiting for {resource_name} to be completely removed...")
    start_time = time.time()
    
    while (time.time() - start_time) < TIMEOUT_SECONDS:
        # If get_resource_id returns None, it means the item is completely gone from the list
        item_id, _ = get_resource_id(list_url, headers, target_name, name_key)
        
        if not item_id:
            print(f"[+] Success: {resource_name} successfully deleted.\n")
            return True
            
        print(f"    [{int(time.time() - start_time)}s elapsed] Still exists. Waiting {POLL_INTERVAL}s...")
        time.sleep(POLL_INTERVAL)
        
    print(f"[-] Timeout Error: {resource_name} was not deleted within {TIMEOUT_SECONDS} seconds.")
    sys.exit(1)

# --- Execution Steps ---

def main():
    print("=== Starting Idempotent VCF 9 & vCenter Teardown ===\n")
    
    print("[*] Authenticating to APIs...")
    tenant_token = get_vcfa_tenant_token(TENANT_URL, TENANT_USER, TENANT_PASS, TENANT_ORG)
    provider_token = get_vcfa_provider_token(PROVIDER_URL, PROVIDER_USER, PROVIDER_PASS)
    vc_session = get_vcenter_session(VCENTER_URL, VCENTER_USER, VCENTER_PASS)
    
    # Standard CloudAPI Headers for VCF 9
    cloudapi_provider_headers = {
        "Authorization": f"Bearer {provider_token}", 
        "Accept": "application/json;version=40.0",
        "Content-Type": "application/json"
    }
    vc_headers = {"vmware-api-session-id": vc_session, "Content-Type": "application/json"}
    
    print("[+] Authentication successful.\n")
    
    # 1. Remove Content Library (VCF 9 CloudAPI)
    print("--- Step 1: Removing Content Library ---")
    cl_name = "provider-content-library"
    cl_list_url = f"{PROVIDER_URL}/cloudapi/vcf/contentLibraries" 
    cl_id, _ = get_resource_id(cl_list_url, cloudapi_provider_headers, cl_name)
    
    if cl_id:
        print(f"[*] Found Content Library '{cl_name}' with ID: {cl_id}. Deleting...")
        # Add the recursive and force flags to bypass the "not empty" safety check
        cl_delete_url = f"{cl_list_url}/{cl_id}?recursive=true&force=true"
        
        del_resp = requests.delete(cl_delete_url, headers=cloudapi_provider_headers, verify=False)
        
        if del_resp.status_code >= 400:
            print(f"[-] API Delete Request Failed! Status Code: {del_resp.status_code}")
            print(f"[-] VCFA Error Message: {del_resp.text}")
            sys.exit(1)
            
        wait_for_deletion_by_list(cl_list_url, cloudapi_provider_headers, cl_name, "Content Library")
    else:
        print(f"[+] Content Library '{cl_name}' not found. Already deleted. Skipping.\n")

    # 2. Remove Tenant Namespace (Using TMC CloudAPI)
    print("--- Step 2: Removing Tenant Namespace ---")
    ns_name = "demo-namespace-3qdtf"
    ns_summary_url = f"{TENANT_URL}/tm/cloudapi/v1/namespaceSummaries"
    
    tm_tenant_headers = {
        "Authorization": f"Bearer {tenant_token}", 
        "Accept": "application/json;version=40.0",
        "Content-Type": "application/json"
    }
    
    # Define the Provider equivalent for TMC endpoints
    tm_provider_headers = {
        "Authorization": f"Bearer {provider_token}", 
        "Accept": "application/json;version=40.0",
        "Content-Type": "application/json"
    }
    
    ns_id, active_ns_headers = get_resource_id(ns_summary_url, tm_tenant_headers, ns_name)
    
    if ns_id:
        print(f"[*] Found Namespace '{ns_name}' with ID: {ns_id}. Deleting...")
        ns_delete_url = f"{TENANT_URL}/tm/cloudapi/v1/namespaces/{ns_id}"
        
        # Attempt deletion with the active token (Tenant)
        del_resp = requests.delete(ns_delete_url, headers=active_ns_headers, verify=False)
        
        # If the Tenant lacks destruction rights, instantly swap to Provider token
        if del_resp.status_code == 403:
            print("    [!] Tenant lacks deletion rights. Swapping to Provider token...")
            active_ns_headers = tm_provider_headers
            del_resp = requests.delete(ns_delete_url, headers=active_ns_headers, verify=False)
            
        if del_resp.status_code >= 400:
            print(f"[-] Delete request failed: {del_resp.status_code} - {del_resp.text}")
            sys.exit(1)
            
        wait_for_deletion_by_list(ns_summary_url, active_ns_headers, ns_name, "Tenant Namespace")
    else:
        print(f"[+] Namespace '{ns_name}' not found. Already deleted. Skipping.\n")

    # 3. Delete Regional Networking Config (VCF 9 CloudAPI)
    print("--- Step 3: Deleting Regional Networking Config ---")
    net_name = "all-appsus-west-region"
    net_list_url = f"{PROVIDER_URL}/cloudapi/vcf/regionalNetworkingSettings"
    net_id, _ = get_resource_id(net_list_url, cloudapi_provider_headers, net_name)
    
    if net_id:
        print(f"[*] Found Regional Networking '{net_name}' with ID: {net_id}. Deleting...")
        net_url = f"{net_list_url}/{net_id}"
        requests.delete(net_url, headers=cloudapi_provider_headers, verify=False)
        wait_for_deletion_by_list(net_list_url, cloudapi_provider_headers, net_name, "Regional Networking")
    else:
        print(f"[+] Regional Networking '{net_name}' not found. Already deleted. Skipping.\n")

    # 4. Delete Regional Quota (VCF 9 CloudAPI Quota Policies)
    print("--- Step 4: Deleting Regional Quota ---")
    quota_name = "us-west-region"
    quota_list_url = f"{PROVIDER_URL}/cloudapi/1.0.0/quotaPolicies"
    quota_id, _ = get_resource_id(quota_list_url, cloudapi_provider_headers, quota_name)
    
    if quota_id:
        print(f"[*] Found Regional Quota '{quota_name}' with ID: {quota_id}. Deleting...")
        quota_url = f"{quota_list_url}/{quota_id}"
        requests.delete(quota_url, headers=cloudapi_provider_headers, verify=False)
        wait_for_deletion_by_list(quota_list_url, cloudapi_provider_headers, quota_name, "Regional Quota")
    else:
        print(f"[+] Regional Quota '{quota_name}' not found. Already deleted. Skipping.\n")

    # 5. Disable and Delete Tenant Org (VCF 9 CloudAPI)
    print("--- Step 5: Disabling and Deleting Tenant Org ---")
    org_list_url = f"{PROVIDER_URL}/cloudapi/1.0.0/orgs"
    org_id, _ = get_resource_id(org_list_url, cloudapi_provider_headers, TENANT_ORG)
    
    if org_id:
        print(f"[*] Found Tenant Org '{TENANT_ORG}' with ID {org_id}.")
        org_url = f"{org_list_url}/{org_id}"
        
        org_data = requests.get(org_url, headers=cloudapi_provider_headers, verify=False).json()
        if org_data.get("isEnabled", True):
            print(f"[*] Disabling Tenant Org '{TENANT_ORG}'...")
            org_data["isEnabled"] = False
            requests.put(org_url, headers=cloudapi_provider_headers, json=org_data, verify=False)
            time.sleep(5) 
            
        print(f"[*] Deleting Tenant Org '{TENANT_ORG}'...")
        requests.delete(f"{org_url}?force=true", headers=cloudapi_provider_headers, verify=False)
        wait_for_deletion_by_list(org_list_url, cloudapi_provider_headers, TENANT_ORG, "Tenant Org")
    else:
        print(f"[+] Tenant Org '{TENANT_ORG}' not found. Already deleted. Skipping.\n")

    # 6. Delete vCenter Supervisor (vCenter WCP API)
    print("--- Step 6: Deleting vCenter Supervisor ---")
    supervisor_url = f"{VCENTER_URL}/api/vcenter/namespace-management/clusters/{CLUSTER_ID}"
    
    sup_check = requests.get(supervisor_url, headers=vc_headers, verify=False)
    if sup_check.status_code == 200:
        print(f"[*] Found Supervisor on Cluster '{CLUSTER_ID}'. Deleting...")
        requests.delete(supervisor_url, headers=vc_headers, verify=False)
        
        # For vCenter, we just poll the specific endpoint for 404 since it's a cluster ID, not a name in a list
        print(f"[*] Polling: Waiting for vCenter Supervisor to be completely removed...")
        start_time = time.time()
        while (time.time() - start_time) < TIMEOUT_SECONDS:
            check_resp = requests.get(supervisor_url, headers=vc_headers, verify=False)
            if check_resp.status_code == 404:
                print(f"[+] Success: vCenter Supervisor successfully deleted.\n")
                break
            print(f"    [{int(time.time() - start_time)}s elapsed] Still exists. Waiting {POLL_INTERVAL}s...")
            time.sleep(POLL_INTERVAL)
    else:
        print(f"[+] Supervisor on Cluster '{CLUSTER_ID}' not found/already removed. Skipping.\n")

    print("=== Teardown complete! Environment is clean and ready for Terraform. ===")

if __name__ == "__main__":
    main()
