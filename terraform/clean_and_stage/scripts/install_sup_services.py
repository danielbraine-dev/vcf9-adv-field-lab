#!/usr/bin/env python3
import sys, requests, urllib3, argparse, json, base64

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

def inject_avi_dns(avi_ip, avi_user, avi_pass, fqdn, target_ip):
    """Handles the Avi REST API logic for injecting a DNS A-Record."""
    session = requests.Session()
    session.verify = False
    try:
        login_res = session.post(f"https://{avi_ip}/login", data={"username": avi_user, "password": avi_pass})
        login_res.raise_for_status()
        
        csrf_token = session.cookies.get("csrftoken")
        headers = {
            "X-CSRFToken": csrf_token,
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
        
        if "record_table" not in dns_domain:
            dns_domain["record_table"] = []

        # Idempotency check
        original_count = len(dns_domain["record_table"])
        dns_domain["record_table"] = [rec for rec in dns_domain["record_table"] if fqdn not in rec.get("fqdn", [])]

        # Append new A-Record
        dns_domain["record_table"].append({
            "fqdn": [fqdn],
            "type": "DNS_RECORD_A",
            "ip_address": {"addr": target_ip, "type": "V4"}
        })

        update_res = session.put(f"https://{avi_ip}/api/ipamdnsproviderprofile/{profile_uuid}", headers=headers, json=dns_profile)
        update_res.raise_for_status()
        
        action = "Updated" if original_count == len(dns_domain["record_table"]) else "Added"
        print(f"[+] Successfully {action} DNS Record in Avi: {fqdn} -> {target_ip}")
        return True

    except requests.exceptions.RequestException as e:
        print(f"[-] Avi API DNS injection failed: {e}")
        if e.response is not None: print(e.response.text)
        sys.exit(1)

def main():
    parser = argparse.ArgumentParser(description="Install a vSphere Supervisor Service and optionally inject Avi DNS.")
    # vCenter Args (Required)
    parser.add_argument("--host", required=True, help="vCenter Hostname/IP")
    parser.add_argument("--user", required=True, help="vCenter Username")
    parser.add_argument("--password", required=True, help="vCenter Password")
    parser.add_argument("--service-name", required=True, help="Name of the service (e.g., 'contour' or 'harbor')")
    parser.add_argument("--config-yaml", help="Path to the service configuration YAML file")
    
    # Avi DNS Args (Optional)
    parser.add_argument("--avi-ip", help="Avi Controller IP (Triggers DNS injection)")
    parser.add_argument("--avi-user", default="admin", help="Avi Username")
    parser.add_argument("--avi-pass", help="Avi Password")
    parser.add_argument("--fqdn", help="The FQDN to register in Avi")
    parser.add_argument("--target-ip", help="The IP address to map to the FQDN")
    args = parser.parse_args()

    # If Avi arguments are provided, handle DNS injection FIRST
    if args.avi_ip and args.fqdn and args.target_ip:
        print(f"[*] Pre-flight task: Injecting DNS mapping for {args.fqdn}...")
        inject_avi_dns(args.avi_ip, args.avi_user, args.avi_pass, args.fqdn, args.target_ip)

    session = requests.Session()
    session.auth = (args.user, args.password)
    session.verify = False

    try:
        # 1. Authenticate to vCenter
        res = session.post(f"https://{args.host}/api/session")
        res.raise_for_status()
        session.headers.update({"vmware-api-session-id": res.json()})

        # 2. Get Supervisor Cluster ID
        res = session.get(f"https://{args.host}/api/vcenter/namespace-management/clusters")
        res.raise_for_status()
        clusters = res.json()
        if not clusters:
            print("[-] No Supervisor-enabled clusters found!")
            sys.exit(1)
        supervisor_id = clusters[0]["cluster"]

        # 3. Look up the Supervisor Service ID
        res = session.get(f"https://{args.host}/api/vcenter/namespace-management/supervisor-services")
        res.raise_for_status()
        target_service = next((s for s in res.json() if args.service_name.lower() in s.get("name", "").lower()), None)
        if not target_service:
            print(f"[-] Could not find a registered Supervisor Service matching '{args.service_name}'.")
            sys.exit(1)
        service_id = target_service["supervisor_service"]

        # 4. Get the latest ACTIVATED version
        res = session.get(f"https://{args.host}/api/vcenter/namespace-management/supervisor-services/{service_id}/versions")
        res.raise_for_status()
        versions = [v for v in res.json() if v.get("state") == "ACTIVATED"]
        if not versions:
            print(f"[-] No ACTIVATED versions found for service {args.service_name}.")
            sys.exit(1)
        version_id = versions[0]["version"]

        # 5. Prepare Payload & Encode YAML
        payload = {"supervisor_service": service_id, "version": version_id}
        if args.config_yaml:
            with open(args.config_yaml, "rb") as f:
                payload["yaml_service_config"] = base64.b64encode(f.read()).decode('utf-8')
                print(f"[*] Attached and encoded config file: {args.config_yaml}")

        # 6. Install the Service
        print(f"[*] Installing {args.service_name} (Version: {version_id}) on Supervisor...")
        res = session.post(f"https://{args.host}/api/vcenter/namespace-management/supervisors/{supervisor_id}/supervisor-services", json=payload)
        
        if res.status_code == 201:
            print(f"[+] Successfully initiated installation of {args.service_name}!")
        else:
            res.raise_for_status()

    except requests.exceptions.RequestException as e:
        print(f"[-] API call failed! HTTP {e.response.status_code if e.response is not None else 'Unknown'}")
        if e.response is not None: print(e.response.text)
        sys.exit(1)
    except FileNotFoundError:
        print(f"[-] Config YAML file not found at path: {args.config_yaml}")
        sys.exit(1)

if __name__ == "__main__":
    main()
