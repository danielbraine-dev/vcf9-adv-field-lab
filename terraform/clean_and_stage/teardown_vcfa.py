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
    items = data.get("values", data.get("content", data.get("items", data))) if isinstance(data, dict) else data
    
    for item in items:
        if isinstance(item, dict) and item.get(name_key) == target_name:
            return item.get("id"), active_headers
            
    return None, active_headers

def wait_for_deletion_by_list(list_url, headers, target_name, resource_name, name_key="name"):
    print(f"[*] Polling: Waiting for {resource_name} to be completely removed...")
    start_time = time.time()
    
    while (time.time() - start_time) < TIMEOUT_SECONDS:
        item_id, _ = get_resource_id(list_url, headers, target_name, name_key)
        
        if not item_id:
            print(f"[+] Success: {resource_name} successfully deleted.\n")
            return True
            
        print(f"    [{int(time.time() - start_time)}s elapsed] Still exists. Waiting {POLL_INTERVAL}s...")
        time.sleep(POLL_INTERVAL)
        
    print(f"[-] Timeout Error: {resource_name} was not deleted within {TIMEOUT_SECONDS} seconds.")
    sys.exit(1)

# --- Main Logic ---

def main():
    print("=== Starting Final VCF 9 Environment Teardown ===\n")
    
    print("[*] Authenticating to APIs...")
    tenant_token = get_vcfa_tenant_token(TENANT_URL, TENANT_USER, TENANT_PASS, TENANT_ORG)
    provider_token = get_vcfa_provider_token(PROVIDER_URL, PROVIDER_USER, PROVIDER_PASS)
    vc_session = get_vcenter_session(VCENTER_URL, VCENTER_USER, VCENTER_PASS)
    
    cloudapi_provider_headers = {
        "Authorization": f"Bearer {provider_token}", 
        "Accept": "application/json;version=40.0",
        "Content-Type": "application/json"
    }
    vc_headers = {"vmware-api-session-id": vc_session, "Content-Type": "application/json"}
    print("[+] Authentication successful.\n")

    # 1. Clear Deployments
    print("--- Step 1: Clearing Tenant Deployments ---")
    dep_headers = {"Authorization": f"Bearer {tenant_token}", "Content-Type": "application/json"}
    dep_list_url = f"{TENANT_URL}/deployment/api/deployments"
    dep_resp = requests.get(dep_list_url, headers=dep_headers, verify=False).json()
    for dep in dep_resp.get("content", []):
        requests.delete(f"{dep_list_url}/{dep['id']}", headers=dep_headers, verify=False)
        wait_for_deletion_by_list(dep_list_url, dep_headers, dep['name'], "Deployment")

    # 2. Delete Namespace
    print("--- Step 2: Removing Tenant Namespace ---")
    ns_name = "demo-namespace-3qdtf"
    ns_list_url = f"{TENANT_URL}/tm/cloudapi/v1/namespaceSummaries"
    
    tm_tenant_headers = {"Authorization": f"Bearer {tenant_token}", "Accept": "application/json;version=40.0", "Content-Type": "application/json"}
    tm_provider_headers = {"Authorization": f"Bearer {provider_token}", "Accept": "application/json;version=40.0", "Content-Type": "application/json"}
    
    ns_id, active_ns_headers = get_resource_id(ns_list_url, tm_tenant_headers, ns_name)
    if ns_id:
        print(f"[*] Found Namespace '{ns_name}' with ID: {ns_id}. Deleting...")
        ns_delete_url = f"{TENANT_URL}/tm/cloudapi/v1/namespaces/{ns_id}"
        
        # Capture the response to catch errors
        del_resp = requests.delete(ns_delete_url, headers=active_ns_headers, verify=False)
        
        # If the Tenant lacks destruction rights, swap to Provider token
        if del_resp.status_code == 403:
            print("    [!] Tenant lacks deletion rights. Swapping to Provider token...")
            active_ns_headers = tm_provider_headers
            del_resp = requests.delete(ns_delete_url, headers=active_ns_headers, verify=False)
            
        if del_resp.status_code >= 400:
            print(f"[-] Delete request failed: {del_resp.status_code} - {del_resp.text}")
            sys.exit(1)
            
        wait_for_deletion_by_list(ns_list_url, active_ns_headers, ns_name, "Namespace")
        print("[*] Waiting 180s for network purge...")
        time.sleep(180)
    else:
        print(f"[+] Namespace '{ns_name}' not found. Already deleted. Skipping.\n")

    # 3. Regional Networking
    print("--- Step 3: Deleting Regional Networking Config ---")
    net_name = "all-appsus-west-region"
    net_list_url = f"{PROVIDER_URL}/cloudapi/vcf/regionalNetworkingSettings"
    net_id, _ = get_resource_id(net_list_url, cloudapi_provider_headers, net_name)
    if net_id:
        requests.delete(f"{net_list_url}/{net_id}", headers=cloudapi_provider_headers, verify=False)
        wait_for_deletion_by_list(net_list_url, cloudapi_provider_headers, net_name, "Networking")

    # 4. Disable and Delete Tenant Org
    print("--- Step 4: Disabling and Deleting Tenant Org ---")
    org_list_url = f"{PROVIDER_URL}/cloudapi/1.0.0/orgs"
    org_id, _ = get_resource_id(org_list_url, cloudapi_provider_headers, TENANT_ORG)
    if org_id:
        org_url = f"{org_list_url}/{org_id}"
        requests.put(org_url, headers=cloudapi_provider_headers, json={"isEnabled": False}, verify=False)
        time.sleep(10)
        requests.delete(f"{org_url}?force=true&recursive=true", headers=cloudapi_provider_headers, verify=False)
        wait_for_deletion_by_list(org_list_url, cloudapi_provider_headers, TENANT_ORG, "Tenant Org")

    # 5. Delete Region
    print("--- Step 5: Deleting Region ---")
    region_name = "us-west-region"
    region_list_url = f"{PROVIDER_URL}/cloudapi/1.0.0/regions"
    region_id, _ = get_resource_id(region_list_url, cloudapi_provider_headers, region_name)
    if region_id:
        print(f"[*] Found Region '{region_name}'. Deleting...")
        requests.delete(f"{region_list_url}/{region_id}", headers=cloudapi_provider_headers, verify=False)
        wait_for_deletion_by_list(region_list_url, cloudapi_provider_headers, region_name, "Region")
    else:
        print(f"[+] Region '{region_name}' already removed. Skipping.")

    # 6. Delete vCenter Supervisor
    print("--- Step 6: Deleting vCenter Supervisor ---")
    supervisor_url = f"{VCENTER_URL}/api/vcenter/namespace-management/clusters/{CLUSTER_ID}"
    if requests.get(supervisor_url, headers=vc_headers, verify=False).status_code == 200:
        print(f"[*] Decommissioning Supervisor on cluster {CLUSTER_ID}...")
        requests.delete(supervisor_url, headers=vc_headers, verify=False)
        start_time = time.time()
        while requests.get(supervisor_url, headers=vc_headers, verify=False).status_code != 404:
            if (time.time() - start_time) > TIMEOUT_SECONDS:
                print("[-] Timeout waiting for Supervisor removal.")
                sys.exit(1)
            print(f"    [{int(time.time() - start_time)}s] Still decommissioning...")
            time.sleep(30)
        print("[+] Success: Supervisor removed.")
    else:
        print("[+] Supervisor already removed. Skipping.")

    print("\n=== Teardown Complete! Environment is clean. ===")

if __name__ == "__main__":
    main()
