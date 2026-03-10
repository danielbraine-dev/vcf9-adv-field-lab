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
CLUSTER_ID = "cluster-wld01-01a"  # Used for logging/context, but script uses dynamic MoREF lookup

# Timers
TIMEOUT_SECONDS = 1200
POLL_INTERVAL = 30

# --- Helper Functions ---

def get_vcfa_provider_token(url, username, password):
    auth_url = f"{url}/cloudapi/1.0.0/sessions/provider"
    headers = {"Accept": "application/json;version=40.0"} 
    auth = (f"{username}@system", password) 
    response = requests.post(auth_url, headers=headers, auth=auth, verify=False)
    response.raise_for_status()
    return response.headers.get("x-vmware-vcloud-access-token")

def get_vcfa_tenant_token(url, username, password, org_name):
    auth_url = f"{url}/cloudapi/1.0.0/sessions"
    headers = {"Accept": "application/json;version=40.0"}
    auth = (f"{username}@{org_name}", password) 
    response = requests.post(auth_url, headers=headers, auth=auth, verify=False)
    response.raise_for_status()
    return response.headers.get("x-vmware-vcloud-access-token")

def get_vcenter_session(url, username, password):
    auth_url = f"{url}/api/session"
    response = requests.post(auth_url, auth=(username, password), verify=False)
    response.raise_for_status()
    return response.json()

def get_resource_id(api_url, headers, target_name, name_key="name", fallback_headers=None):
    active_headers = headers
    response = requests.get(api_url, headers=active_headers, verify=False)
    
    if response.status_code == 403 and fallback_headers:
        active_headers = fallback_headers
        response = requests.get(api_url, headers=active_headers, verify=False)
        
    if response.status_code == 404:
        return None, active_headers
        
    response.raise_for_status()
    data = response.json()
    
    # Handle VCF 9 pagination structures
    items = data.get("values", data.get("content", data.get("items", [])))
    if not isinstance(items, list) and isinstance(data, list):
        items = data

    for item in items:
        if isinstance(item, dict) and item.get(name_key) == target_name:
            return item.get("id"), active_headers
            
    return None, active_headers

def wait_for_deletion_by_list(list_url, headers, target_name, resource_name, name_key="name"):
    print(f"[*] Polling: Waiting for {resource_name} to vanish from list...")
    start_time = time.time()
    
    while (time.time() - start_time) < TIMEOUT_SECONDS:
        item_id, _ = get_resource_id(list_url, headers, target_name, name_key)
        
        if not item_id:
            print(f"[+] Success: {resource_name} is no longer found.\n")
            return True
            
        print(f"    [{int(time.time() - start_time)}s elapsed] Still exists. Waiting {POLL_INTERVAL}s...")
        time.sleep(POLL_INTERVAL)
        
    print(f"[-] Timeout Error: {resource_name} was not deleted within {TIMEOUT_SECONDS} seconds.")
    sys.exit(1)

# --- Main Logic ---

def main():
    print("=== Starting Final Idempotent VCF 9 Teardown ===\n")
    
    print("[*] Authenticating to APIs...")
    
    # Idempotent Tenant Auth: Catch 401 if the Org was wiped in a previous run
    tenant_token = None
    try:
        tenant_token = get_vcfa_tenant_token(TENANT_URL, TENANT_USER, TENANT_PASS, TENANT_ORG)
        print(f"[+] Tenant authentication successful for '{TENANT_ORG}'.")
    except requests.exceptions.HTTPError as e:
        if e.response.status_code == 401:
            print(f"[+] Tenant Auth (401). Org '{TENANT_ORG}' is already deleted. Tenant steps will be skipped.")
        else:
            print(f"[-] Unexpected Tenant Auth Error: {e}")
            sys.exit(1)

    provider_token = get_vcfa_provider_token(PROVIDER_URL, PROVIDER_USER, PROVIDER_PASS)
    vc_session = get_vcenter_session(VCENTER_URL, VCENTER_USER, VCENTER_PASS)
    
    cloudapi_provider_headers = {"Authorization": f"Bearer {provider_token}", "Accept": "application/json;version=40.0", "Content-Type": "application/json"}
    vc_headers = {"vmware-api-session-id": vc_session, "Content-Type": "application/json"}
    print("[+] Provider and vCenter authentication successful.\n")

    # 1. Content Library
    print("--- Step 1: Removing Content Library ---")
    cl_name = "provider-content-library"
    cl_list_url = f"{PROVIDER_URL}/cloudapi/vcf/contentLibraries"
    cl_id, _ = get_resource_id(cl_list_url, cloudapi_provider_headers, cl_name)
    if cl_id:
        print(f"[*] Found Content Library '{cl_name}'. Deleting...")
        requests.delete(f"{cl_list_url}/{cl_id}?recursive=true&force=true", headers=cloudapi_provider_headers, verify=False)
        wait_for_deletion_by_list(cl_list_url, cloudapi_provider_headers, cl_name, "Content Library")
    else:
        print(f"[+] Content Library '{cl_name}' not found. Already deleted. Skipping.\n")

    # 2. Deployments & Namespaces (Only run if Tenant Org exists)
    if tenant_token:
        # 2a. Deployments
        print("--- Step 2a: Clearing Tenant Deployments (Workload Teardown) ---")
        dep_headers = {"Authorization": f"Bearer {tenant_token}", "Content-Type": "application/json"}
        dep_list_url = f"{TENANT_URL}/deployment/api/deployments"
        dep_resp = requests.get(dep_list_url, headers=dep_headers, verify=False).json()
        deployments = dep_resp.get("content", [])
        
        if not deployments:
            print("[+] No active deployments found. Network should be clear of workloads.")
        for dep in deployments:
            print(f"[*] Found Deployment '{dep['name']}'. Instructing VCFA to destroy it...")
            requests.delete(f"{dep_list_url}/{dep['id']}", headers=dep_headers, verify=False)
            wait_for_deletion_by_list(dep_list_url, dep_headers, dep['name'], "Deployment")

        # 2b. Namespace
        print("\n--- Step 2b: Removing Tenant Namespace ---")
        ns_name = "demo-namespace-3qdtf"
        ns_list_url = f"{TENANT_URL}/tm/cloudapi/v1/namespaceSummaries"
        tm_tenant_headers = {"Authorization": f"Bearer {tenant_token}", "Accept": "application/json;version=40.0"}
        
        ns_id, active_ns_headers = get_resource_id(ns_list_url, tm_tenant_headers, ns_name)
        if ns_id:
            print(f"[*] Found Namespace '{ns_name}'. Deleting...")
            del_resp = requests.delete(f"{TENANT_URL}/tm/cloudapi/v1/namespaces/{ns_id}", headers=active_ns_headers, verify=False)
            
            # Fallback to Provider token if Tenant lacks deletion rights
            if del_resp.status_code == 403:
                print("    [!] Tenant lacks deletion rights. Swapping to Provider token...")
                tm_prov_headers = {"Authorization": f"Bearer {provider_token}", "Accept": "application/json;version=40.0"}
                del_resp = requests.delete(f"{TENANT_URL}/tm/cloudapi/v1/namespaces/{ns_id}", headers=tm_prov_headers, verify=False)
                active_ns_headers = tm_prov_headers
                
            if del_resp.status_code >= 400:
                print(f"[-] Delete request failed: {del_resp.status_code} - {del_resp.text}")
                sys.exit(1)
                
            wait_for_deletion_by_list(ns_list_url, active_ns_headers, ns_name, "Tenant Namespace")
            print("[*] Namespace deletion initialized. Waiting 180s for VCFA to purge stranded networking items...")
            time.sleep(180)
            print("[+] Wait complete.\n")
        else:
            print(f"[+] Namespace '{ns_name}' not found. Already deleted. Skipping.\n")
    else:
        print("--- Step 2: Skipping Deployments & Namespace (Tenant Org already deleted) ---\n")

    # 3. Regional Networking
    print("--- Step 3: Deleting Regional Networking Config ---")
    net_name = "all-appsus-west-region"
    net_list_url = f"{PROVIDER_URL}/cloudapi/vcf/regionalNetworkingSettings"
    net_id, _ = get_resource_id(net_list_url, cloudapi_provider_headers, net_name)
    if net_id:
        print(f"[*] Found Regional Networking '{net_name}'. Deleting...")
        requests.delete(f"{net_list_url}/{net_id}", headers=cloudapi_provider_headers, verify=False)
        wait_for_deletion_by_list(net_list_url, cloudapi_provider_headers, net_name, "Regional Networking")
    else:
        print(f"[+] Regional Networking '{net_name}' not found. Already deleted. Skipping.\n")

    # 4. Disable and Delete Tenant Org (Implicitly cleans up Quotas)
    print("--- Step 4: Disabling and Deleting Tenant Org ---")
    org_list_url = f"{PROVIDER_URL}/cloudapi/1.0.0/orgs"
    org_id, _ = get_resource_id(org_list_url, cloudapi_provider_headers, TENANT_ORG)
    if org_id:
        print(f"[*] Found Tenant Org '{TENANT_ORG}'. Disabling and Purging...")
        org_url = f"{org_list_url}/{org_id}"
        requests.put(org_url, headers=cloudapi_provider_headers, json={"isEnabled": False}, verify=False)
        time.sleep(10)
        # Force and recursive ensures attached 500-erroring quotas are purged
        requests.delete(f"{org_url}?force=true&recursive=true", headers=cloudapi_provider_headers, verify=False)
        wait_for_deletion_by_list(org_list_url, cloudapi_provider_headers, TENANT_ORG, "Tenant Org")
    else:
        print(f"[+] Tenant Org '{TENANT_ORG}' already gone. Skipping.\n")

    # 5. Delete Region
    print("--- Step 5: Deleting Region ---")
    region_name = "us-west-region"
    region_list_url = f"{PROVIDER_URL}/cloudapi/vcf/regions"
    region_id, _ = get_resource_id(region_list_url, cloudapi_provider_headers, region_name)
    if region_id:
        print(f"[*] Found Region '{region_name}' with URN: {region_id}. Deleting...")
        requests.delete(f"{region_list_url}/{region_id}", headers=cloudapi_provider_headers, verify=False)
        wait_for_deletion_by_list(region_list_url, cloudapi_provider_headers, region_name, "Region")
    else:
        print(f"[+] Region '{region_name}' already removed. Skipping.\n")

    # 6. Delete vCenter Supervisor (Final Corrected Endpoint)
    print("--- Step 6: Deleting vCenter Supervisor ---")
    
    # 1. Lookup: Get the list of clusters to find the MoREF
    sup_list_url = f"{VCENTER_URL}/api/vcenter/namespace-management/clusters"
    list_resp = requests.get(sup_list_url, headers=vc_headers, verify=False)
    
    target_moref = None
    if list_resp.status_code == 200:
        clusters = list_resp.json()
        for cluster in clusters:
            # Match the human-readable name to get the MoREF (e.g., domain-c10)
            if cluster.get("cluster_name") == CLUSTER_ID:
                target_moref = cluster.get("cluster")
                break
    
    if target_moref:
        print(f"[*] Found Supervisor on Cluster '{CLUSTER_ID}' (MoREF: {target_moref}). Decommissioning...")
        
        # 2. Decommission: Use the 'software' path for the DELETE operation
        # This is the specific VCF 9 / vSphere 8 path for decommissioning
        del_url = f"{VCENTER_URL}/api/vcenter/namespace-management/software/clusters/{target_moref}"
        
        del_req = requests.delete(del_url, headers=vc_headers, verify=False)
        
        if del_req.status_code >= 400:
            print(f"[-] Decommission failed: {del_req.status_code} - {del_req.text}")
            sys.exit(1)
            
        print(f"[*] Polling: Waiting for vCenter to completely remove the Supervisor...")
        start_time = time.time()
        while True:
            # We poll the original summary list to see when the MoREF disappears
            check_resp = requests.get(sup_list_url, headers=vc_headers, verify=False)
            still_exists = False
            if check_resp.status_code == 200:
                for c in check_resp.json():
                    if c.get("cluster") == target_moref:
                        still_exists = True
                        break
            
            if not still_exists:
                print(f"[+] Success: Supervisor on '{CLUSTER_ID}' removed.\n")
                break
            
            if (time.time() - start_time) > TIMEOUT_SECONDS:
                print("[-] Timeout waiting for Supervisor removal.")
                sys.exit(1)
                
            print(f"    [{int(time.time() - start_time)}s elapsed] Still decommissioning... Waiting 30s...")
            time.sleep(30)
    else:
        print(f"[+] No active Supervisor found for cluster '{CLUSTER_ID}'. Already removed. Skipping.\n")

    print("=== Teardown Complete! Environment is clean and ready for Terraform. ===")

if __name__ == "__main__":
    main()
