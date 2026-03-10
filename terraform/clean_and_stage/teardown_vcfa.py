import requests
import urllib3
import time
import sys

# Suppress insecure request warnings
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

# --- Configuration Variables ---
PROVIDER_URL = "https://auto-a.site-a.vcf.lab"
PROVIDER_USER = "admin"
PROVIDER_PASS = "VMware123!VMware123!"

TENANT_URL = "https://auto-a.site-a.vcf.lab"
TENANT_ORG = "all-apps"
TENANT_USER = "all-apps-admin"
TENANT_PASS = "VMware123!VMware123!"

VCENTER_URL = "https://vc-wld01-a.site-a.vcf.lab"
VCENTER_USER = "administrator@wld.sso"
VCENTER_PASS = "VMware123!VMware123!"
CLUSTER_ID = "cluster-wld01-01a"

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
    
    # VCF 9 lists are often in 'values', 'content', or 'items'
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

# --- Main Execution ---

def main():
    print("=== Starting Final Idempotent VCF 9 Teardown ===\n")
    
    tenant_token = get_vcfa_tenant_token(TENANT_URL, TENANT_USER, TENANT_PASS, TENANT_ORG)
    provider_token = get_vcfa_provider_token(PROVIDER_URL, PROVIDER_USER, PROVIDER_PASS)
    vc_session = get_vcenter_session(VCENTER_URL, VCENTER_USER, VCENTER_PASS)
    
    cloudapi_provider_headers = {"Authorization": f"Bearer {provider_token}", "Accept": "application/json;version=40.0", "Content-Type": "application/json"}
    provider_iaas_headers = {"Authorization": f"Bearer {provider_token}", "Content-Type": "application/json"}
    vc_headers = {"vmware-api-session-id": vc_session, "Content-Type": "application/json"}

    # 1. Content Library
    print("--- Step 1: Removing Content Library ---")
    cl_name = "provider-content-library"
    cl_list_url = f"{PROVIDER_URL}/cloudapi/vcf/contentLibraries"
    cl_id, _ = get_resource_id(cl_list_url, cloudapi_provider_headers, cl_name)
    if cl_id:
        requests.delete(f"{cl_list_url}/{cl_id}?recursive=true&force=true", headers=cloudapi_provider_headers, verify=False)
        wait_for_deletion_by_list(cl_list_url, cloudapi_provider_headers, cl_name, "Content Library")

    # 2a. Deployments
    print("--- Step 2a: Clearing Deployments ---")
    dep_headers = {"Authorization": f"Bearer {tenant_token}", "Content-Type": "application/json"}
    dep_list_url = f"{TENANT_URL}/deployment/api/deployments"
    dep_resp = requests.get(dep_list_url, headers=dep_headers, verify=False).json()
    for dep in dep_resp.get("content", []):
        requests.delete(f"{dep_list_url}/{dep['id']}", headers=dep_headers, verify=False)
        wait_for_deletion_by_list(dep_list_url, dep_headers, dep['name'], "Deployment")

    # 2b. Namespace
    print("--- Step 2b: Removing Namespace ---")
    ns_name = "demo-namespace-3qdtf"
    ns_list_url = f"{TENANT_URL}/tm/cloudapi/v1/namespaceSummaries"
    tm_headers = {"Authorization": f"Bearer {tenant_token}", "Accept": "application/json;version=40.0", "Content-Type": "application/json"}
    tm_prov_headers = {"Authorization": f"Bearer {provider_token}", "Accept": "application/json;version=40.0", "Content-Type": "application/json"}
    
    ns_id, active_headers = get_resource_id(ns_list_url, tm_headers, ns_name)
    if ns_id:
        del_resp = requests.delete(f"{TENANT_URL}/tm/cloudapi/v1/namespaces/{ns_id}", headers=active_headers, verify=False)
        if del_resp.status_code == 403:
            requests.delete(f"{TENANT_URL}/tm/cloudapi/v1/namespaces/{ns_id}", headers=tm_prov_headers, verify=False)
            active_headers = tm_prov_headers
        
        # Use list-based polling to avoid getting stuck on internal status strings
        wait_for_deletion_by_list(ns_list_url, active_headers, ns_name, "Tenant Namespace")
        print("[*] Waiting 180s for NSX IP Block purge...")
        time.sleep(180)

    # 3. Regional Networking
    print("--- Step 3: Deleting Regional Networking ---")
    net_name = "all-appsus-west-region"
    net_list_url = f"{PROVIDER_URL}/cloudapi/vcf/regionalNetworkingSettings"
    net_id, _ = get_resource_id(net_list_url, cloudapi_provider_headers, net_name)
    if net_id:
        requests.delete(f"{net_list_url}/{net_id}", headers=cloudapi_provider_headers, verify=False)
        wait_for_deletion_by_list(net_list_url, cloudapi_provider_headers, net_name, "Networking")

    # 4. Delete Regional Quota (VCF 9 CloudAPI + IaaS Fallback)
    print("--- Step 4: Deleting Regional Quota ---")
    quota_name = "us-west-region"
    # Using the CloudAPI limits endpoint which is more stable in VCF 9
    quota_list_url = f"{PROVIDER_URL}/cloudapi/1.0.0/limits"
    
    try:
        quota_id, _ = get_resource_id(quota_list_url, cloudapi_provider_headers, quota_name)
        
        if quota_id:
            print(f"[*] Found Regional Quota '{quota_name}' via CloudAPI. Deleting...")
            requests.delete(f"{quota_list_url}/{quota_id}", headers=cloudapi_provider_headers, verify=False)
            wait_for_deletion_by_list(quota_list_url, cloudapi_provider_headers, quota_name, "Quota")
        else:
            print(f"[+] Quota '{quota_name}' not found via CloudAPI. It may be managed via Org VDC. Skipping to Org deletion.")
    except Exception as e:
        print(f"[!] Warning: Quota API threw an error ({e}). Proceeding to forced Org deletion to clear it.")

    # 5. Disable and Delete Tenant Org (The "Nuclear" Option)
    print("\n--- Step 5: Disabling and Deleting Tenant Org ---")
    org_list_url = f"{PROVIDER_URL}/cloudapi/1.0.0/orgs"
    org_id, _ = get_resource_id(org_list_url, cloudapi_provider_headers, TENANT_ORG)
    
    if org_id:
        print(f"[*] Found Tenant Org '{TENANT_ORG}'. Disabling and Purging...")
        org_url = f"{org_list_url}/{org_id}"
        
        # Disable the Org first
        requests.put(org_url, headers=cloudapi_provider_headers, json={"isEnabled": False}, verify=False)
        time.sleep(5)
        
        # In VCF 9, we use recursive=true and force=true to ensure the Org takes the 500-erroring quotas with it
        print(f"[*] Executing recursive force delete on Org '{TENANT_ORG}'...")
        del_org_resp = requests.delete(f"{org_url}?force=true&recursive=true", headers=cloudapi_provider_headers, verify=False)
        
        if del_org_resp.status_code >= 400:
            print(f"[-] Org delete failed: {del_org_resp.status_code} - {del_org_resp.text}")
            sys.exit(1)
            
        wait_for_deletion_by_list(org_list_url, cloudapi_provider_headers, TENANT_ORG, "Tenant Org")
    else:
        print(f"[+] Tenant Org '{TENANT_ORG}' already gone. Skipping.\n")

    # 6. vCenter Supervisor
    print("--- Step 6: vCenter Supervisor ---")
    sup_url = f"{VCENTER_URL}/api/vcenter/namespace-management/clusters/{CLUSTER_ID}"
    if requests.get(sup_url, headers=vc_headers, verify=False).status_code == 200:
        requests.delete(sup_url, headers=vc_headers, verify=False)
        print("[*] Waiting for vCenter Supervisor 404...")
        while requests.get(sup_url, headers=vc_headers, verify=False).status_code != 404:
            time.sleep(30)
    
    print("\n=== Teardown Complete ===")

if __name__ == "__main__":
    main()
