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
  
  # Pass 1: Build the Cloud shell, vCenter, IPAM, and DNS. 
  terraform -chdir="${ROOT_DIR}" apply -auto-approve \
    -target=avi_cloud.nsx_cloud \
    -target=avi_vcenterserver.wld01_vc
  
  # Pass 2: Build the Service Engine Group
  terraform -chdir="${ROOT_DIR}" apply -auto-approve \
    -target=avi_serviceenginegroup.avi_lab_se_group

  # Extract SE Group UUID
  SE_UUID=$(terraform -chdir="${ROOT_DIR}" state show avi_serviceenginegroup.avi_lab_se_group | grep '^ *uuid' | awk '{print $3}' | tr -d '"')
  [[ -z "$SE_UUID" ]] && { error "[-] Failed to extract SE Group UUID!"; exit 1; }

  log "Stitching SE Group UUID ($SE_UUID) back into the NSX Cloud..."
  # Pass 3: Apply the Cloud with SE Group attached
  terraform -chdir="${ROOT_DIR}" apply -auto-approve \
    -var="se_group_uuid=${SE_UUID}" \
    -target=avi_cloud.nsx_cloud

  log "Waiting 15 seconds for Avi to sync NSX-T VRF Contexts..."
  sleep 15

  log "Deploying Delegated DNS Virtual Service..."
  # Pass 4: Deploy VS VIP and Virtual Service (We keep passing SE_UUID so it doesn't revert)
  terraform -chdir="${ROOT_DIR}" apply -auto-approve \
    -var="se_group_uuid=${SE_UUID}" \
    -target=data.avi_vrfcontext.t1_se_services \
    -target=avi_vsvip.dns_vip \
    -target=avi_virtualservice.delegated_dns

  # Extract DNS VS UUID
  DNS_VS_UUID=$(terraform -chdir="${ROOT_DIR}" state show avi_virtualservice.delegated_dns | grep '^ *uuid' | awk '{print $3}' | tr -d '"')
  [[ -z "$DNS_VS_UUID" ]] && { error "[-] Failed to extract DNS VS UUID!"; exit 1; }

  log "Attaching Delegated DNS to System Configuration..."
  # Pass 5: Update System Config with the new DNS VS
  terraform -chdir="${ROOT_DIR}" apply -auto-approve \
    -var="se_group_uuid=${SE_UUID}" \
    -var="dns_vs_uuid=${DNS_VS_UUID}" \
    -target=avi_systemconfiguration.this

  # Wait for SE Image Upload to Content Library 
  CL_NAME=$(terraform -chdir="${ROOT_DIR}" state show vsphere_content_library.avi_se_cl | grep '^ *name ' | awk -F'=' '{print $2}' | tr -d ' "')
  
  export GOVC_URL="$(read_tfvar vsphere_server)"
  export GOVC_USERNAME="$(read_tfvar vsphere_user)"
  export GOVC_PASSWORD="$(read_tfvar vsphere_password)"
  export GOVC_INSECURE=1

  log "Waiting for Avi to generate and upload the Service Engine OVA to the vCenter Content Library ('$CL_NAME')..."
  log "(This typically takes 5-10 minutes depending on storage performance)"

  # 40 attempts * 23 seconds ~ 15 minutes max wait
  for ((i=1; i<=40; i++)); do
    # 'grep -c .' counts non-empty lines. '|| true' prevents the script from crashing if it's 0.
    ITEM_COUNT=$(govc library.item.ls "$CL_NAME" 2>/dev/null | grep -c . || true)
    
    if [[ "$ITEM_COUNT" -gt 0 ]]; then
      printf "\n"
      log "[+] Service Engine OVA successfully uploaded to Content Library!"
      break
    else
      printf "."
      sleep 23
    fi

    if [[ $i -eq 40 ]]; then
      printf "\n"
      error "[-] Timeout waiting for Avi to upload the SE image. Check vCenter Tasks or Avi UI."
      exit 1
    fi
  done
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

step10_prime_vcfa_objects(){
  log "[10] Priming VCFA Region and Tenant Org…"
  if [[ -f "${ROOT_DIR}/scripts/prime_vcfa.py" ]]; then
    log "Executing Python VCFA Prime script..."
    python3 "${ROOT_DIR}/scripts/prime_vcfa.py" || { error "Prime VCFA script failed!"; exit 1; }
  else
    error "prime_vcfa.py not found in ${ROOT_DIR}/scripts!"
    exit 1
  fi
  pause
}


step11_install_supervisor_services(){
  log "[11] Installing Contour & Harbor (Consolidated API Deployment)…"

  SUP_IP=$(read_tfvar sup_mgmt_ip_range | awk -F'-' '{print $1}')
  VC_HOST="$(read_tfvar vsphere_server)"
  VC_USER="$(read_tfvar vsphere_user)"
  VC_PASS="$(read_tfvar vsphere_password)"
  
  AVI_IP="$(read_tfvar avi_mgmt_ip)"
  AVI_PASS="$(read_tfvar avi_admin_password)"
  
  HARBOR_FQDN="harbor.lb.site-a.vcf.lab"
  SERVICE_DIR="$(cd "${ROOT_DIR}/../../Supervisor_Services" && pwd)"
  
  CONTOUR_DEF="${SERVICE_DIR}/contour-service-v1.32.0.yaml"
  
  # Dynamically find the base Harbor Definition YAML (excluding your dynamic values file)
  HARBOR_DEF=$(ls -1 "${SERVICE_DIR}"/harbor-*.yaml 2>/dev/null | grep -v "dynamic-values" | head -n1 || true)
  
  [[ ! -f "${ROOT_DIR}/scripts/install_sup_service.py" ]] && { error "install_sup_service.py missing!"; exit 1; }
  [[ ! -f "${CONTOUR_DEF}" ]] && { error "Contour definition not found at ${CONTOUR_DEF}!"; exit 1; }
  [[ -z "${HARBOR_DEF}" ]] && { error "Harbor definition YAML not found in ${SERVICE_DIR}!"; exit 1; }

  # --- 1. INSTALL CONTOUR & GET IP ---
  log "Calling vCenter API to Register & Install Contour Supervisor Service..."
  # Notice we pass --definition-yaml here!
  python3 "${ROOT_DIR}/scripts/install_sup_service.py" \
    --host "${VC_HOST}" --user "${VC_USER}" --password "${VC_PASS}" \
    --service-name "contour" --definition-yaml "${CONTOUR_DEF}" || exit 1

  CTX_NAME="lab-supervisor"
  export VCF_CLI_VSPHERE_PASSWORD="${VC_PASS}"
  export VSPHERE_PASSWORD="${VC_PASS}"
  export KUBECTL_VSPHERE_PASSWORD="${VC_PASS}"
  
  log "Authenticating to Supervisor Control Plane using VCF CLI..."
  # SILENT DELETE FIX: Auto-confirming 'y' to prevent hanging
  echo "y" | vcf context delete "${CTX_NAME}" >/dev/null 2>&1 || true
  
  vcf context create "${CTX_NAME}" --endpoint "${SUP_IP}" --auth-type basic --username "${VC_USER}" --insecure-skip-tls-verify
  vcf context use "${CTX_NAME}"

  log "Waiting for Contour Envoy to receive an Avi Load Balancer IP..."
  for ((i=1; i<=30; i++)); do
    CONTOUR_IP=$(kubectl get svc -n svc-contour envoy -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    if [[ -n "$CONTOUR_IP" ]]; then
      printf "\n"
      log "[+] Contour Ingress active at IP: ${CONTOUR_IP}"
      break
    else
      printf "."
      sleep 10
    fi
    [[ $i -eq 30 ]] && { error "[-] Timeout waiting for Contour IP."; exit 1; }
  done

  # --- 2. GENERATE CUSTOM TLS CERTIFICATE ---
  log "Generating Self-Signed TLS Certificate for ${HARBOR_FQDN}..."
  mkdir -p "${ROOT_DIR}/certs"
  openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "${ROOT_DIR}/certs/harbor.key" \
    -out "${ROOT_DIR}/certs/harbor.crt" \
    -subj "/C=US/ST=VA/L=DunnLoring/O=VCF/OU=Lab/CN=${HARBOR_FQDN}" \
    -addext "subjectAltName=DNS:${HARBOR_FQDN}" 2>/dev/null

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
  persistenceVolumeClaim:
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
tls:
  certificate: |
${CERT_INDENTED}
  key: |
${KEY_INDENTED}
EOF

  # --- 4. INSTALL HARBOR (WITH INTEGRATED AVI DNS INJECTION) ---
  log "Calling Python helper to inject Avi DNS, Register, AND Install Harbor..."
  # Passing both the Definition YAML (App) and the Values YAML (Settings)
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
  log "Injecting Custom Certificate into local Docker Trust Store..."
  sudo mkdir -p "/etc/docker/certs.d/${HARBOR_FQDN}"
  sudo cp "${ROOT_DIR}/certs/harbor.crt" "/etc/docker/certs.d/${HARBOR_FQDN}/ca.crt"

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

step12_deploy_openldap(){
  log "[12] Creating Shared Namespace & Deploying OpenLDAP…"

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

  log "[+] Step 12 Complete! Global Identity Provider is online."
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
    7) step7_avi_base_config;;
    8) step8_nsx_cloud;;
    9) step9_install_sup;;
   10) step10_prime_vcfa_objects;;
   11) step11_install_supervisor_services;;
   12) step12_deploy_openldap;;
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
