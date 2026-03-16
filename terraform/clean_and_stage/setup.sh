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

  # FIXED: Adding the DNS record generation back!
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
}

step7_avi_base_config(){
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

step10_provision_vcfa_objects(){
  log "[10] Provisioning VCFA Objects…"
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
    7) step7_avi_base_config;;
    8) step8_nsx_cloud;;
    9) step9_install_sup;;
   10) step10_provision_vcfa_objects;;
    *) echo "Unknown step $1"; exit 2;;
  esac
}

run() {
  local spec="${1:-all}"
  if [[ "$spec" == "all" ]]; then
    for n in {1..10}; do do_step "$n"; done
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
