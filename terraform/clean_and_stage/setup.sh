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

step1_install_tools() {
  echo "[1] Install tools…"
  #-----------------------------
  # 1) Setup tools in lab & apply fixes
  #-----------------------------
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


step2_dns_fix() {
  echo "[2] DNS fix…"
  if [[ -x "${ROOT_DIR}/scripts/dns_fix.sh" ]]; then
    log "Applying DNS fix…"
    chmod +x "${ROOT_DIR}/scripts/dns_fix.sh"
    "${ROOT_DIR}/scripts/dns_fix.sh" || warn "dns_fix.sh reported a warning."
  else
    warn "dns_fix.sh not found; skipping DNS fix."
  fi
  pause
}

step3_tf_init() {
  echo "[3] terraform init/validate…"
  
  # Ensure a tfvars exists (safe defaults; edit as needed)
  if [[ ! -f "${TFVARS_FILE}" ]]; then
    log "Creating ${TFVARS_FILE} with lab defaults…"
    cat > "${TFVARS_FILE}" <<'EOF'
  # ---- NSX ----
  nsx_host                 = "nsx-wld01-a.site-a.vcf.lab"
  nsx_username             = "admin"
  nsx_password             = "VMware123!VMware123!"
  nsx_allow_unverified_ssl = true
  
  # ---- vSphere ----
  vsphere_server   = "vc-wld01-a.site-a.vcf.lab"
  vsphere_user     = "administrator@wld.sso"
  vsphere_password = "VMware123!VMware123!"
  vsphere_datacenter = "wld-01a-DC"
  vsphere_cluster    = "cluster-wld01-01a"
  vsphere_datastore  = "cluster-wld01-01a-vsan01"
  
  # ---- VCFA provider ----
  vcfa_endpoint    = "https://auto-a.site-a.vcf.lab"
  vcfa_token       = "<PUT_YOUR_VCFA_TOKEN_HERE>"
  
  # ---- VCFA cleanup inputs (Step 2) ----
  enable_vcfa_cleanup = true
  vcfa_org_name            = "showcase-all-apps"
  vcfa_region_name         = "us-west-region"
  org_project_name         = "default-project"
  ns_name                  = "demo-namespace-vkrcg"
  org_cl_name              = "showcase-content-library"
  provider_cl_name         = "provider-content-library"
  org_reg_net_name         = "showcase-all-appsus-west-region"
  provider_gw_name         = "provider-gateway-us-west"
  provider_ip_space        = "ip-space-us-west"
  vcenter_fqdn_to_refresh  = "vc-wld01-a.site-a.vcf.lab"
  
  # ---- AVI OVA deploy (Step 5) ----
  avi_ova_path           = "/path/to/Controller.ova"
  avi_vm_name            = "avi-controller01-a"
  avi_mgmt_pg            = "<MGMT_PORTGROUP_NAME>"   # e.g., 'pg-mgmt' or 'VM Network'
  avi_mgmt_ip            = "10.1.1.200"
  avi_mgmt_netmask       = "255.255.255.0"
  avi_mgmt_gateway       = "10.1.1.1"
  avi_dns_servers        = ["10.1.1.1"]
  avi_ntp_servers        = ["10.1.1.1"]
  avi_domain_search      = "site-a.vcf.lab"
  avi_admin_password     = "VMware123!VMware123!"
  
  # ---- Supervisor enable (Step 6)
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
  tgw_ipblock_cidr             = "172.16.100.0/24"
  tgw_ipblock_range            = "172.16.100.0-172.16.100.255"
  workload_vpc_cidrs           = ["172.16.200.0/24"]
  service_cidr                 = "10.96.0.0/23"
EOF
fi
  
  # Terraform init (repo root)
  log "Running terraform init…"
  terraform -chdir="${ROOT_DIR}" init -upgrade
  terraform -chdir="${ROOT_DIR}" validate
  pause
}

step4_remove_vcfa_objects(){
  log "Priming VCFA lookup data (org/region)…"
  terraform -chdir="${ROOT_DIR}"  apply -input=false \
    -target=null_resource.auth_dir \
    -target=vcfa_api_token.tenant \
    -target=vcfa_api_token.system \
    -auto-approve

  # Refresh the two lookups we actually read IDs from
  terraform -chdir="${ROOT_DIR}" apply -input=false \
    -target="data.vcfa_org.showcase" \
    -target="data.vcfa_region.region" \
    -refresh-only -auto-approve

  # Resolve the token file path written by vcfa_api_token.tenant (robustly)
  TOKEN_DIR="${ROOT_DIR}/.auth"
  TENANT_CANDS=( "${TOKEN_DIR}/vcfa_tenant_token.json" "${TOKEN_DIR}/tenant_token.json" )
  SYSTEM_CANDS=( "${TOKEN_DIR}/vcfa_system_token.json" "${TOKEN_DIR}/system_token.json" )

  TOKEN_FILE=""
  for f in "${TENANT_CANDS[@]}"; do [[ -s "$f" ]] && TOKEN_FILE="$f" && break; done
  if [[ -z "$TOKEN_FILE" ]]; then
    for f in "${SYSTEM_CANDS[@]}"; do [[ -s "$f" ]] && TOKEN_FILE="$f" && break; done
  fi

  # Last-resort: take vcfa_token from terraform.tfvars if present
  if [[ -z "${TOKEN_FILE}" || ! -s "${TOKEN_FILE}" ]]; then
    read_tfvar() { awk -F= -v key="$1" '$1 ~ "^[[:space:]]*"key"[[:space:]]*$" {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); gsub(/^"|"$|;$/,"",$2); print $2}' "${TFVARS_FILE}" | tail -n1; }
    VCFA_TOKEN_FROM_VARS="$(read_tfvar vcfa_token || true)"
    if [[ -n "${VCFA_TOKEN_FROM_VARS}" && "${VCFA_TOKEN_FROM_VARS}" != "<PUT_YOUR_VCFA_TOKEN_HERE>" ]]; then
      TOKEN_FILE="${ROOT_DIR}/.tenant.token"
      printf '%s' "${VCFA_TOKEN_FROM_VARS}" > "${TOKEN_FILE}"
      log "Using vcfa_token from ${TFVARS_FILE}."
    fi
  fi

  [[ -z "${TOKEN_FILE:-}" || ! -s "${TOKEN_FILE}" ]] && { error "Could not resolve a VCFA token file in ${TOKEN_DIR} and no tfvars fallback was provided."; exit 1; }

  # Read token from JSON or raw text
  _bearer() {
    local raw; raw="$(cat "${TOKEN_FILE}")"
    # If it's JSON, extract common fields; else echo raw
    jq -r '.token // .access_token // .accessToken // empty' 2>/dev/null <<<"$raw" | awk 'NF{print; exit}' \
      || printf '%s' "$raw"
  }

  VCFA_API="${VCFA_API:-https://auto-a.site-a.vcf.lab}"
  ORG_NAME="${ORG_NAME:-showcase-all-apps}"
  PROJECT_NAME="${PROJECT_NAME:-default-project}"
  REGION_NAME="${REGION_NAME:-us-west-region}"
  VPC_NAME="${VPC_NAME:-us-west-region-Default-VPC}"
  ORG_CL_NAME="${ORG_CL_NAME:-showcase-content-library}"
  PROVIDER_CL_NAME="${PROVIDER_CL_NAME:-provider-content-library}"
  NS_NAME="${NS_NAME:-demo-namespace-vkrcg}"
  CLOUDAPI_VERSION="${CLOUDAPI_VERSION:-40.0}"
  CLOUDAPI_ACCEPT="Accept: application/json;version=${CLOUDAPI_VERSION}"
  NS_URN="urn:vcloud:namespace:6d272bc5-a6aa-4531-bfe4-7c0e034f238a"

  log()   { printf -- "\n==> %s\n" "$*"; }
  warn()  { printf -- "\n!! %s\n" "$*" >&2; }
  error() { printf -- "\n!! %s\n" "$*" >&2; }

  # Always -k in lab (self-signed); return code only (no -f) so we can inspect status
  _http_get() { # prints: body \n code
  curl -ksS \
    -H "$CLOUDAPI_ACCEPT" \
    -H "Authorization: Bearer $(_bearer)" \
    -w '\n%{http_code}' "${VCFA_API}$1" || echo -e "\n000"
  }

  
  # Existence using URN endpoint
  # Returns: 0 present, 1 gone, 2 unauthorized, 3 unknown/transient
  ns_exists() {
    local body code
    { read -r body; read -r code; } < <(_http_get "/cloudapi/vcf/namespaces/${NS_URN}")
    case "$code" in
      200) return 0 ;;
      404|410) return 1 ;;
      401|403) return 2 ;;
    esac
    # Some builds return JSON error with RESOURCE_NOT_FOUND
    if jq -e '(.errorCode // .code // "") | test("RESOURCE_NOT_FOUND")' >/dev/null 2>&1 <<<"$body"; then
      return 1
    fi
    return 3
  }

  wait_ns_deleted() {
    log "Waiting for Supervisor Namespace ${NS_NAME} (URN: ${NS_URN}) to be deleted…"
    local t0 timeout_sec=5400 unauth_cnt=0 unknown_cnt=0
    t0=$(date +%s)
    while true; do
      ns_exists; rc=$?
      case "$rc" in
        0) : ;;  # present -> keep waiting
        1) log "Supervisor Namespace ${NS_NAME} confirmed deleted."; return 0 ;;
        2) ((unauth_cnt++))
           if (( unauth_cnt >= 6 )); then
             warn "Auth failing repeatedly (401/403). Proceeding as deleted due to inability to verify."
             return 0
           fi ;;
        3) ((unknown_cnt++))
           if (( unknown_cnt >= 12 )); then
             warn "Verification inconclusive after multiple attempts. Proceeding as deleted."
             return 0
           fi ;;
      esac
      if (( $(date +%s) - t0 > timeout_sec )); then
        warn "Timed out waiting for namespace deletion (soft-timeout). Proceeding."
        return 0
      fi
      sleep 10
    done
    }
  
  
  # --- Purge all items from a vCenter Content Library by NAME (govc only) ---
  purge_cl_items() {
  local CL_NAME="$1"

  # Lab creds (hardcoded OK)
  export GOVC_URL="https://vc-wld01-a.site-a.vcf.lab"
  export GOVC_USERNAME="administrator@wld.sso"
  export GOVC_PASSWORD="VMware123!VMware123!"
  export GOVC_INSECURE=1

  if ! command -v govc >/dev/null 2>&1; then
    warn "govc not found; cannot purge '${CL_NAME}'."
    return 1
  fi
  if ! govc about >/dev/null 2>&1; then
    warn "govc login failed; check GOVC_* values."
    return 1
  fi
  if ! govc library.info "/${CL_NAME}" >/dev/null 2>&1; then
    log "Content Library '/${CL_NAME}' not found (already removed?)."
    return 0
  fi

  # Collect item paths under /<library>/<item>
  local list
  list="$(govc library.ls "/${CL_NAME}" 2>/dev/null || true)"

  # Keep only entries that are child items, not the library root
  mapfile -t items < <(awk -v root="/${CL_NAME}/" 'index($0, root)==1' <<<"$list")

  # Fallback: try JSON and extract .Path fields if ls output is odd
  if [[ ${#items[@]} -eq 0 ]]; then
    local j
    j="$(govc library.info -json "/${CL_NAME}" 2>/dev/null || true)"
    mapfile -t items < <(jq -r '.. | objects | select(has("Path")) | .Path' 2>/dev/null <<<"$j" \
                         | awk -v root="/${CL_NAME}/" 'index($0, root)==1' || true)
  fi

  if [[ ${#items[@]} -eq 0 ]]; then
    log "Content Library '${CL_NAME}' already empty."
    return 0
  fi

  log "Removing ${#items[@]} item(s) from Content Library '${CL_NAME}'…"
  local ok=0 fail=0
  for it in "${items[@]}"; do
    echo " - deleting: ${it}"
    # No -r flag for library.rm; delete each item path
    if timeout 90s govc library.rm "${it}"; then
      ((ok++))
    else
      ((fail++))
      warn "   failed to delete: ${it}"
    fi
  done

  log "Purge complete for '${CL_NAME}': removed=${ok}, failed=${fail}"
  return 0
  }


  log "Importing VCFA resources for cleanup…"
  terraform -chdir="${ROOT_DIR}" import -var="enable_vcfa_cleanup=false" 'vcfa_supervisor_namespace.project_ns[0]'            'default-project.demo-namespace-vkrcg' || true
  terraform -chdir="${ROOT_DIR}" import -var="enable_vcfa_cleanup=false" 'vcfa_content_library.org_cl[0]'                    'showcase-all-apps.showcase-content-library' || true
  terraform -chdir="${ROOT_DIR}" import -var="enable_vcfa_cleanup=false" 'vcfa_content_library.provider_cl[0]'               'System.provider-content-library' || true
  terraform -chdir="${ROOT_DIR}" import -var="enable_vcfa_cleanup=false" 'vcfa_org_region_quota.showcase_us_west[0]'         'showcase-all-apps.us-west-region' || true
  terraform -chdir="${ROOT_DIR}" import -var="enable_vcfa_cleanup=false" 'vcfa_org_regional_networking.showcase_us_west[0]'  'showcase-all-apps.showcase-all-appsus-west-region' || true
  terraform -chdir="${ROOT_DIR}" import -var="enable_vcfa_cleanup=false" 'vcfa_provider_gateway.us_west[0]'                  'us-west-region.provider-gateway-us-west' || true
  terraform -chdir="${ROOT_DIR}" import -var="enable_vcfa_cleanup=false" 'vcfa_ip_space.us_west[0]'                          'us-west-region.ip-space-us-west' || true
  terraform -chdir="${ROOT_DIR}" import -var="enable_vcfa_cleanup=false" 'vcfa_region.us_west[0]'                            'us-west-region' || true

  terraform -chdir="${ROOT_DIR}" -input=false state list | egrep '^vcfa_(supervisor_namespace|content_library|org_region_quota|org_regional_networking|provider_gateway|ip_space|region)\.' || true

  # --- STRICT SERIAL TEARDOWN, NO BLANKET DESTROY PASS ---

  # 1) Start NS deletion (non-fatal), then ALWAYS wait
  if ! terraform -chdir="${ROOT_DIR}"  apply -input=false \
        -auto-approve -parallelism=1 \
        -var="enable_vcfa_cleanup=true" \
        -target='vcfa_supervisor_namespace.project_ns[0]'; then
    warn "NS delete apply returned non-zero (provider timeout is common). Proceeding to wait…"
  fi

  # wait (this is the part that wasn’t actually running before)
  if ! wait_ns_deleted; then
    warn "Continuing even though the wait hit its soft timeout."
  fi
  
  log "Purging items from content libraries before deletion…"
  purge_cl_items "${ORG_CL_NAME}" 
  purge_cl_items "${PROVIDER_CL_NAME}"

  # 2) Content libraries (ensure they’re empty first if needed)
  terraform -chdir="${ROOT_DIR}" apply -input=false -auto-approve -parallelism=1 \
    -var="enable_vcfa_cleanup=true" \
    -target='vcfa_content_library.org_cl[0]' || true

  terraform -chdir="${ROOT_DIR}" apply -input=false -auto-approve -parallelism=1 \
    -var="enable_vcfa_cleanup=true" \
    -target='vcfa_content_library.provider_cl[0]' || true
    
  # 3) Now the quota and org regional networking (they require the NS to be gone)
  terraform -chdir="${ROOT_DIR}" apply -input=false -auto-approve -parallelism=1 \
    -var="enable_vcfa_cleanup=true" \
    -target='vcfa_org_region_quota.showcase_us_west[0]' || true

  terraform -chdir="${ROOT_DIR}" apply -input=false -auto-approve -parallelism=1 \
    -var="enable_vcfa_cleanup=true" \
    -target='vcfa_org_regional_networking.showcase_us_west[0]' || true

  # 4) Provider infra
  terraform -chdir="${ROOT_DIR}" apply -input=false -auto-approve -parallelism=1 \
    -var="enable_vcfa_cleanup=true" \
    -target='vcfa_provider_gateway.us_west[0]' || true

  terraform -chdir="${ROOT_DIR}" apply -input=false  -auto-approve -parallelism=1 \
    -var="enable_vcfa_cleanup=true" \
    -target='vcfa_ip_space.us_west[0]' || true

  # 5) Region last
  terraform -chdir="${ROOT_DIR}" apply -input=false -auto-approve -parallelism=1 \
    -var="enable_vcfa_cleanup=true" \
    -target='vcfa_region.us_west[0]' || true

  pause
}


step5_remove_sup(){
  #-----------------------------
  # Remove Supervisor installed in vSphere (native REST)
  #-----------------------------
  log "STEP 3: Removing Supervisor from vSphere…"
  bash "${ROOT_DIR}/scripts/remove_supervisor.sh" || warn "Supervisor removal script finished with warnings."
  pause
}

step6_create_nsx_objects(){
  #-----------------------------
  # Create NSX Tier-1 + Segment & vSphere Content Library
  #-----------------------------
  log "Applying NSX/vSphere creation stack (Tier-1 + Segment + Content Library)…"
  terraform -chdir="${ROOT_DIR}" apply -auto-approve \
    -target='nsxt_policy_tier1_gateway.se_mgmt' \
    -target='nsxt_policy_segment.se_mgmt' \
    -target='vsphere_content_library.avi_se_cl'
  pause
}

step7_deploy_avi(){
  #-----------------------------
  # Install AVI + NSX integration
  #-----------------------------
 
  AVI_OVA_FILENAME="${AVI_OVA_FILENAME:-$(ls -1 "${ROOT_DIR}"/*.ova 2>/dev/null | head -n1 | xargs -n1 basename)}"
  AVI_OVA_PATH="${ROOT_DIR}/${AVI_OVA_FILENAME}"
  
  if [[ ! -f "${AVI_OVA_PATH}" ]]; then
    error "Could not find an .ova in ${ROOT_DIR}. Place the AVI OVA next to setup.sh or set AVI_OVA_FILENAME."
    exit 1
  fi
  
  # Get the realized display name of the SE mgmt segment from state
  AVI_MGMT_PG="$(
    terraform -chdir="${ROOT_DIR}" state show -no-color nsxt_policy_segment.se_mgmt \
      | awk -F' = ' '/^\s*display_name\s*=/{print $2}' \
      | sed -e 's/^"//' -e 's/"$//' \
      | tail -n1
  )"
  
  if [[ -z "${AVI_MGMT_PG}" ]]; then
    error "Could not resolve nsxt_policy_segment.se_mgmt.display_name from state."
    exit 1
  fi
  
  # Feed Terraform via an auto tfvars (picked up automatically)
  cat > "${ROOT_DIR}/avi.auto.tfvars.json" <<EOF
  {
    "avi_ova_path": "${AVI_OVA_PATH}",
    "avi_mgmt_pg": "${AVI_MGMT_PG}"
  }
EOF
  
  log "Prepared AVI vars: ova=${AVI_OVA_PATH}, mgmt_pg=${AVI_MGMT_PG}"
  
  log "Adding DNS record for Avi controller…"
  bash "${ROOT_DIR}/scripts/add_dns_record.sh"
  
  log "Deploying Avi Controller OVA via Terraform…"
  terraform -chdir="${ROOT_DIR}" apply -auto-approve -target='vsphere_virtual_machine.avi_controller'
  pause
}

step8_create_cert(){
  # Wait for the Avi Controller API to come up
  AVI_FQDN="avi-controller01-a.site-a.vcf.lab"
  log "Waiting for Avi API at https://${AVI_FQDN}…"
  until curl -sk --max-time 5 "https://${AVI_FQDN}/api/initial-data" >/dev/null; do
    sleep 10
  done
  log "Avi API is up."

  # Apply just the cert/trust pieces and write PEMs to disk
  terraform -chdir="${ROOT_DIR}" apply -auto-approve \
    -target=tls_private_key.avi \
    -target=tls_self_signed_cert.avi \
    -target=avi_sslkeyandcertificate.portal \
    -target=avi_systemconfiguration.this \
    -target=local_file.avi_cert_pem \
    -target=local_file.avi_key_pem

  # Extract NSX creds from terraform.tfvars (same helper you already use)
  read_tfvar() { awk -F= -v key="$1" '$1 ~ "^[[:space:]]*"key"[[:space:]]*$" {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); gsub(/^"|"$|;$/,"",$2); print $2}' "${TFVARS_FILE}" | tail -n1; }

  NSX_HOST="$(read_tfvar nsx_host)"
  NSX_USER="$(read_tfvar nsx_username)"
  NSX_PASS="$(read_tfvar nsx_password)"
  CERT_PATH="${ROOT_DIR}/out/avi-portal.crt"
  CERT_NAME="$(read_tfvar avi_cert_name || echo avi-portal-cert)"

  if [[ -z "${NSX_HOST}" || -z "${NSX_USER}" || -z "${NSX_PASS}" ]]; then
    warn "NSX variables missing from ${TFVARS_FILE}; skipping NSX trust upload."
  else
    log "Uploading Avi portal cert to NSX trust store…"
    bash "${ROOT_DIR}/scripts/upload_nsx_cert.sh" "$NSX_HOST" "$NSX_USER" "$NSX_PASS" "$CERT_PATH" "$CERT_NAME"
  fi

  pause
}



step9_nsx_cloud(){
  log "PASS A — NSXCloud + vCenter (no IPAM/DNS yet)"
  terraform -chdir="${ROOT_DIR}" apply -auto-approve \
    -var="attach_ipam_now=false" \
    -target=avi_cloud.nsx_t_cloud \
    -target=avi_vcenterserver.vc_01
  
  log "PASS B1 — Discover networks and create IPAM/DNS profile"
  terraform -chdir="${ROOT_DIR}" apply -auto-approve \
    -target=data.avi_network.vip \
    -target=avi_ipamdnsproviderprofile.internal

  log "PASS B2 — Attach IPAM/DNS to Cloud and create SE Group"
  terraform -chdir="${ROOT_DIR}" apply -auto-approve \
    -var="attach_ipam_now=true" \
    -target=avi_cloud.nsx_t_cloud \
    -target=avi_serviceenginegroup.default
  pause
}  

step10_onboard_nsx_alb(){
  log "Onboarding Avi to NSX (ALB onboarding)…"
  bash "${ROOT_DIR}/scripts/nsx_onboard_alb.sh"
  pause
}

step11_install_sup(){
  #-----------------------------
  # Install Supervisor in vSphere (native REST)
  #-----------------------------
  log "STEP 6: Installing Supervisor in vSphere…"
  bash "${ROOT_DIR}/scripts/install_supervisor.sh" || warn "Supervisor install script finished with warnings."
  pause
}

do_step() {
  case "$1" in
    1) step1_install_tools;;
    2) step2_dns_fix;;
    3) step3_tf_init;;
    4) step4_remove_vcfa_objects;;
    5) step5_remove_sup;;
    6) step6_create_nsx_objects;;
    7) step7_deploy_avi;;
    8) step8_create_cert;;
    9) step9_nsx_cloud;;
   10) step10_onboard_nsx_alb;;
   11) step11_install_sup;;
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
      echo "Bad step spec: '$p'"; echo "Usage: $0 [all|N|N-M|N:M|N1,N2,...]"; exit 2
    fi
  done
}
# Only execute when run directly (not when sourced)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  run "${1:-all}"
fi

