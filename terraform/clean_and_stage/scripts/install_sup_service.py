#!/usr/bin/env python3
import sys, requests, urllib3, argparse, json, base64, re, time

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

def robust_post(session, url, payload):
    """
    Dynamically handles vCenter API wrapper inconsistencies.
    VAPI often requires the payload to be wrapped in a specific parameter name.
    """
    # 1. Try wrapping in 'create_spec' (Standard for VAPI Create operations)
    r = session.post(url, json={"create_spec": payload})
    if r.status_code < 400 or "AlreadyExists" in r.text: return r

    # 2. Try wrapping in 'spec'
    r = session.post(url, json={"spec": payload})
    if r.status_code < 400 or "AlreadyExists" in r.text: return r

    # 3. Try flat JSON payload
    r = session.post(url, json=payload)
    return r

def inject_avi_dns(avi_ip, avi_user, avi_pass, fqdn, target_ip):
    """Handles the Avi REST API logic for injecting a DNS A-Record."""
    session = requests.Session()
    session.verify = False
    try:
        login_res = session.post(f"https://{avi_ip}/login", data={"username": avi_user, "password": avi_pass})
        login_res.raise_for_status()
        
        headers = {
            "X-CSRFToken": session.cookies.get("csrftoken"),
            "X-Avi-Version": "31.2.2", 
            "Referer": f"https://{avi_ip}/",
            "Content-Type": "application/json"
        }

        res = session.get(f"https://{avi_ip}/api/ipamdnsproviderprofile", headers=headers)
        res.raise_for_status()
        
        dns_profile = next((p for p in res.json().get("results", []) if p.get("type") == "PROFILE_TYPE_DNS"), None)
        if not dns_profile:
            print("[-] No DNS Provider Profile found in Avi. Skipping DNS injection.")
            return False

        profile_uuid = dns_profile["uuid"]
        dns_domain = dns_profile.get("internal_profile", {}).get("dns_service_domain", [{}])[0]
        
        if "record_table" not in dns_domain: dns_domain["record_table"] = []

        original_count = len(dns_domain["record_table"])
        dns_domain["record_table"] = [rec for rec in dns_domain["record_table"] if fqdn not in rec.get("fqdn", [])]
        dns_domain["record_table"].append({"fqdn": [fqdn], "type": "DNS_RECORD_A", "ip_address": {"addr": target_ip, "type": "V4"}})

        update_res = session.put(f"https://{avi_ip}/api/ipamdnsproviderprofile/{profile_uuid}", headers=headers, json=dns_profile)
        update_res.raise_for_status()
        
        action = "Updated" if original_count == len(dns_domain["record_table"]) else "Added"
        print(f"[+] Successfully {action} DNS Record in Avi: {fqdn} -> {target_ip}")
        return True

    except requests.exceptions.RequestException as e:
        print(f"[-] Avi API DNS injection failed: {e}")
        sys.exit(1)

def register_and_activate_service(session, host, definition_path, service_name):
    """Automates Phase 1: Uploading the Service Definition using the Native Schema"""
    with open(definition_path, 'r') as f:
        content_raw = f.read()
    
    b64_content = base64.b64encode(content_raw.encode('utf-8')).decode('utf-8')
    
    # Best-effort parsing just so we know what ID to poll for status
    ref_match = re.search(r'refName:\s*([^\s]+)', content_raw)
    ver_match = re.search(r'version:\s*([^\s]+)', content_raw)
    svc_id_guess = ref_match.group(1).strip("'\"") if ref_match else service_name
    svc_ver_guess = ver_match.group(1).strip("'\"") if ver_match else "unknown"

    print(f"[*] Registering Supervisor Service via inline YAML payload...")
    
    payload_vsphere = {
        "vsphere_spec": {
            "version_spec": {
                "content": b64_content,
                "accept_eula": True
            }
        }
    }
    
    r = robust_post(session, f"https://{host}/api/vcenter/namespace-management/supervisor-services", payload_vsphere)
    
    if r.status_code >= 400 and "AlreadyExists" not in r.text:
        print("[-] vsphere_spec format rejected. Falling back to carvel_spec format...")
        payload_carvel = {
            "carvel_spec": {
                "version_spec": {
                    "content": b64_content
                }
            }
        }
        r = robust_post(session, f"https://{host}/api/vcenter/namespace-management/supervisor-services", payload_carvel)

    if r.status_code >= 400 and "AlreadyExists" not in r.text:
        print(f"[-] API POST failed! HTTP {r.status_code}")
        try:
            print(json.dumps(r.json(), indent=2))
        except:
            print(r.text)
        sys.exit(1)

    print("[+] Service and Version registered successfully (or already exists)!")

    res = session.get(f"https://{host}/api/vcenter/namespace-management/supervisor-services")
    res.raise_for_status()
    existing_svcs = res.json()
    
    target_svc = next((s for s in existing_svcs if svc_id_guess in s["supervisor_service"]), None)
    if not target_svc:
        target_svc = next((s for s in existing_svcs if service_name.lower() in s.get("name", "").lower() or service_name.lower() in s.get("display_name", "").lower()), None)
    
    if not target_svc:
        print("[-] Service was registered, but could not be found in the catalog to query status!")
        sys.exit(1)
        
    svc_id = target_svc["supervisor_service"]

    print(f"[*] Waiting for version to reach ACTIVATED state (can take 1-2 minutes)...")
    for _ in range(40):
        r = session.get(f"https://{host}/api/vcenter/namespace-management/supervisor-services/{svc_id}/versions")
        versions_data = r.json()
        
        activated_version = next((v["version"] for v in versions_data if v["state"] == "ACTIVATED" and (svc_ver_guess == "unknown" or v["version"] == svc_ver_guess)), None)
        
        if activated_version:
            print(f"[+] Version {activated_version} is ACTIVATED and ready for deployment!")
            return svc_id, activated_version
        time.sleep(3)
        
    print("[-] Timeout waiting for Service Version to activate.")
    sys.exit(1)

def main():
    parser = argparse.ArgumentParser(description="Lifecycle a vSphere Supervisor Service.")
    parser.add_argument("--host", required=True)
    parser.add_argument("--user", required=True)
    parser.add_argument("--password", required=True)
    parser.add_argument("--service-name", required=True)
    parser.add_argument("--definition-yaml", required=True, help="The base Service Definition YAML (e.g., contour-service-vX.Y.yaml)")
    parser.add_argument("--values-yaml", help="The custom Data Values YAML (e.g., harbor-dynamic-values.yaml)")
    
    parser.add_argument("--avi-ip")
    parser.add_argument("--avi-user", default="admin")
    parser.add_argument("--avi-pass")
    parser.add_argument("--fqdn")
    parser.add_argument("--target-ip")
    args = parser.parse_args()

    if args.avi_ip and args.fqdn and args.target_ip:
        print(f"[*] Pre-flight task: Injecting DNS mapping for {args.fqdn}...")
        inject_avi_dns(args.avi_ip, args.avi_user, args.avi_pass, args.fqdn, args.target_ip)

    session = requests.Session()
    session.auth = (args.user, args.password)
    session.verify = False

    try:
        session.headers.update({"vmware-api-session-id": session.post(f"https://{args.host}/api/session").json()})

        # Phase 1: Registration
        svc_id, svc_ver = register_and_activate_service(session, args.host, args.definition_yaml, args.service_name)

        supervisor_id = session.get(f"https://{args.host}/api/vcenter/namespace-management/clusters").json()[0]["cluster"]

        # Phase 2: Installation
        payload = {"supervisor_service": svc_id, "version": svc_ver}
        if args.values_yaml:
            with open(args.values_yaml, "rb") as f:
                payload["yaml_service_config"] = base64.b64encode(f.read()).decode('utf-8')

        install_url = f"https://{args.host}/api/vcenter/namespace-management/supervisors/{supervisor_id}/supervisor-services"
        
        # --- THE FIX: Bulletproof Idempotency Check ---
        try:
            r_exist = session.get(install_url)
            if r_exist.status_code == 200:
                existing_data = r_exist.json()
                
                # Handle vCenter wrapper {"value": [...]} or raw list [...]
                svc_list = existing_data.get("value", []) if isinstance(existing_data, dict) else existing_data
                
                installed_ids = []
                for item in svc_list:
                    if isinstance(item, str):
                        installed_ids.append(item)
                    elif isinstance(item, dict):
                        installed_ids.append(item.get("supervisor_service", ""))
                
                if svc_id in installed_ids:
                    print(f"[+] Service {svc_id} is already deployed on the Supervisor. Skipping installation.")
                    sys.exit(0)
        except Exception as e:
            print(f"[*] Note: Could not verify existing services natively, proceeding with installation attempt...")

        print(f"[*] Deploying {args.service_name} onto Supervisor {supervisor_id}...")
        r = robust_post(session, install_url, payload)
        
        if r.status_code >= 400:
            print(f"[-] API POST failed! HTTP {r.status_code}")
            try:
                print(json.dumps(r.json(), indent=2))
            except:
                print(r.text)
            sys.exit(1)
            
        print(f"[+] Successfully initiated installation of {args.service_name}!")

    except requests.exceptions.RequestException as e:
        print(f"[-] API connection failed: {e}")
        if e.response is not None:
            print(e.response.text)
        sys.exit(1)

if __name__ == "__main__":
    main()
