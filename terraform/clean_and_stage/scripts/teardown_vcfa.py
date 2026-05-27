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
TENANT_ORG = "Acme-East-A"
TENANT_USER = "acme-east-a"
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
    
    items = data.get("values", data.get("content", data.get("items", [])))
    if not isinstance(items, list) and isinstance(data, list):
        items = data

    for item in items:
        if isinstance(item, dict) and item.get(name_key) == target_name:
            return item.get("id"), active_headers
            
    return None, active_headers

def extract_list_items(api_url, headers):
    """Helper to cleanly extract a list of items from paginated VCFA endpoints."""
    response = requests.get(api_url, headers=headers, verify=False)
    if response.status_code == 404:
        return []
    response.raise_for_status()
    data = response.json()
    items = data.get("values", data.get("content", data.get("items", [])))
    if not isinstance(items, list) and isinstance(data, list):
        items = data
    return items

def wait_for_deletion_by_list(list_url, headers, target_name, resource_name, name_key="name"):
    print(f"[*] Polling: Waiting for {resource_name} '{target_name}' to vanish from list...")
    start_time = time.time()
    
    while (time.time() - start_time) < TIMEOUT_SECONDS:
        item_id, _ = get_resource_id(list_url, headers, target_name, name_key)
        
        if not item_id:
            print(f"[+] Success: {resource_name} '{target_name}' is no longer found.\n")
            return True
            
        print(f"    [{int(time.time() - start_time)}s elapsed] Still exists. Waiting {POLL_INTERVAL}s...")
        time.sleep(POLL_INTERVAL)
        
    print(f"[-] Timeout Error: {resource_name} '{target_name}' was not deleted within {TIMEOUT_SECONDS} seconds.")
    sys.exit(1)

# --- Main Logic ---

def main():
    print("=== Starting Dynamic Idempotent VCF 9 Teardown ===\n")
    
    print("[*] Authenticating to APIs...")
    
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

    # ==========================================
    # 1. Content Libraries (Dynamic)
    # ==========================================
    print("--- Step 1: Removing Content Libraries ---")
    cl_list_url = f"{PROVIDER_URL}/cloudapi/vcf/contentLibraries"
    content_libraries = extract_list_items(cl_list_url, cloudapi_provider_headers)
    
    if content_libraries:
        for cl in content_libraries:
            cl_id = cl.get("id")
            cl_name = cl.get("name")
            print(f"[*] Found Content Library '{cl_name}'. Deleting...")
            requests.delete(f"{cl_list_url}/{cl_id}?recursive=true&force=true", headers=cloudapi_provider_headers, verify=False)
            wait_for_deletion_by_list(cl_list_url, cloudapi_provider_headers, cl_name, "Content Library")
    else:
        print("[+] No Content Libraries found. Skipping.\n")

    # ==========================================
    # Tenant Scope Items (Deployments & Namespaces)
    # ==========================================
    if tenant_token:
        # 2. Deployments (Dynamic)
        print("--- Step 2: Clearing Tenant Deployments (Workload Teardown) ---")
        dep_headers = {"Authorization": f"Bearer {tenant_token}", "Content-Type": "application/json"}
        dep_list_url = f"{TENANT_URL}/deployment/api/deployments"
        deployments = extract_list_items(dep_list_url, dep_headers)
        
        if not deployments:
            print("[+] No active deployments found. Network should be clear of workloads.\n")
        else:
            for dep in deployments:
                print(f"[*] Found Deployment '{dep['name']}'. Instructing VCFA to destroy it...")
                requests.delete(f"{dep_list_url}/{dep['id']}", headers=dep_headers, verify=False)
                wait_for_deletion_by_list(dep_list_url, dep_headers, dep['name'], "Deployment")

        # 3. Namespaces (Dynamic)
        print("--- Step 3: Removing Tenant Namespaces ---")
        ns_list_url = f"{TENANT_URL}/tm/cloudapi/v1/namespaceSummaries"
        tm_tenant_headers = {"Authorization": f"Bearer {tenant_token}", "Accept": "application/json;version=40.0"}
        namespaces = extract_list_items(ns_list_url, tm_tenant_headers)
        
        if not namespaces:
            print("[+] No Namespaces found. Skipping.\n")
        else:
            for ns in namespaces:
                ns_name = ns.get("name")
                ns_id = ns.get("id")
                active_ns_headers = tm_tenant_headers
                
                print(f"[*] Found Namespace '{ns_name}'. Deleting...")
                del_resp = requests.delete(f"{TENANT_URL}/tm/cloudapi/v1/namespaces/{ns_id}", headers=active_ns_headers, verify=False)
                
                # Fallback to Provider token if Tenant lacks deletion rights
                if del_resp.status_code == 403:
                    print("    [!] Tenant lacks deletion rights. Swapping to Provider token...")
                    tm_prov_headers = {"Authorization": f"Bearer {provider_token}", "Accept": "application/json;version=40.0"}
                    del_resp = requests.delete(f"{TENANT_URL}/tm/cloudapi/v1/namespaces/{ns_id}", headers=tm_prov_headers, verify=False)
                    active_ns_headers = tm_prov_headers
                    
                if del_resp.status_code >= 400:
                    print(f"[-] Delete request failed for namespace '{ns_name}': {del_resp.status_code} - {del_resp.text}")
                    sys.exit(1)
                    
                wait_for_deletion_by_list(ns_list_url, active_ns_headers, ns_name, "Tenant Namespace")
            
            print("[*] Namespace deletions initialized. Waiting 180s for VCFA to purge stranded networking items...")
            time.sleep(180)
            print("[+] Wait complete.\n")
    else:
        print("--- Step 2 & 3: Skipping Deployments & Namespaces (Tenant Org already deleted) ---\n")

    # ==========================================
    # 4. Virtual Datacenters (Dynamic)
    # ==========================================
    print("--- Step 4: Deleting Virtual Datacenters ---")
    vdc_list_url = f"{PROVIDER_URL}/cloudapi/vcf/virtualDatacenters"
    virtual_datacenters = extract_list_items(vdc_list_url, cloudapi_provider_headers)
    
    # Filter for VDCs bound to our specific Tenant
    found_vdcs = [vdc for vdc in virtual_datacenters if vdc.get("org", {}).get("name") == TENANT_ORG]
    
    if found_vdcs:
        for vdc in found_vdcs:
            target_vdc_id = vdc.get("id")
            target_vdc_name = vdc.get("name")
            print(f"[*] Found Virtual Datacenter '{target_vdc_name}' bound to Org '{TENANT_ORG}'. Deleting...")
            
            requests.delete(f"{vdc_list_url}/{target_vdc_id}", headers=cloudapi_provider_headers, verify=False)
            wait_for_deletion_by_list(vdc_list_url, cloudapi_provider_headers, target_vdc_name, "Virtual Datacenter")
    else:
        print(f"[+] No Virtual Datacenters found for Org '{TENANT_ORG}'. Skipping.\n")

    # ==========================================
    # 5. Regional Networking (Dynamic)
    # ==========================================
    print("--- Step 5: Deleting Regional Networking Config ---")
    net_list_url = f"{PROVIDER_URL}/cloudapi/vcf/regionalNetworkingSettings"
    regional_networks = extract_list_items(net_list_url, cloudapi_provider_headers)
    
    found_nets = [net for net in regional_networks if net.get("orgRef", {}).get("name") == TENANT_ORG]
    
    if found_nets:
        for net in found_nets:
            target_net_id = net.get("id")
            target_net_name = net.get("name")
            print(f"[*] Found Regional Networking '{target_net_name}' bound to Org '{TENANT_ORG}'. Deleting...")
            requests.delete(f"{net_list_url}/{target_net_id}", headers=cloudapi_provider_headers, verify=False)
            wait_for_deletion_by_list(net_list_url, cloudapi_provider_headers, target_net_name, "Regional Networking")
    else:
        print(f"[+] Regional Networking for Org '{TENANT_ORG}' not found. Skipping.\n")

    # ==========================================
    # 6. Tenant Org
    # ==========================================
    print("--- Step 6: Disabling and Deleting Tenant Org ---")
    org_list_url = f"{PROVIDER_URL}/cloudapi/1.0.0/orgs"
    org_id, _ = get_resource_id(org_list_url, cloudapi_provider_headers, TENANT_ORG)
    if org_id:
        print(f"[*] Found Tenant Org '{TENANT_ORG}'. Disabling and Purging...")
        org_url = f"{org_list_url}/{org_id}"
        requests.put(org_url, headers=cloudapi_provider_headers, json={"isEnabled": False}, verify=False)
        time.sleep(10)
        requests.delete(f"{org_url}?force=true&recursive=true", headers=cloudapi_provider_headers, verify=False)
        wait_for_deletion_by_list(org_list_url, cloudapi_provider_headers, TENANT_ORG, "Tenant Org")
    else:
        print(f"[+] Tenant Org '{TENANT_ORG}' already gone. Skipping.\n")

    # ==========================================
    # 7. Region
    # ==========================================
    print("--- Step 7: Deleting Region ---")
    region_name = "us-east-a"
    region_list_url = f"{PROVIDER_URL}/cloudapi/vcf/regions"
    region_id, _ = get_resource_id(region_list_url, cloudapi_provider_headers, region_name)
    if region_id:
        print(f"[*] Found Region '{region_name}' with URN: {region_id}. Deleting...")
        requests.delete(f"{region_list_url}/{region_id}", headers=cloudapi_provider_headers, verify=False)
        wait_for_deletion_by_list(region_list_url, cloudapi_provider_headers, region_name, "Region")
    else:
        print(f"[+] Region '{region_name}' already removed. Skipping.\n")

    # ==========================================
    # 8. Supervisor
    # ==========================================
    print("--- Step 8: Disabling vCenter Supervisor ---")
    sup_list_url = f"{VCENTER_URL}/api/vcenter/namespace-management/clusters"
    list_resp = requests.get(sup_list_url, headers=vc_headers, verify=False)
    
    target_moref = None
    if list_resp.status_code == 200:
        clusters = list_resp.json()
        for cluster in clusters:
            if cluster.get("cluster_name") == CLUSTER_ID:
                target_moref = cluster.get("cluster")
                break
    
    if target_moref:
        print(f"[*] Found Supervisor on Cluster '{CLUSTER_ID}' (MoREF: {target_moref}). Disabling...")
        disable_url = f"{VCENTER_URL}/api/vcenter/namespace-management/clusters/{target_moref}?action=disable"
        disable_req = requests.post(disable_url, headers=vc_headers, verify=False)
        
        if disable_req.status_code >= 400:
            print(f"[-] Disable action failed: {disable_req.status_code} - {disable_req.text}")
            sys.exit(1)
            
        print(f"[*] Polling: Waiting for vCenter to completely decommission the Supervisor...")
        start_time = time.time()
        while True:
            check_resp = requests.get(sup_list_url, headers=vc_headers, verify=False)
            still_exists = False
            if check_resp.status_code == 200:
                for c in check_resp.json():
                    if c.get("cluster") == target_moref:
                        still_exists = True
                        break
            
            if not still_exists:
                print(f"[+] Success: Supervisor on '{CLUSTER_ID}' disabled and removed.\n")
                break
            
            if (time.time() - start_time) > TIMEOUT_SECONDS:
                print("[-] Timeout waiting for Supervisor decommissioning.")
                sys.exit(1)
                
            print(f"    [{int(time.time() - start_time)}s elapsed] Still decommissioning... Waiting 30s...")
            time.sleep(30)
    else:
        print(f"[+] No active Supervisor found for cluster '{CLUSTER_ID}'. Already disabled. Skipping.\n")

    print("=== Teardown Complete! Environment is clean and ready for Terraform. ===")

if __name__ == "__main__":
    main()
