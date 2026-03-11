#!/usr/bin/env bash
set -euo pipefail

# Enable tracing with TRACE=1 ./setup.sh …
[[ "${TRACE:-0}" == "1" ]] && set -x

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TFVARS_FILE="${ROOT_DIR}/terraform.tfvars"
  
log()   { printf "\n\033[1;36m%s\033[0m\n" "$*"; }
warn()  { printf "\n\033[1;33m%s\033[0m\n" "$*"; }
error() { printf "\n\033[1;31m%s\033[0m\n" "$*"; }

pause() { [[ "${PAUSE:-0}" == "1" ]] && read -rp "→ Press Enter to continue…" || true; }

# Global Helper to read standard strings from tfvars
read_tfvar() { awk -F= -v key="$1" '$1 ~ "^[[:space:]]*"key"[[:space:]]*$" {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); gsub(/^"|"$|;$/,"",$2); print $2}' "${TFVARS_FILE}" | tail -n1; }

step1_install_tools() {
  echo "[1] Install tools…"
  if [[ -f "${ROOT_DIR}/commands.txt" ]]; then
    log "Installing tools from commands.txt…"
    while IFS= read -r command; do
      [[ -z "$command" || "$command" =~ ^# ]] && continue
      echo "Executing: $command"
      bash -lc "$command" || warn "Command failed (continuing): $command"
    done < "${ROOT_DIR}/commands.txt"
  else
    warn "commands.txt not found; skipping tool install."
  fi
  pause
}

step2_teardown_environment() {
  echo "[2] Teardown existing VCF & vCenter environment…"
  if [[ -f "${ROOT_DIR}/scripts/teardown_vcfa.py" ]]; then
    log "Executing Python teardown script..."
    python3 "${ROOT_DIR}/scripts/teardown_vcfa.py" || { error "Teardown script failed!"; exit 1; }
  else
    error "teardown_vcfa.py not found in ${ROOT_DIR}/scripts!"
    exit 1
  fi
  pause
}

step3_tf_init() {
  echo "[3] terraform init/validate…"
  if [[ ! -f "${TFVARS_FILE}" ]]; then
    log "Creating ${TFVARS_FILE} with ALL original lab defaults…"
    cat > "${TFVARS_FILE}" <<'EOF'
  # ---- NSX ----
  nsx_host                 = "nsx-wld01-a.site-a.vcf.lab"
  nsx_username             = "admin"
  nsx_password             = "VMware123!VMware123!"
  nsx_allow_unverified_ssl = true
  
  # ---- vSphere ----
  vsphere_server     = "vc-wld01-a.site-a.vcf.lab"
  vsphere_user       = "administrator@wld.sso"
  vsphere_password   = "VMware123!VMware123!"
  vsphere_datacenter = "wld-01a-DC"
  vsphere_cluster    = "cluster-wld01-01a"
  vsphere_datastore  = "cluster-wld01-01a-vsan01"
  
  # ---- VCFA provider ----
  vcfa_endpoint    = "https://auto-a.site-a.vcf.lab"
  vcfa_token       = "<PUT_YOUR_VCFA_TOKEN_HERE>"
  
  # ---- AVI OVA deploy ----
  avi_ova_path           = "/path/to/Controller.ova"
  avi_vm_name            = "avi-controller01-a"
  avi_mgmt_pg            = "<MGMT_PORTGROUP_NAME>"
  avi_mgmt_ip            = "10.1.1.200"
  avi_mgmt_netmask       = "255.255.255.0"
  avi_mgmt_gateway       = "10.1.1.1"
  avi_dns_servers        = ["10.1.1.1"]
  avi_ntp_servers        = ["10.1.1.1"]
  avi_domain_search      = "site-a.vcf.lab"
  avi_admin_password     = "VMware123!VMware123!"
  
  # ---- Supervisor enable
  sup_mgmt_ip_range      = "10.1.1.85-10.1.1.95"
  sup_mgmt_netmask       = "255.255.255.0"
  sup_mgmt_gateway       = "10.1.1.1"
  sup_dns_servers        = ["10.1.1.1"]
  sup_ntp_servers        = ["10.1.1.1"]
  sup_dns_search         = "site-a.vcf.lab"

  # Workload settings
  nsx_project_name             = "Default"
  nsx_vpc_connectivity_profile = "Default VPC Connectivity Profile"
  ext_ipblock_name             = "VPC-External-Block"
  ext_ipblock_cidr             = "10.1.0.0/24"
  ext_ipblock_range            = "10.1.0.7-10.1.0.255"
  tgw_ipblock_name             = "Supervisor TGW IP Block"
  tgw_ipblock_cidr             = "172.16.101.0/24"
  tgw_ipblock_range            = "172.16.101.1-172.16.101.254"
  workload_vpc_cidrs           = ["172.16.201.0/24"]
  service_cidr                 = "10.96.0.0/23"
EOF
fi
  log "Running terraform init…"
  terraform -chdir="${ROOT_DIR}" init -upgrade
  terraform -chdir="${ROOT_DIR}" validate
  pause
}

step4_create_nsx_objects(){
  log "[4] Applying NSX/vSphere creation stack…"
  terraform -chdir="${ROOT_DIR}" apply -auto-approve \
    -target='nsxt_policy_dhcp_server.common_dhcp' \
    -target='nsxt_policy_tier1_gateway.t1_se_services' \
    -target='nsxt_policy_segment.se_mgmt' \
    -target='nsxt_policy_segment.se_data_vip' \
    -target='vsphere_content_library.avi_se_cl'
  pause
}

step5_deploy_avi(){
  log "[5] Deploying Avi Controller via govc..."

  # 1. Apply Terraform to build the Resource Pool & Content Library
  terraform -chdir="${ROOT_DIR}" apply -auto-approve \
    -target='vsphere_resource_pool.avi' \
    -target='vsphere_content_library.avi_se_cl'

  # 2. Locate the OVA
  FINAL_OVA_PATH=$(ls -1 "${ROOT_DIR}"/*.ova 2>/dev/null | head -n1)
  [[ -z "$FINAL_OVA_PATH" ]] && { error "No OVA found!"; exit 1; }

  # 3. Set vCenter Auth (Ensure these match your lab)
  export GOVC_URL="vc-wld01-a.site-a.vcf.lab"
  export GOVC_USERNAME="administrator@wld.sso"
  export GOVC_PASSWORD="VMware123!VMware123!"
  export GOVC_INSECURE=1

  log "Importing OVA natively to vCenter via govc..."
  
  # 4. Deploy via govc
  govc import.ova \
    -options="${ROOT_DIR}/avi_vapp_options.json" \
    -dc="dc-a" \
    -ds="vsan-wld01-01a" \
    -pool="cluster-wld01-01a/Resources/Avi-Controller" \
    -name="avi-controller01" \
    "${FINAL_OVA_PATH}"

  log "Powering on Avi Controller..."
  govc vm.power -on "avi-controller01"

  # 5. Wait for API
  log "Waiting for Avi API at https://10.1.1.200..."
  until curl -sk --max-time 5 "https://10.1.1.200/api/initial-data" >/dev/null; do
    printf "."
    sleep 20
  done
  log -e "\n[+] Avi Controller is responding. Ready for Step 6."
  pause
}

step6_init_avi(){
  log "[6] Initializing Avi Controller System Configuration (Zero-Touch)..."

  # Dynamically pull variables from tfvars
  AVI_IP=$(read_tfvar avi_mgmt_ip)
  AVI_PASS=$(read_tfvar avi_admin_password)
  DOMAIN=$(read_tfvar avi_domain_search)
  AVI_VERSION="31.2.2" 
  
  # Safely extract the IP from the arrays like ["10.1.1.1"]
  DNS_IP=$(grep '^avi_dns_servers' "${TFVARS_FILE}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1)
  NTP_IP=$(grep '^avi_ntp_servers' "${TFVARS_FILE}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1)

  log "Authenticating with Avi API..."
  curl -sk -c "${ROOT_DIR}/avi_cookies.txt" -X POST "https://${AVI_IP}/login" \
    -d "username=admin&password=${AVI_PASS}" > /dev/null

  CSRF_TOKEN=$(awk '/csrftoken/ {print $7}' "${ROOT_DIR}/avi_cookies.txt")
  [[ -z "$CSRF_TOKEN" ]] && { error "Failed to get CSRF token. Is the VM booted?"; exit 1; }

  log "Bypassing initial Admin Setup screen..."
  USER_UUID=$(curl -sk -b "${ROOT_DIR}/avi_cookies.txt" \
    -H "X-Avi-Version: ${AVI_VERSION}" \
    "https://${AVI_IP}/api/useraccount" | jq -r '.results[] | select(.username=="admin") | .uuid')

  curl -sk -o /dev/null -b "${ROOT_DIR}/avi_cookies.txt" -X PUT \
    -H "X-CSRFToken: ${CSRF_TOKEN}" \
    -H "X-Avi-Version: ${AVI_VERSION}" \
    -H "Content-Type: application/json" \
    -H "Referer: https://${AVI_IP}/" \
    -d "{\"username\":\"admin\",\"password\":\"${AVI_PASS}\",\"old_password\":\"${AVI_PASS}\",\"name\":\"admin\",\"email\":\"admin@${DOMAIN}\"}" \
    "https://${AVI_IP}/api/useraccount/${USER_UUID}"

  log "[+] Admin account finalized!"
  log "Retrieving factory system configuration..."
  
  curl -sk -b "${ROOT_DIR}/avi_cookies.txt" \
    -H "X-Avi-Version: ${AVI_VERSION}" \
    "https://${AVI_IP}/api/systemconfiguration" > "${ROOT_DIR}/sysconf_raw.json"

  log "Injecting DNS ($DNS_IP) and NTP ($NTP_IP) settings..."
  jq --arg dns "$DNS_IP" \
     --arg domain "$DOMAIN" \
     --arg ntp "$NTP_IP" \
     '.dns_configuration.server_list = [{"type": "V4", "addr": $dns}] | 
      .dns_configuration.search_domain = $domain | 
      .ntp_configuration.ntp_servers = [{"server": {"type": "V4", "addr": $ntp}}]' \
     "${ROOT_DIR}/sysconf_raw.json" > "${ROOT_DIR}/sysconf_updated.json"

  log "Applying updated system configuration..."
  HTTP_STATUS=$(curl -sk -w "%{http_code}" -o /dev/null -b "${ROOT_DIR}/avi_cookies.txt" -X PUT \
    -H "X-CSRFToken: ${CSRF_TOKEN}" \
    -H "X-Avi-Version: ${AVI_VERSION}" \
    -H "Referer: https://${AVI_IP}/" \
    -H "Content-Type: application/json" \
    -d @"${ROOT_DIR}/sysconf_updated.json" \
    "https://${AVI_IP}/api/systemconfiguration")

  if [[ "$HTTP_STATUS" == "200" || "$HTTP_STATUS" == "201" ]]; then
    log "[+] Avi Controller System Configuration applied successfully!"
  else
    error "[-] Failed to apply configuration. HTTP Status: $HTTP_STATUS"
    exit 1
  fi

  rm -f "${ROOT_DIR}/sysconf_raw.json" "${ROOT_DIR}/sysconf_updated.json" "${ROOT_DIR}/avi_cookies.txt"
  pause
}

step7_create_cert(){
  log "[7] Creating Certificates and Uploading to NSX…"
  AVI_FQDN="avi-controller01-a.site-a.vcf.lab"
  log "Waiting for Avi API at https://${AVI_FQDN}…"
  until curl -sk --max-time 5 "https://${AVI_FQDN}/api/initial-data" >/dev/null; do
    sleep 10
  done

  terraform -chdir="${ROOT_DIR}" apply -auto-approve \
    -target=tls_private_key.avi \
    -target=tls_self_signed_cert.avi \
    -target=avi_sslkeyandcertificate.portal \
    -target=avi_systemconfiguration.this \
    -target=local_file.avi_cert_pem \
    -target=local_file.avi_key_pem

  NSX_HOST="$(read_tfvar nsx_host)"
  NSX_USER="$(read_tfvar nsx_username)"
  NSX_PASS="$(read_tfvar nsx_password)"
  CERT_PATH="${ROOT_DIR}/out/avi-portal.crt"
  CERT_NAME="$(read_tfvar avi_cert_name || echo avi-portal-cert)"

  if [[ -z "${NSX_HOST}" || -z "${NSX_USER}" || -z "${NSX_PASS}" ]]; then
    warn "NSX variables missing; skipping NSX trust upload."
  else
    log "Uploading Avi portal cert to NSX trust store…"
    bash "${ROOT_DIR}/scripts/upload_nsx_cert.sh" "$NSX_HOST" "$NSX_USER" "$NSX_PASS" "$CERT_PATH" "$CERT_NAME"
  fi
  pause
}

step8_nsx_cloud(){
  log "[8] NSXCloud Setup (Two-Pass)…"
  terraform -chdir="${ROOT_DIR}" apply -auto-approve \
    -var="attach_ipam_now=false" \
    -target=avi_cloud.nsx_t_cloud \
    -target=avi_vcenterserver.vc_01
  
  terraform -chdir="${ROOT_DIR}" apply -auto-approve \
    -target=data.avi_network.vip \
    -target=avi_ipamdnsproviderprofile.internal

  terraform -chdir="${ROOT_DIR}" apply -auto-approve \
    -var="attach_ipam_now=true" \
    -target=avi_cloud.nsx_t_cloud \
    -target=avi_serviceenginegroup.default
  pause
}  

step9_onboard_nsx_alb(){
  log "[9] Onboarding Avi to NSX…"
  bash "${ROOT_DIR}/scripts/nsx_onboard_alb.sh"
  pause
}

step10_install_sup(){
  log "[10] Installing Supervisor in vSphere…"
  bash "${ROOT_DIR}/scripts/install_supervisor.sh"
  pause
}

step11_provision_vcfa_objects(){
  log "[11] Provisioning VCFA Objects…"
  # Add your final terraform apply commands here
  pause
}

do_step() {
  case "$1" in
    1) step1_install_tools;;
    2) step2_teardown_environment;;
    3) step3_tf_init;;
    4) step4_create_nsx_objects;;
    5) step5_deploy_avi;;
    6) step6_init_avi;;
    7) step7_create_cert;;
    8) step8_nsx_cloud;;
    9) step9_onboard_nsx_alb;;
   10) step10_install_sup;;
   11) step11_provision_vcfa_objects;;
    *) echo "Unknown step $1"; exit 2;;
  esac
}

run() {
  local spec="${1:-all}"
  if [[ "$spec" == "all" ]]; then
    for n in {1..11}; do do_step "$n"; done
    echo "All steps complete. ✅"
    return
  fi
  IFS=',' read -ra parts <<< "$spec"
  for p in "${parts[@]}"; do
    if [[ "$p" =~ ^([0-9]+)[-:]([0-9]+)$ ]]; then
      for n in $(seq "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"); do do_step "$n"; done
    elif [[ "$p" =~ ^[0-9]+$ ]]; then
      do_step "$p"
    else
      echo "Bad step spec: '$p'"; exit 2
    fi
  done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  run "${1:-all}"
fi
