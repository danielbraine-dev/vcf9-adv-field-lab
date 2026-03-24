#!/usr/bin/env python3
import sys, requests, urllib3, argparse, json, base64, re, time

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

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

        # Idempotency check
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
    """Automates Phase 1: Uploading the Service Definition to vCenter's Catalog"""
    with open(definition_path, 'r') as f:
        content_raw = f.read()
    
    # Extract Service ID and Version from the Carvel YAML
    ref_match = re.search(r'refName:\s*([^\s]+)', content_raw)
    ver_match = re.search(r'version:\s*([^\s]+)', content_raw)
    
    if not ref_match or not ver_match:
        print(f"[-] Could not parse 'refName' or 'version' from {definition_path}")
        sys.exit(1)
        
    svc_id = ref_match.group(1).strip("'\"")
    svc_ver = ver_match.group(1).strip("'\"")
    
    # 1. Register the Service Name if it doesn't exist
    res = session.get(f"https://{host}/api/vcenter/namespace-management/supervisor-services")
    res.raise_for_status()
    if svc_id not in [s["supervisor_service"] for s in res.json()]:
        print(f"[*] Registering new Supervisor Service in Catalog: {svc_id}")
        session.post(f"https://{host}/api/vcenter/namespace-management/supervisor-services", 
                     json={"supervisor_service": svc_id, "name": service_name, "description": f"{service_name} deployed via automation"}).raise_for_status()

    # 2. Upload the Version YAML if it doesn't exist
    res = session.get(f"https://{host}/api/vcenter/namespace-management/supervisor-services/{svc_id}/versions")
    res.raise_for_status()
    if svc_ver not in [v["version"] for v in res.json()]:
        print(f"[*] Uploading Version {svc_ver} to vCenter...")
        session.post(f"https://{host}/api/vcenter/namespace-management/supervisor-services/{svc_id}/versions", 
                     json={"version": svc_ver, "content": base64.b64encode(content_raw.encode('utf-8')).decode('utf-8'), "eula_accept": True}).raise_for_status()

    # 3. Wait for vCenter to unpack and ACTIVATE the version
    print(f"[*] Waiting for version {svc_ver} to reach ACTIVATED state...")
    for _ in range(40):
        r = session.get(f"https://{host}/api/vcenter/namespace-management/supervisor-services/{svc_id}/versions")
        if next((v["state"] for v in r.json() if v["version"] == svc_ver), None) == "ACTIVATED":
            print(f"[+] Version {svc_ver} is ACTIVATED and ready for deployment!")
            return svc_id, svc_ver
        time.sleep(3)
        
    print("[-] Timeout waiting for Service Version to activate.")
    sys.exit(1)

def main():
    parser = argparse.ArgumentParser(description="Lifecycle a vSphere Supervisor Service.")
    parser.add_argument("--host", required=True)
    parser.add_argument("--user", required=True)
    parser.add_argument("--password", required=True)
    parser.add_argument("--service-name", required=True)
    # Changed arguments to explicitly separate Definition (App) from Values (Settings)
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
        
        # Idempotency check: Is it already on the Supervisor?
        if svc_id in [s["supervisor_service"] for s in session.get(install_url).json()]:
            print(f"[+] Service {svc_id} is already deployed on the Supervisor. Skipping.")
            sys.exit(0)
            
        print(f"[*] Deploying {args.service_name} onto Supervisor {supervisor_id}...")
        session.post(install_url, json=payload).raise_for_status()
        print(f"[+] Successfully initiated installation of {args.service_name}!")

    except requests.exceptions.RequestException as e:
        print(f"[-] API call failed! HTTP {e.response.status_code if e.response is not None else 'Unknown'}")
        if e.response is not None: print(e.response.text)
        sys.exit(1)

if __name__ == "__main__":
    main()
