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

step1_install_tools_verify_vcfa() {
  log "[1] Phase A: Installing Tools from commands.txt…"
  
  if [[ -f "${ROOT_DIR}/commands.txt" ]]; then
    while IFS= read -r command; do
      [[ -z "$command" || "$command" =~ ^# ]] && continue
      echo "Executing: $command"
      bash -lc "$command" || warn "Command failed (continuing): $command"
    done < "${ROOT_DIR}/commands.txt"
  else
    warn "commands.txt not found; skipping tool install."
  fi

  log "\n[1] Phase B: Checking VCFA UI for 'no healthy upstream'..."
  local VCFA_URL="https://auto-a.site-a.vcf.lab/login/login?service=provider"
  
  # Fetch the UI page, bypassing SSL (-k) and running silently (-s)
  local RESPONSE=$(curl -s -k -L "$VCFA_URL" || true)

  if echo "$RESPONSE" | grep -i "no healthy upstream"; then
    log "[!] Detected 'no healthy upstream'. Applying KB 419711 workaround..."

    # Use sshpass to log in, and pipe the password to sudo to silently elevate to root
    sshpass -p 'VMware123!VMware123!' ssh -o StrictHostKeyChecking=no vmware-system-user@auto-a.site-a.vcf.lab << 'EOF'
echo 'VMware123!VMware123!' | sudo -S su - << 'ROOT_EOF'
export KUBECONFIG=/etc/kubernetes/admin.conf
echo "Restarting vsphere-csi-controller..."
kubectl rollout restart deployments/vsphere-csi-controller -n kube-system

# Give the API server a few seconds to acknowledge the rollout before pulling the plug
sleep 5
echo "Rebooting the VCFA appliance..."
reboot
ROOT_EOF
EOF

    log "[*] Reboot initiated. Waiting for VCFA to return (Timeout: 15 minutes)..."
    sleep 60
    
    # Wait loop: Check every 15 seconds for up to 15 minutes (60 iterations)
    for ((i=1; i<=60; i++)); do
      local STATUS_CHECK=$(curl -s -k -L  "$VCFA_URL" || true)
      
      # If curl succeeds AND the page no longer says 'no healthy upstream'
      if [[ -n "$STATUS_CHECK" ]] && ! echo "$STATUS_CHECK" | grep -i "no healthy upstream"; then
        printf "\n"
        log "[+] VCFA is healthy and back online!"
        break
      fi
      
      printf "."
      sleep 15
      
      # Exit if we hit the 15-minute timeout
      [[ $i -eq 60 ]] && { error "\n[-] Timeout waiting for VCFA to recover."; exit 1; }
    done

  else
    log "[+] VCFA UI is responding normally. Skipping KB workaround."
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
    vsphere_datacenter = "dc-a"
    vsphere_cluster    = "cluster-wld01-01a"
    vsphere_datastore  = "vsan-wld01-01a"
    
    # ---- VCFA provider ----
    vcfa_endpoint    = "https://auto-a.site-a.vcf.lab"
    vcfa_token       = ""
    
    # ---- AVI OVA deploy ----
    avi_ova_path           = "/path/to/Controller.ova"
    avi_vm_name            = "avi-controller01"
    avi_mgmt_pg            = "mgmt-vds01-wld01-01a"
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

  if [[ -f "${ROOT_DIR}/scripts/add_dns_record.sh" ]]; then
    log "Injecting DNS Records for Avi components..."
    bash "${ROOT_DIR}/scripts/add_dns_record.sh" || warn "Failed to add DNS records."
  fi

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

  AVI_IP=$(read_tfvar avi_mgmt_ip)
  AVI_PASS=$(read_tfvar avi_admin_password)
  DOMAIN=$(read_tfvar avi_domain_search)
  AVI_VERSION="31.2.2" 
  
  DNS_IP=$(grep 'avi_dns_servers' "${TFVARS_FILE}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || echo "10.1.1.1")
  NTP_IP=$(grep 'avi_ntp_servers' "${TFVARS_FILE}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || echo "10.1.1.1")

  log "Authenticating with Avi API at ${AVI_IP}..."
  curl -sk -c "${ROOT_DIR}/avi_cookies.txt" -X POST "https://${AVI_IP}/login" \
    -d "username=admin&password=${AVI_PASS}" > /dev/null

  CSRF_TOKEN=$(awk '/csrftoken/ {print $7}' "${ROOT_DIR}/avi_cookies.txt")
  [[ -z "$CSRF_TOKEN" ]] && { error "Failed to get CSRF token. Is the VM booted?"; exit 1; }

  # 1. BYPASS USER SETUP
  log "Bypassing initial Admin Setup screen..."
  HTTP_SETUP=$(curl -sk -w "%{http_code}" -o /dev/null -b "${ROOT_DIR}/avi_cookies.txt" -X PUT \
    -H "X-CSRFToken: ${CSRF_TOKEN}" \
    -H "X-Avi-Version: ${AVI_VERSION}" \
    -H "Content-Type: application/json" \
    -H "Referer: https://${AVI_IP}/" \
    -d "{\"username\":\"admin\",\"password\":\"${AVI_PASS}\",\"old_password\":\"${AVI_PASS}\",\"name\":\"admin\",\"email\":\"admin@${DOMAIN}\"}" \
    "https://${AVI_IP}/api/useraccount")

  if [[ "$HTTP_SETUP" == "200" || "$HTTP_SETUP" == "201" ]]; then
      log "[+] Admin account finalized!"
  else
      error "[-] Failed to set password. HTTP: $HTTP_SETUP"
      exit 1
  fi

  # 2. SET BACKUP PASSPHRASE
  log "Retrieving Backup Configuration..."
  curl -sk -b "${ROOT_DIR}/avi_cookies.txt" \
    -H "X-Avi-Version: ${AVI_VERSION}" \
    "https://${AVI_IP}/api/backupconfiguration" > "${ROOT_DIR}/backupconf_raw.json"

  BACKUP_UUID=$(jq -r '.results[0].uuid' "${ROOT_DIR}/backupconf_raw.json")

  log "Setting Backup Passphrase..."
  jq --arg pass "${AVI_PASS}" \
     '.results[0] | .passphrase = $pass' \
     "${ROOT_DIR}/backupconf_raw.json" > "${ROOT_DIR}/backupconf_updated.json"

  HTTP_BACKUP=$(curl -sk -w "%{http_code}" -o /dev/null -b "${ROOT_DIR}/avi_cookies.txt" -X PUT \
    -H "X-CSRFToken: ${CSRF_TOKEN}" \
    -H "X-Avi-Version: ${AVI_VERSION}" \
    -H "Referer: https://${AVI_IP}/" \
    -H "Content-Type: application/json" \
    -d @"${ROOT_DIR}/backupconf_updated.json" \
    "https://${AVI_IP}/api/backupconfiguration/${BACKUP_UUID}")

  if [[ "$HTTP_BACKUP" == "200" || "$HTTP_BACKUP" == "201" ]]; then
    log "[+] Backup Configuration (Passphrase) applied successfully!"
  else
    warn "[-] Failed to set Backup Passphrase. HTTP: $HTTP_BACKUP"
  fi

  # 3. SET SYSTEM CONFIGURATION & COMPLETE WORKFLOW
  log "Retrieving factory system configuration..."
  curl -sk -b "${ROOT_DIR}/avi_cookies.txt" \
    -H "X-Avi-Version: ${AVI_VERSION}" \
    "https://${AVI_IP}/api/systemconfiguration" > "${ROOT_DIR}/sysconf_raw.json"

  # We add '.welcome_workflow_complete = true' to bypass the UI wizard entirely
  log "Injecting DNS ($DNS_IP), NTP ($NTP_IP), and bypassing Welcome wizard..."
  jq --arg dns "$DNS_IP" \
     --arg domain "$DOMAIN" \
     --arg ntp "$NTP_IP" \
     '.dns_configuration.server_list = [{"type": "V4", "addr": $dns}] | 
      .dns_configuration.search_domain = $domain | 
      .ntp_configuration.ntp_servers = [{"server": {"type": "V4", "addr": $ntp}}] |
      .welcome_workflow_complete = true' \
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

  rm -f "${ROOT_DIR}"/*_raw.json "${ROOT_DIR}"/*_updated.json "${ROOT_DIR}/avi_cookies.txt"
  pause
}

step7_avi_base_config(){
  log "[7] Applying Day-1 Avi Config and Establishing NSX Trust…"
  
  # Quick validation to ensure API is ready
  until curl -sk --max-time 5 "https://10.1.1.200/api/initial-data" >/dev/null; do sleep 5; done

  terraform -chdir="${ROOT_DIR}" init -upgrade

  terraform -chdir="${ROOT_DIR}" apply -auto-approve \
    -target=tls_private_key.avi \
    -target=tls_self_signed_cert.avi \
    -target=avi_sslkeyandcertificate.portal \
    -target=avi_systemconfiguration.this \
    -target=local_file.avi_cert_pem \
    -target=local_file.avi_key_pem \
    -target=avi_cloudconnectoruser.vcenter_admin \
    -target=avi_cloudconnectoruser.nsx_admin \
    -target=avi_ipamdnsproviderprofile.avi_ipam \
    -target=avi_ipamdnsproviderprofile.avi_dns

  # Read variables for the NSX trust script
  NSX_HOST="$(read_tfvar nsx_host)"
  NSX_USER="$(read_tfvar nsx_username)"
  NSX_PASS="$(read_tfvar nsx_password)"
  AVI_IP="$(read_tfvar avi_mgmt_ip)"
  AVI_PASS="$(read_tfvar avi_admin_password)"

  log "Triggering NSX ALB Onboarding Workflow..."
  bash "${ROOT_DIR}/scripts/nsx_alb_onboarding.sh" "$NSX_HOST" "$NSX_USER" "$NSX_PASS" "$AVI_IP" "admin" "$AVI_PASS"
  
  pause
}

step8_nsx_cloud(){
  log "[8] NSXCloud Setup & DNS Virtual Service…"
  
  # THE FIX: Aggressively strip quotes, carriage returns, and newlines from TF vars
  AVI_IP=$(read_tfvar avi_mgmt_ip | tr -d '"\r\n')
  AVI_USER=$(read_tfvar avi_admin_user | tr -d '"\r\n')
  AVI_PASS=$(read_tfvar avi_admin_password | tr -d '"\r\n')
  AVI_VERSION=$(read_tfvar avi_version | tr -d '"\r\n')

  # THE FIX: Use jq to safely encode the JSON payload so special characters don't break it
  LOGIN_PAYLOAD=$(jq -n --arg username "$AVI_USER" --arg password "$AVI_PASS" '{username: $username, password: $password}')

  # ==========================================
  # PRE-FLIGHT CHECK: Is the cloud already healthy?
  # ==========================================
  EXISTING_CLOUD_UUID=$(terraform -chdir="${ROOT_DIR}" state show avi_cloud.nsx_cloud 2>/dev/null | grep '^ *uuid' | awk '{print $3}' | tr -d '"' || true)

  if [[ -n "$EXISTING_CLOUD_UUID" ]]; then
    log "[*] Found NSX Cloud in Terraform state. Checking Avi API for current health..."
    
    PREFLIGHT_COOKIE=$(mktemp /tmp/avi_preflight_XXXXXX.txt)
    
    LOGIN_STATUS=$(curl -s -k -o /dev/null -w "%{http_code}" -X POST "https://${AVI_IP}/login" \
      -H "Content-Type: application/json" \
      -d "$LOGIN_PAYLOAD" \
      -c "$PREFLIGHT_COOKIE" || echo "000")

    if [[ "$LOGIN_STATUS" == "200" || "$LOGIN_STATUS" == "204" ]]; then
      PREFLIGHT_CSRF=$(grep csrftoken "$PREFLIGHT_COOKIE" 2>/dev/null | awk '{print $7}' || true)
      
      if [[ -n "$PREFLIGHT_CSRF" ]]; then
        CLOUD_STATUS=$(curl -s -k -X GET "https://${AVI_IP}/api/cloud/${EXISTING_CLOUD_UUID}/status" \
          -H "X-CSRFToken: ${PREFLIGHT_CSRF}" \
          -H "X-Avi-Version: ${AVI_VERSION}" \
          -H "Referer: https://${AVI_IP}/" \
          -b "$PREFLIGHT_COOKIE" || true)

        STATE=$(echo "$CLOUD_STATUS" | jq -r '.state' 2>/dev/null || true)
        
        if [[ "$STATE" == "CLOUD_STATE_PLACED" || "$STATE" == "CLOUD_STATE_READY" || "$STATE" == "CLOUD_STATE_OPERATIONAL" ]]; then
          log "[+] NSX Cloud is already deployed and fully operational! (State: $STATE)"
          log "[+] Skipping Step 8."
          rm -f "$PREFLIGHT_COOKIE"
          pause
          return 0
        else
          log "[-] Cloud exists but is in state '$STATE'. Proceeding with Terraform apply..."
        fi
      else
        log "[-] Authenticated, but could not extract CSRF token. Proceeding..."
      fi
    else
      log "[-] Pre-flight Avi login failed (HTTP $LOGIN_STATUS). Proceeding with Terraform apply..."
      log "    (Debug) IP: $AVI_IP | User: $AVI_USER"
    fi
    
    rm -f "$PREFLIGHT_COOKIE"
  else
    log "[*] NSX Cloud not found in local state. Beginning deployment..."
  fi

  # ==========================================
  # PHASE 1: TERRAFORM CREATION
  # ==========================================
  terraform -chdir="${ROOT_DIR}" apply -auto-approve \
    -target=avi_cloud.nsx_cloud \
    -target=avi_vcenterserver.wld01_vc
  
  terraform -chdir="${ROOT_DIR}" apply -auto-approve \
    -target=avi_serviceenginegroup.avi_lab_se_group

  SE_UUID=$(terraform -chdir="${ROOT_DIR}" state show avi_serviceenginegroup.avi_lab_se_group | grep '^ *uuid' | awk '{print $3}' | tr -d '"')
  [[ -z "$SE_UUID" ]] && { error "[-] Failed to extract SE Group UUID!"; exit 1; }

  log "Stitching SE Group UUID ($SE_UUID) back into the NSX Cloud..."
  terraform -chdir="${ROOT_DIR}" apply -auto-approve \
    -var="se_group_uuid=${SE_UUID}" \
    -target=avi_cloud.nsx_cloud

  log "Waiting 15 seconds for Avi to sync NSX-T VRF Contexts..."
  sleep 15

  log "Deploying Delegated DNS Virtual Service..."
  terraform -chdir="${ROOT_DIR}" apply -auto-approve \
    -var="se_group_uuid=${SE_UUID}" \
    -target=data.avi_vrfcontext.t1_se_services \
    -target=avi_vsvip.dns_vip \
    -target=avi_virtualservice.delegated_dns

  DNS_VS_UUID=$(terraform -chdir="${ROOT_DIR}" state show avi_virtualservice.delegated_dns | grep '^ *uuid' | awk '{print $3}' | tr -d '"')
  [[ -z "$DNS_VS_UUID" ]] && { error "[-] Failed to extract DNS VS UUID!"; exit 1; }

  log "Attaching Delegated DNS to System Configuration..."
  terraform -chdir="${ROOT_DIR}" apply -auto-approve \
    -var="se_group_uuid=${SE_UUID}" \
    -var="dns_vs_uuid=${DNS_VS_UUID}" \
    -target=avi_systemconfiguration.this

  # ==========================================
  # PHASE 2: POST-DEPLOYMENT HEALTH CHECK
  # ==========================================
  log "Verifying NSX Cloud Status via Avi API..."
  
  CLOUD_UUID=$(terraform -chdir="${ROOT_DIR}" state show avi_cloud.nsx_cloud | grep '^ *uuid' | awk '{print $3}' | tr -d '"')
  [[ -z "$CLOUD_UUID" ]] && { error "[-] Failed to extract NSX Cloud UUID!"; exit 1; }

  log "Authenticating to Avi Controller at ${AVI_IP}..."
  
  VAL_COOKIE=$(mktemp /tmp/avi_val_XXXXXX.txt)
  
  VAL_LOGIN=$(curl -s -k -o /dev/null -w "%{http_code}" -X POST "https://${AVI_IP}/login" \
    -H "Content-Type: application/json" \
    -d "$LOGIN_PAYLOAD" \
    -c "$VAL_COOKIE" || echo "000")

  if [[ "$VAL_LOGIN" != "200" && "$VAL_LOGIN" != "204" ]]; then
    error "[-] FATAL: Failed to authenticate to Avi Controller (HTTP $VAL_LOGIN). Cannot verify Cloud status."
    rm -f "$VAL_COOKIE"
    exit 1
  fi

  CSRF_TOKEN=$(grep csrftoken "$VAL_COOKIE" 2>/dev/null | awk '{print $7}' || true)
  
  if [[ -z "$CSRF_TOKEN" ]]; then
    error "[-] FATAL: Authenticated to Avi, but could not retrieve CSRF token from temp file."
    rm -f "$VAL_COOKIE"
    exit 1
  fi

  log "Waiting for NSX Cloud ('$CLOUD_UUID') to report a healthy, ready state..."
  log "(This includes vCenter/NSX syncing and SE image generation. Typically 5-10 minutes.)"

  for ((i=1; i<=40; i++)); do
    CLOUD_STATUS=$(curl -s -k -X GET "https://${AVI_IP}/api/cloud/${CLOUD_UUID}/status" \
      -H "X-CSRFToken: ${CSRF_TOKEN}" \
      -H "X-Avi-Version: ${AVI_VERSION}" \
      -H "Referer: https://${AVI_IP}/" \
      -b "$VAL_COOKIE" || true)

    STATE=$(echo "$CLOUD_STATUS" | jq -r '.state' 2>/dev/null || true)
    
    if [[ "$STATE" == "CLOUD_STATE_PLACED" || "$STATE" == "CLOUD_STATE_READY" || "$STATE" == "CLOUD_STATE_OPERATIONAL" ]]; then
      printf "\n"
      log "[+] NSX Cloud is fully synced and operational! (State: $STATE)"
      break
    elif [[ "$STATE" == "CLOUD_STATE_FAILED" || "$STATE" == "CLOUD_STATE_ERROR" ]]; then
      printf "\n"
      error "[-] NSX Cloud creation failed! (State: $STATE)"
      error "    Avi API Response: $CLOUD_STATUS"
      rm -f "$VAL_COOKIE"
      exit 1
    else
      printf "."
      sleep 23
    fi

    if [[ $i -eq 40 ]]; then
      printf "\n"
      error "[-] Timeout waiting for NSX Cloud to become operational. Last State: $STATE"
      rm -f "$VAL_COOKIE"
      exit 1
    fi
  done
  
  rm -f "$VAL_COOKIE"

  log "[+] Step 8 Complete! NSX Cloud Built and System DNS Delegated."
  pause
}

step9_install_sup(){
  log "[9] Deploying vSphere Supervisor (VCF VPC Mode)…"
  
  VCFA_URL="$(read_tfvar vcfa_endpoint)"
  NSX_HOST="$(read_tfvar nsx_host)"
  NSX_USER="$(read_tfvar nsx_username)"
  NSX_PASS="$(read_tfvar nsx_password)"
  VC_HOST="$(read_tfvar vsphere_server)"
  VC_USER="$(read_tfvar vsphere_user)"
  VC_PASS="$(read_tfvar vsphere_password)"

  log "Executing Python automation for VCFA/NSX prerequisites..."
  python3 "${ROOT_DIR}/scripts/update_sup_prereqs.py" "$VCFA_URL" "$NSX_HOST" "$NSX_USER" "$NSX_PASS"
  
  log "Initiating Supervisor Deployment via vCenter API..."
  python3 "${ROOT_DIR}/scripts/deploy_supervisor.py" "$VC_HOST" "$VC_USER" "$VC_PASS"

  log "[+] Step 9 Complete! Supervisor is fully operational."
  pause
}


step10_install_supervisor_services(){
  log "[10] Installing Contour & Harbor (Consolidated API Deployment)…"

  SUP_IP=$(read_tfvar sup_mgmt_ip_range | awk -F'-' '{print $1}')
  VC_HOST="$(read_tfvar vsphere_server)"
  VC_USER="$(read_tfvar vsphere_user)"
  VC_PASS="$(read_tfvar vsphere_password)"
  
  AVI_IP="$(read_tfvar avi_mgmt_ip)"
  AVI_PASS="$(read_tfvar avi_admin_password)"
  
  HARBOR_FQDN="harbor.lb.site-a.vcf.lab"
  SERVICE_DIR="$(cd "${ROOT_DIR}/../../Supervisor_Services" && pwd)"
  
  CONTOUR_DEF="${SERVICE_DIR}/contour-service-v1.32.0.yml"
  CONTOUR_VALS="${SERVICE_DIR}/contour-data-values.yml"
  
  HARBOR_DEF="${SERVICE_DIR}/harbor-service-v2.13.1.yml"
  
  [[ ! -f "${ROOT_DIR}/scripts/install_sup_service.py" ]] && { error "install_sup_service.py missing!"; exit 1; }
  [[ ! -f "${CONTOUR_DEF}" ]] && { error "Contour definition YAML not found at ${CONTOUR_DEF}!"; exit 1; }
  [[ ! -f "${CONTOUR_VALS}" ]] && { error "Contour values YAML not found at ${CONTOUR_VALS}!"; exit 1; }
  [[ ! -f "${HARBOR_DEF}" ]] && { error "Harbor definition YAML not found at ${HARBOR_DEF}!"; exit 1; }

  # --- 1. INSTALL CONTOUR & GET IP ---
  log "Calling vCenter API to Register & Install Contour Supervisor Service..."
  # Fix: Added the --values-yaml argument to the Contour installation
  python3 "${ROOT_DIR}/scripts/install_sup_service.py" \
    --host "${VC_HOST}" --user "${VC_USER}" --password "${VC_PASS}" \
    --service-name "contour" \
    --definition-yaml "${CONTOUR_DEF}" \
    --values-yaml "${CONTOUR_VALS}" || exit 1

  CTX_NAME="lab-supervisor"
  export VCF_CLI_VSPHERE_PASSWORD="${VC_PASS}"
  export VSPHERE_PASSWORD="${VC_PASS}"
  export KUBECTL_VSPHERE_PASSWORD="${VC_PASS}"
  
  log "Authenticating to Supervisor Control Plane using VCF CLI..."
  echo "y" | vcf context delete "${CTX_NAME}" >/dev/null 2>&1 || true
  
  vcf context create "${CTX_NAME}" --endpoint "${SUP_IP}" --auth-type basic --username "${VC_USER}" --insecure-skip-tls-verify
  vcf context use "${CTX_NAME}"

  log "Waiting for Contour Envoy to receive an Avi Load Balancer IP..."
  for ((i=1; i<=30; i++)); do
    # Dynamically locate the namespace vCenter created (e.g., svc-contour-domain-c10)
    CONTOUR_NS=$(kubectl get ns -o name 2>/dev/null | grep 'svc-contour' | cut -d'/' -f2 | head -n1 || true)
    
    if [[ -n "$CONTOUR_NS" ]]; then
      # Query the service using the discovered namespace
      CONTOUR_IP=$(kubectl get svc envoy -n "${CONTOUR_NS}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
      
      if [[ -n "$CONTOUR_IP" ]]; then
        printf "\n"
        log "[+] Contour Ingress active at IP: ${CONTOUR_IP} (Namespace: ${CONTOUR_NS})"
        break
      fi
    fi
    
    printf "."
    sleep 10
    [[ $i -eq 30 ]] && { error "[-] Timeout waiting for Contour IP."; exit 1; }
  done

# --- 2. GENERATE CUSTOM TLS CERTIFICATE ---
  log "Generating Go-Compliant Self-Signed TLS Certificate for ${HARBOR_FQDN}..."
  mkdir -p "${ROOT_DIR}/certs"
  
  # THE FIX: Added the critical CA:TRUE constraint so containerd on ESXi trusts it
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "${ROOT_DIR}/certs/harbor.key" \
    -out "${ROOT_DIR}/certs/harbor.crt" \
    -subj "/C=US/ST=VA/L=DunnLoring/O=VCF/OU=Lab/CN=${HARBOR_FQDN}" \
    -addext "subjectAltName=DNS:${HARBOR_FQDN}" \
    -addext "basicConstraints=critical,CA:TRUE" 2>/dev/null

  CERT_INDENTED=$(awk '{printf "    %s\n", $0}' "${ROOT_DIR}/certs/harbor.crt")
  KEY_INDENTED=$(awk '{printf "    %s\n", $0}' "${ROOT_DIR}/certs/harbor.key")

  # --- 3. DYNAMICALLY BUILD HARBOR CONFIG ---
  log "Injecting TLS Certs into Harbor Data Values YAML..."
  HARBOR_YAML="${SERVICE_DIR}/harbor-dynamic-values.yaml"
  cat <<EOF > "${HARBOR_YAML}"
hostname: "${HARBOR_FQDN}"
port:
  https: 443
createNetworkPolicy: true
harborAdminPassword: VMware123!VMware123!
secretKey: 0123456789ABCDEF
database:
  password: VMware123!VMware123!
core:
  replicas: 1
  secret: VMware123!VMware123!
  xsrfKey: 0123456789ABCDEF0123456789ABCDEF
jobservice:
  replicas: 1
  secret: VMware123!VMware123!
registry:
  replicas: 1
  secret: VMware123!VMware123!
persistence:
  persistentVolumeClaim:
    registry:
      storageClass: "vsan-default-storage-policy"
      subPath: ""
      accessMode: ReadWriteOnce
      size: 10Gi
    jobservice:
      jobLog:
        existingClaim: ""
        storageClass: "vsan-default-storage-policy"
        subPath: ""
        accessMode: ReadWriteOnce
        size: 1Gi
    database:
      existingClaim: ""
      storageClass: "vsan-default-storage-policy"
      subPath: ""
      accessMode: ReadWriteOnce
      size: 1Gi
    redis:
      existingClaim: ""
      storageClass: "vsan-default-storage-policy"
      subPath: ""
      accessMode: ReadWriteOnce
      size: 1Gi
    trivy:
      existingClaim: ""
      storageClass: "vsan-default-storage-policy"
      subPath: ""
      accessMode: ReadWriteOnce
      size: 1Gi
metrics:
  enabled: true
  core:
    path: /metrics
    port: 8001
  registry:
    path: /metrics
    port: 8001
  exporter:
    path: /metrics
    port: 8001
network:
  ipFamilies: ["IPv4"]
tlsCertificate:
  tlsSecretLabels: {"managed-by": "vmware-vRegistry"}
  tls.crt: |
${CERT_INDENTED}
  tls.key: |
${KEY_INDENTED}
  ca.crt: |
${CERT_INDENTED}
EOF

  # --- 4. INSTALL HARBOR (WITH INTEGRATED AVI DNS INJECTION) ---
  log "Calling Python helper to inject Avi DNS, Register, AND Install Harbor..."
  python3 "${ROOT_DIR}/scripts/install_sup_service.py" \
    --host "${VC_HOST}" --user "${VC_USER}" --password "${VC_PASS}" \
    --service-name "harbor" \
    --definition-yaml "${HARBOR_DEF}" \
    --values-yaml "${HARBOR_YAML}" \
    --avi-ip "${AVI_IP}" --avi-pass "${AVI_PASS}" \
    --fqdn "${HARBOR_FQDN}" --target-ip "${CONTOUR_IP}" || exit 1
  
  log "Waiting for Harbor core services to initialize (This can take 3-5 minutes)..."
  for ((i=1; i<=40; i++)); do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -k "https://${HARBOR_FQDN}/api/v2.0/health" || true)
    if [[ "$HTTP_CODE" == "200" ]]; then
      printf "\n"
      log "[+] Supervisor Harbor Instance is UP and Healthy!"
      break
    else
      printf "."
      sleep 15
    fi
    [[ $i -eq 40 ]] && { error "[-] Timeout waiting for Harbor API."; exit 1; }
  done

 # --- 5. ESTABLISH DOCKER TLS TRUST ---
  log "Configuring Docker to trust the lab Harbor registry..."
  
  # Tell Docker to bypass strict x509 CA checks for our specific lab registry
  sudo mkdir -p /etc/docker
  sudo tee /etc/docker/daemon.json > /dev/null <<EOF
{
  "insecure-registries": ["${HARBOR_FQDN}"]
}
EOF

  log "Restarting Docker to apply registry bypass..."
  sudo systemctl restart docker
  sleep 5

  log "Granting active shell access to the Docker socket..."
  sudo chmod 666 /var/run/docker.sock

  # --- 6. STAGE THE IMAGE ---
  log "Pulling OpenLDAP from upstream..."
  docker pull osixia/openldap:1.5.0

  log "Tagging image for Supervisor Harbor..."
  TARGET_IMAGE="${HARBOR_FQDN}/library/osixia-openldap:1.5.0"
  docker tag osixia/openldap:1.5.0 "${TARGET_IMAGE}"

  log "Logging into Supervisor Harbor (${HARBOR_FQDN})..."
  docker login "${HARBOR_FQDN}" -u "admin" -p "VMware123!VMware123!"

  log "Pushing OpenLDAP image into the Supervisor..."
  docker push "${TARGET_IMAGE}"

  log "Updating OpenLDAP vSphere Pod YAML with new local image URL..."
  sed -i "s|image:.*|image: ${TARGET_IMAGE}|g" "${ROOT_DIR}/openldap-vsphere-pod.yaml"

  log "[+] Step 11 Complete! Setup is deeply integrated and self-contained."
  pause
}

step11_deploy_openldap(){
  log "[11] Creating Shared Namespace, Deploying OpenLDAP, and phpLDAPAdmin UI"  
  
  SUP_IP=$(read_tfvar sup_mgmt_ip_range | awk -F'-' '{print $1}')
  VC_HOST="$(read_tfvar vsphere_server)"
  VC_USER="$(read_tfvar vsphere_user)"
  VC_PASS="$(read_tfvar vsphere_password)"
  
  if [[ -f "${ROOT_DIR}/scripts/create_shared_namespace.py" ]]; then
    log "Executing standalone script to provision Supervisor Namespace..."
    python3 "${ROOT_DIR}/scripts/create_shared_namespace.py" \
      --host "${VC_HOST}" \
      --user "${VC_USER}" \
      --password "${VC_PASS}" \
      --namespace "shared-infrastructure" \
      --storage-policy "vSAN Default Storage Policy" || { error "Namespace script failed!"; exit 1; }
  else
    error "create_shared_namespace.py not found in ${ROOT_DIR}/scripts!"
    exit 1
  fi

  log "Authenticating to Supervisor Control Plane at ${SUP_IP} using VCF CLI..."
  
  CTX_NAME="lab-supervisor"
  export VCF_CLI_VSPHERE_PASSWORD="${VC_PASS}"
  export VSPHERE_PASSWORD="${VC_PASS}"
  export KUBECTL_VSPHERE_PASSWORD="${VC_PASS}"
  
  # SILENT DELETE FIX: Auto-confirming 'y' to prevent hanging
  echo "y" | vcf context delete "${CTX_NAME}" >/dev/null 2>&1 || true
  
  vcf context create "${CTX_NAME}" \
    --endpoint "${SUP_IP}" \
    --auth-type basic \
    --username "${VC_USER}" \
    --insecure-skip-tls-verify
  
  log "Setting default Kubernetes context..."
  vcf context use "${CTX_NAME}"
  
  log "Applying OpenLDAP Manifest to the Shared Infrastructure Namespace..."
  kubectl apply -f "${ROOT_DIR}/openldap-vsphere-pod.yaml"  
  log "Waiting for Avi to assign a Load Balancer VIP to the LDAP Service..."
  log "(This may take 1-2 minutes as Avi spins up the NSX-T Virtual Service)"
  
  for ((i=1; i<=20; i++)); do
    LDAP_VIP=$(kubectl get svc openldap-lb -n shared-infrastructure -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    
    if [[ -n "$LDAP_VIP" ]]; then
      printf "\n"
      log "[+] OpenLDAP successfully provisioned!"
      log "    LDAP Endpoint: ldap://${LDAP_VIP}:389"
      log "    Admin DN:      cn=admin,dc=vcf,dc=lab"
      log "    Password:      VMware123!"
      break
    else
      printf "."
      sleep 10
    fi
  done
  
  
  
  HARBOR_FQDN="harbor.lb.site-a.vcf.lab"
  PHPLDAPADMIN_SOURCE="osixia/phpldapadmin:0.9.0"
  PHPLDAPADMIN_TARGET="${HARBOR_FQDN}/library/osixia-phpldapadmin:0.9.0"
  PHPLDAPADMIN_YAML="${ROOT_DIR}/phpldapadmin.yaml"

  # --- 1. STAGE THE IMAGE ---
  log "Pulling phpLDAPadmin from upstream..."
  docker pull "${PHPLDAPADMIN_SOURCE}"

  log "Tagging image for Supervisor Harbor..."
  docker tag "${PHPLDAPADMIN_SOURCE}" "${PHPLDAPADMIN_TARGET}"

  docker login "${HARBOR_FQDN}" -u "admin" -p "VMware123!VMware123!"

  log "Pushing phpLDAPadmin image into the Supervisor..."
  docker push "${PHPLDAPADMIN_TARGET}"

  # --- 2. GENERATE KUBERNETES MANIFEST ---
  log "Generating phpLDAPadmin Kubernetes manifest..."
  cat <<EOF > "${PHPLDAPADMIN_YAML}"
apiVersion: apps/v1
kind: Deployment
metadata:
  name: phpldapadmin
  namespace: shared-infrastructure
spec:
  replicas: 1
  selector:
    matchLabels:
      app: phpldapadmin
  template:
    metadata:
      labels:
        app: phpldapadmin
    spec:
      containers:
      - name: phpldapadmin
        image: ${PHPLDAPADMIN_TARGET}
        ports:
        - containerPort: 443
        env:
        - name: PHPLDAPADMIN_LDAP_HOSTS
          value: "openldap-lb"
---
apiVersion: v1
kind: Service
metadata:
  name: phpldapadmin
  namespace: shared-infrastructure
spec:
  type: LoadBalancer
  ports:
  - port: 443
    targetPort: 443
    protocol: TCP
  selector:
    app: phpldapadmin
EOF

  # --- 3. DEPLOY TO VSPHERE PODS ---
  log "Applying phpLDAPadmin manifest to the Supervisor..."
  kubectl apply -f "${PHPLDAPADMIN_YAML}"

  log "[+] phpLDAPadmin deployment initiated!"
  log "Setup is complete. Run the following command to get your UI IP address:"
  log "kubectl get svc -n shared-infrastructure -w"
  
  pause
}

step12_prime_vcfa_objects(){
  log "[12] Priming VCFA Region, Tenant Org, and LDAP Integration…"
  
  # --- 1. AUTHENTICATE TO SUPERVISOR ---
  SUP_IP=$(read_tfvar sup_mgmt_ip_range | awk -F'-' '{print $1}')
  VC_USER="$(read_tfvar vsphere_user)"
  VC_PASS="$(read_tfvar vsphere_password)"

  CTX_NAME="lab-supervisor"
  export VCF_CLI_VSPHERE_PASSWORD="${VC_PASS}"
  export VSPHERE_PASSWORD="${VC_PASS}"
  export KUBECTL_VSPHERE_PASSWORD="${VC_PASS}"

  log "Authenticating to Supervisor Control Plane at ${SUP_IP} using VCF CLI..."
  
  # SILENT DELETE FIX: Auto-confirming 'y' to prevent hanging on stale contexts
  echo "y" | vcf context delete "${CTX_NAME}" >/dev/null 2>&1 || true

  vcf context create "${CTX_NAME}" \
    --endpoint "${SUP_IP}" \
    --auth-type basic \
    --username "${VC_USER}" \
    --insecure-skip-tls-verify
    
  vcf context use "${CTX_NAME}" >/dev/null 2>&1

  # --- 2. EXTRACT LDAP VIP ---
  log "Retrieving OpenLDAP LoadBalancer IP from Avi..."
  
  LDAP_VIP=""
  for ((i=1; i<=30; i++)); do
    # Extract the IP directly using jsonpath
    LDAP_VIP=$(kubectl get svc openldap-lb -n shared-infrastructure -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    
    if [[ -n "$LDAP_VIP" ]]; then
      printf "\n"
      log "[+] Found OpenLDAP VIP: ${LDAP_VIP}"
      break
    fi
    printf "."
    sleep 10
    [[ $i -eq 30 ]] && { error "[-] Timeout waiting for OpenLDAP VIP."; exit 1; }
  done
  
  # --- 3. EXECUTE PYTHON AUTOMATION ---
  if [[ -f "${ROOT_DIR}/scripts/prime_vcfa.py" ]]; then
    log "Executing Python VCFA Prime script with LDAP VIP: ${LDAP_VIP}..."
    python3 "${ROOT_DIR}/scripts/prime_vcfa.py" "${LDAP_VIP}" || { error "Prime VCFA script failed!"; exit 1; }
  else
    error "prime_vcfa.py not found in ${ROOT_DIR}/scripts!"
    exit 1
  fi
  
  pause
}

do_step() {
  case "$1" in
    1) step1_install_tools_verify_vcfa;;
    2) step2_teardown_environment;;
    3) step3_tf_init;;
    4) step4_create_nsx_objects;;
    5) step5_deploy_avi;;
    6) step6_init_avi;;
    7) step7_avi_base_config;;
    8) step8_nsx_cloud;;
    9) step9_install_sup;;
   10) step10_install_supervisor_services;;
   11) step11_deploy_openldap;;
   12) step12_prime_vcfa_objects;;
    *) echo "Unknown step $1"; exit 2;;
  esac
}

run() {
  local spec="${1:-all}"
  if [[ "$spec" == "all" ]]; then
    for n in {1..12}; do do_step "$n"; done
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
