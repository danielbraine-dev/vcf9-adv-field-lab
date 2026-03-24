#!/usr/bin/env python3
import sys, requests, urllib3, argparse, json, base64

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

def main():
    parser = argparse.ArgumentParser(description="Install a vSphere Supervisor Service.")
    parser.add_argument("--host", required=True, help="vCenter Hostname/IP")
    parser.add_argument("--user", required=True, help="vCenter Username")
    parser.add_argument("--password", required=True, help="vCenter Password")
    parser.add_argument("--service-name", required=True, help="Name of the service (e.g., 'contour' or 'harbor')")
    parser.add_argument("--config-yaml", help="Path to the service configuration YAML file")
    args = parser.parse_args()

    session = requests.Session()
    session.auth = (args.user, args.password)
    session.verify = False

    try:
        # 1. Authenticate
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
        services = res.json()
        
        # Match by name (case-insensitive substring match)
        target_service = next((s for s in services if args.service_name.lower() in s.get("name", "").lower()), None)
        if not target_service:
            print(f"[-] Could not find a registered Supervisor Service matching '{args.service_name}'. Is it uploaded to vCenter?")
            sys.exit(1)
            
        service_id = target_service["supervisor_service"]

        # 4. Get the latest ACTIVATED version of the service
        res = session.get(f"https://{args.host}/api/vcenter/namespace-management/supervisor-services/{service_id}/versions")
        res.raise_for_status()
        versions = [v for v in res.json() if v.get("state") == "ACTIVATED"]
        
        if not versions:
            print(f"[-] No ACTIVATED versions found for service {args.service_name}.")
            sys.exit(1)
            
        # Assuming the first one in the list is the desired/latest version
        version_id = versions[0]["version"]

        # 5. Prepare the Payload
        payload = {
            "supervisor_service": service_id,
            "version": version_id
        }

        # Base64 encode the YAML config if provided
        if args.config_yaml:
            with open(args.config_yaml, "rb") as f:
                encoded_yaml = base64.b64encode(f.read()).decode('utf-8')
                payload["yaml_service_config"] = encoded_yaml
                print(f"[*] Attached and encoded config file: {args.config_yaml}")

        # 6. Install the Service on the Supervisor
        print(f"[*] Installing {args.service_name} (Version: {version_id}) on Supervisor {supervisor_id}...")
        install_url = f"https://{args.host}/api/vcenter/namespace-management/supervisors/{supervisor_id}/supervisor-services"
        res = session.post(install_url, json=payload)
        
        # 201 is Success per your API Spec
        if res.status_code == 201:
            print(f"[+] Successfully initiated installation of {args.service_name}!")
        else:
            res.raise_for_status()

    except requests.exceptions.RequestException as e:
        print(f"[-] API call failed! HTTP {e.response.status_code if e.response is not None else 'Unknown'}")
        if e.response is not None:
            print("\n--- Error Response ---")
            try:
                print(json.dumps(e.response.json(), indent=2))
            except:
                print(e.response.text)
            print("----------------------\n")
        sys.exit(1)
    except FileNotFoundError:
        print(f"[-] Config YAML file not found at path: {args.config_yaml}")
        sys.exit(1)

if __name__ == "__main__":
    main()
