#!/usr/bin/env python3
import sys, os, requests, urllib3, argparse, json, base64, re, time

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

def robust_post(session, url, payload):
    """
    Dynamically handles vCenter API wrapper inconsistencies.
    Checks for both 'AlreadyExists' and 'unique_violation' to handle idempotency safely.
    """
    def is_success_or_exists(r):
        text = r.text.lower()
        return r.status_code < 400 or "already exist" in text or "unique_violation" in text

    # 1. Try wrapping in 'create_spec'
    r = session.post(url, json={"create_spec": payload})
    if is_success_or_exists(r): return r

    # 2. Try wrapping in 'spec'
    r = session.post(url, json={"spec": payload})
    if is_success_or_exists(r): return r

    # 3. Try flat JSON payload
    r = session.post(url, json=payload)
    return r

def inject_avi_dns(avi_ip, avi_user, avi_pass, fqdn, target_ip):
    """Handles the Avi REST API logic for injecting a Static DNS A-Record directly into the Virtual Service."""
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

        res = session.get(f"https://{avi_ip}/api/virtualservice?name=delegated-dns", headers=headers)
        res.raise_for_status()
        
        results = res.json().get("results", [])
        if not results:
            print("[-] No Virtual Service named 'delegated-dns' found in Avi. Skipping DNS injection.")
            return False

        vs_obj = results[0]
        vs_uuid = vs_obj["uuid"]
        
        if "static_dns_records" not in vs_obj: 
            vs_obj["static_dns_records"] = []

        original_count = len(vs_obj["static_dns_records"])
        
        filtered_records = []
        for rec in vs_obj["static_dns_records"]:
            rec_fqdns = rec.get("fqdn", [])
            if isinstance(rec_fqdns, str): rec_fqdns = [rec_fqdns]
            if fqdn not in rec_fqdns:
                filtered_records.append(rec)
                
        vs_obj["static_dns_records"] = filtered_records
        
        vs_obj["static_dns_records"].append({
            "fqdn": [fqdn], 
            "type": "DNS_RECORD_A", 
            "ip_address": [
                {
                    "ip_address": {
                        "addr": target_ip, 
                        "type": "V4"
                    }
                }
            ]
        })

        update_res = session.put(f"https://{avi_ip}/api/virtualservice/{vs_uuid}", headers=headers, json=vs_obj)
        update_res.raise_for_status()
        
        action = "Updated" if original_count == len(vs_obj["static_dns_records"]) else "Added"
        print(f"[+] Successfully {action} Static DNS Record on Virtual Service 'delegated-dns': {fqdn} -> {target_ip}")
        return True

    except requests.exceptions.RequestException as e:
        print(f"[-] Avi API DNS injection failed: {e}")
        if e.response is not None:
            print(e.response.text)
        sys.exit(1)

def trust_harbor_registry(session, host, supervisor_id, fqdn, cert_path):
    """Automates the injection of the Harbor TLS cert into the Supervisor's Image Registry Trust Store."""
    if not os.path.exists(cert_path):
        return

    with open(cert_path, "r") as f:
        ca_cert = f.read()

    url = f"https://{host}/api/vcenter/namespace-management/supervisors/{supervisor_id}/container-image-registries"
    
    # Idempotency Check: Don't add if it's already trusted
    try:
        r_get = session.get(url)
        if r_get.status_code == 200:
            data = r_get.json()
            items = data if isinstance(data, list) else data.get("value", [])
            for reg in items:
                info = reg.get("image_registry", {})
                if info.get("hostname", "") == fqdn or reg.get("name", "") == "Lab-Harbor-Registry":
                    print(f"[*] Registry {fqdn} is already trusted by Supervisor. Skipping.")
                    return
    except Exception:
        pass

    print(f"[*] Injecting Harbor TLS certificate into Supervisor {supervisor_id} Trust Store...")
    
    # THE FIX: Exact vSphere 8.0.3.0 Schema (Flat JSON, nested image_registry object)
    payload = {
        "name": "Lab-Harbor-Registry",
        "image_registry": {
            "hostname": fqdn,
            "port": 443,
            "certificate_chain": ca_cert
        }
    }
    
    # Bypass the brute-forcer completely to avoid wrapper errors
    r = session.post(url, json=payload)
    
    text_lower = r.text.lower()
    if r.status_code >= 400 and "alreadyexist" not in text_lower and "already_exists" not in text_lower:
        print(f"[-] Failed to add Harbor to Supervisor trusted registries! HTTP {r.status_code}")
        try: print(json.dumps(r.json(), indent=2))
        except: print(r.text)
        sys.exit(1)
        
    print("[+] Successfully added Harbor to Supervisor Trusted Registries!")

def register_and_activate_service(session, host, definition_path, service_name):
    """Automates Phase 1: Uploading the Service Definition using the Native Schema idempotently"""
    with open(definition_path, 'r') as f:
        content_raw = f.read()
    
    b64_content = base64.b64encode(content_raw.encode('utf-8')).decode('utf-8')
    
    ref_match = re.search(r'\n\s*refName:\s*([^\s]+)', content_raw)
    ver_match = re.search(r'\n\s*version:\s*([0-9][^\s]+)', content_raw)
    
    svc_id_guess = ref_match.group(1).strip("'\"") if ref_match else service_name
    svc_ver_guess = ver_match.group(1).strip("'\"") if ver_match else "unknown"

    # --- 1. Query the Catalog First (Idempotency Check) ---
    res = session.get(f"https://{host}/api/vcenter/namespace-management/supervisor-services")
    res.raise_for_status()
    existing_svcs = res.json()
    svc_list = existing_svcs.get("value", []) if isinstance(existing_svcs, dict) else existing_svcs
    
    installed_svc_ids = [s.get("supervisor_service", "") if isinstance(s, dict) else s for s in svc_list]

    if svc_id_guess not in installed_svc_ids:
        print(f"[*] Registering new Supervisor Service via inline YAML payload...")
        payload_vsphere = {"vsphere_spec": {"version_spec": {"content": b64_content, "accept_eula": True}}}
        
        r = robust_post(session, f"https://{host}/api/vcenter/namespace-management/supervisor-services", payload_vsphere)
        
        if r.status_code >= 400 and "unique_violation" not in r.text:
            print("[-] vsphere_spec format rejected. Falling back to carvel_spec format...")
            payload_carvel = {"carvel_spec": {"version_spec": {"content": b64_content}}}
            r = robust_post(session, f"https://{host}/api/vcenter/namespace-management/supervisor-services", payload_carvel)

        if r.status_code >= 400 and "unique_violation" not in r.text:
            print(f"[-] API POST failed! HTTP {r.status_code}")
            try: print(json.dumps(r.json(), indent=2))
            except: print(r.text)
            sys.exit(1)
        print("[+] Service registered successfully!")
    else:
        print(f"[*] Supervisor Service '{svc_id_guess}' already registered. Checking versions...")

    svc_id = svc_id_guess

    # --- 2. Check if Version is uploaded ---
    res = session.get(f"https://{host}/api/vcenter/namespace-management/supervisor-services/{svc_id}/versions")
    res.raise_for_status()
    versions_data = res.json()
    ver_list = versions_data.get("value", []) if isinstance(versions_data, dict) else versions_data
    
    installed_versions = [v.get("version") for v in ver_list if isinstance(v, dict)]

    if svc_ver_guess not in installed_versions and svc_ver_guess != "unknown":
        print(f"[*] Uploading Version {svc_ver_guess} to existing Service...")
        
        payload_vsphere_ver = {
            "vsphere_spec": {
                "version_spec": {
                    "content": b64_content,
                    "accept_eula": True
                }
            }
        }
        r = robust_post(session, f"https://{host}/api/vcenter/namespace-management/supervisor-services/{svc_id}/versions", payload_vsphere_ver)
        
        if r.status_code >= 400 and "unique_violation" not in r.text and "AlreadyExists" not in r.text:
            payload_carvel_ver = {"carvel_spec": {"version_spec": {"content": b64_content}}}
            r = robust_post(session, f"https://{host}/api/vcenter/namespace-management/supervisor-services/{svc_id}/versions", payload_carvel_ver)

        if r.status_code >= 400 and "unique_violation" not in r.text and "AlreadyExists" not in r.text:
            print(f"[-] Failed to upload version! HTTP {r.status_code}")
            try: print(json.dumps(r.json(), indent=2))
            except: print(r.text)
            sys.exit(1)

    # --- 3. Poll for ACTIVATED status ---
    print(f"[*] Waiting for version to reach ACTIVATED state (can take 1-2 minutes)...")
    for _ in range(40):
        r = session.get(f"https://{host}/api/vcenter/namespace-management/supervisor-services/{svc_id}/versions")
        v_data = r.json()
        v_list = v_data.get("value", []) if isinstance(v_data, dict) else v_data
        
        activated_version = next((v["version"] for v in v_list if v.get("state") == "ACTIVATED" and (svc_ver_guess == "unknown" or v.get("version") == svc_ver_guess)), None)
        
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
    parser.add_argument("--cert-path", default="certs/harbor.crt")
    args = parser.parse_args()

    # Pre-flight: Avi DNS Injection
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

        # Dynamic Resolution of the Supervisor ID
        install_url = ""
        supervisor_id = None
        res_sups = session.get(f"https://{args.host}/api/vcenter/namespace-management/supervisors/summaries")
        if res_sups.status_code == 200 and res_sups.json().get("items"):
            supervisor_id = res_sups.json()["items"][0]["supervisor"]
            install_url = f"https://{args.host}/api/vcenter/namespace-management/supervisors/{supervisor_id}/supervisor-services"
            print(f"[*] Found Decoupled Supervisor ID: {supervisor_id}")
        else:
            res_clusters = session.get(f"https://{args.host}/api/vcenter/namespace-management/clusters")
            res_clusters.raise_for_status()
            clusters_data = res_clusters.json()
            cluster_list = clusters_data.get("value", []) if isinstance(clusters_data, dict) else clusters_data
            if not cluster_list:
                print("[-] No active Clusters/Supervisors found!")
                sys.exit(1)
            supervisor_id = cluster_list[0]["cluster"]
            install_url = f"https://{args.host}/api/vcenter/namespace-management/clusters/{supervisor_id}/supervisor-services"
            print(f"[*] Found Legacy Cluster ID: {supervisor_id}")

        # --- Phase 1.5: INJECT TRUSTED REGISTRY CERTIFICATE ---
        if args.fqdn and os.path.exists(args.cert_path):
            trust_harbor_registry(session, args.host, supervisor_id, args.fqdn, args.cert_path)

        # Phase 2: Installation
        payload = {"supervisor_service": svc_id, "version": svc_ver}
        if args.values_yaml:
            with open(args.values_yaml, "rb") as f:
                payload["yaml_service_config"] = base64.b64encode(f.read()).decode('utf-8')
        
        # Check 1: Pre-emptive GET Idempotency
        try:
            r_exist = session.get(install_url)
            if r_exist.status_code == 200:
                existing_data = r_exist.json()
                svc_list = existing_data.get("value", []) if isinstance(existing_data, dict) else existing_data
                
                installed_ids = []
                for item in svc_list:
                    if isinstance(item, str): installed_ids.append(item)
                    elif isinstance(item, dict):
                        installed_ids.append(item.get("supervisor_service", ""))
                        installed_ids.append(item.get("service", ""))
                        installed_ids.append(item.get("name", ""))
                
                if svc_id in installed_ids:
                    print(f"[+] Service {svc_id} is already deployed on the Supervisor. Skipping installation.")
                    sys.exit(0)
        except Exception:
            pass 

        print(f"[*] Deploying {args.service_name} onto Supervisor infrastructure...")
        r = robust_post(session, install_url, payload)
        
        # Check 2: Reactive POST Idempotency
        text_lower = r.text.lower()
        is_already_installed = r.status_code >= 400 and ("already exist" in text_lower or "already_exists" in text_lower)

        if r.status_code >= 400 and not is_already_installed:
            print(f"[-] API POST failed! HTTP {r.status_code}")
            try: print(json.dumps(r.json(), indent=2))
            except: print(r.text)
            sys.exit(1)
            
        if is_already_installed:
            print(f"[+] Service {args.service_name} is already deployed (caught by API block). Skipping.")
        else:
            print(f"[+] Successfully initiated installation of {args.service_name}!")

    except requests.exceptions.RequestException as e:
        print(f"[-] API connection failed: {e}")
        if e.response is not None:
            print(e.response.text)
        sys.exit(1)

if __name__ == "__main__":
    main()
