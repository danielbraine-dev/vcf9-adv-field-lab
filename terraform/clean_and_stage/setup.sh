#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TFVARS_FILE="${ROOT_DIR}/terraform.tfvars"

log()   { printf "\n\033[1;36m%s\033[0m\n" "$*"; }
warn()  { printf "\n\033[1;33m%s\033[0m\n" "$*"; }
error() { printf "\n\033[1;31m%s\033[0m\n" "$*"; }

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

if [[ -x "${ROOT_DIR}/dns_fix.sh" ]]; then
  log "Applying DNS fix…"
  chmod +x "${ROOT_DIR}/scripts/dns_fix.sh"
  "${ROOT_DIR}/dns_fix.sh" || warn "dns_fix.sh reported a warning."
else
  warn "dns_fix.sh not found; skipping DNS fix."
fi

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
vcfa_endpoint    = "https://vcfa.provider.lab"
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

#-----------------------------
# 2) Remove existing VCFA configurations (provider-based import + destroy)
#-----------------------------
log "Priming VCFA lookup data (org/region/project)…"
terraform -chdir="${ROOT_DIR}" apply \
  -target="data.vcfa_org.showcase" \
  -target="data.vcfa_region.us_west" \
  -target="data.vcfa_project.default" \
  -refresh-only -auto-approve

# Resolve IDs for imports
log "Resolving IDs from state…"
ORG_ID="$(terraform -chdir="${ROOT_DIR}" state show -no-color data.vcfa_org.showcase | awk -F' = ' '/^ *id *=/{print $2}' | tail -n1)"
REGION_ID="$(terraform -chdir="${ROOT_DIR}" state show -no-color data.vcfa_region.us_west | awk -F' = ' '/^ *id *=/{print $2}' | tail -n1)"
[[ -z "${ORG_ID:-}" || -z "${REGION_ID:-}" ]] && { error "Failed to resolve Org/Region IDs"; exit 1; }

# read vars
read_tfvar() { awk -F= -v key="$1" '$1 ~ "^[[:space:]]*"key"[[:space:]]*$" {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); gsub(/^"|"$|;$/,"",$2); print $2}' "${TFVARS_FILE}" | tail -n1; }
NS_NAME="$(read_tfvar ns_name || echo demo-namespace-vkrcg)"
ORG_CL_NAME="$(read_tfvar org_cl_name || echo showcase-content-library)"
PROVIDER_CL_NAME="$(read_tfvar provider_cl_name || echo provider-content-library)"
ORG_REG_NET_NAME="$(read_tfvar org_reg_net_name || echo showcase-all-appsus-west-region)"
PROVIDER_GW_NAME="$(read_tfvar provider_gw_name || echo provider-gateway-us-west)"
PROVIDER_IP_SPACE="$(read_tfvar provider_ip_space || echo ip-space-us-west)"
REGION_NAME="$(read_tfvar vcfa_region_name || echo us-west-region)"

log "Importing VCFA resources for cleanup…"
terraform -chdir="${ROOT_DIR}" import -var="enable_vcfa_cleanup=true" 'vcfa_supervisor_namespace.project_ns[0]' "${ORG_ID}/${REGION_ID}/${NS_NAME}" || true
terraform -chdir="${ROOT_DIR}" import -var="enable_vcfa_cleanup=true" 'vcfa_content_library.org_cl[0]' "${ORG_ID}/${ORG_CL_NAME}" || true
terraform -chdir="${ROOT_DIR}" import -var="enable_vcfa_cleanup=true" 'vcfa_content_library.provider_cl[0]' "${PROVIDER_CL_NAME}" || true
terraform -chdir="${ROOT_DIR}" import -var="enable_vcfa_cleanup=true" 'vcfa_region_quota.showcase_us_west[0]' "${ORG_ID}/${REGION_ID}" || true
terraform -chdir="${ROOT_DIR}" import -var="enable_vcfa_cleanup=true" 'vcfa_org_regional_networking.showcase_us_west[0]' "${ORG_ID}/${REGION_ID}/${ORG_REG_NET_NAME}" || true
terraform -chdir="${ROOT_DIR}" import -var="enable_vcfa_cleanup=true" 'vcfa_provider_gateway.us_west[0]' "${REGION_ID}/${PROVIDER_GW_NAME}" || true
terraform -chdir="${ROOT_DIR}" import -var="enable_vcfa_cleanup=true" 'vcfa_ip_space.us_west[0]' "${PROVIDER_IP_SPACE}" || true
terraform -chdir="${ROOT_DIR}" import -var="enable_vcfa_cleanup=true" 'vcfa_region.us_west[0]' "${REGION_NAME}" || true

log "Destroying imported VCFA resources…"
terraform -chdir="${ROOT_DIR}" apply -auto-approve -var="enable_vcfa_cleanup=true"

#-----------------------------
# 3) Remove Supervisor installed in vSphere (native REST)
#-----------------------------
log "STEP 3: Removing Supervisor from vSphere…"
bash "${ROOT_DIR}/scripts/remove_supervisor.sh" || warn "Supervisor removal script finished with warnings."

#-----------------------------
# 4) Create NSX Tier-1 + Segment & vSphere Content Library
#-----------------------------
log "Applying NSX/vSphere creation stack (Tier-1 + Segment + Content Library)…"
terraform -chdir="${ROOT_DIR}" apply -auto-approve \
  -target='nsxt_policy_tier1_gateway.se_mgmt' \
  -target='nsxt_policy_segment.se_mgmt' \
  -target='vsphere_content_library.avi_se'

#-----------------------------
# 5) Install AVI + NSX integration
#   5a) DNS record for controller
#   5b) Terraform OVA deploy
#   5c) Export cert -> import into NSX
#   5d) Run ALB onboarding workflow in NSX
#-----------------------------
log "Adding DNS record for Avi controller…"
bash "${ROOT_DIR}/scripts/add_dns_record.sh"

log "Deploying Avi Controller OVA via Terraform…"
terraform -chdir="${ROOT_DIR}" apply -auto-approve -target='vsphere_virtual_machine.avi_controller'

log "Onboarding Avi to NSX (import cert + ALB onboarding)…"
bash "${ROOT_DIR}/scripts/nsx_onboard_alb.sh"

#-----------------------------
# 6) Install Supervisor in vSphere (native REST)
#-----------------------------
log "STEP 6: Installing Supervisor in vSphere…"
bash "${ROOT_DIR}/scripts/install_supervisor.sh" || warn "Supervisor install script finished with warnings."

#-----------------------------
# 7) (Placeholder) VCFA new configuration now that Supervisor/AVI exist
#-----------------------------
log "STEP 7: Apply new VCFA configuration (vcfa_create.tf if present)…"
if [[ -f "${ROOT_DIR}/vcfa_create.tf" ]]; then
  terraform -chdir="${ROOT_DIR}" apply -auto-approve
else
  warn "vcfa_create.tf not found yet. Skipping Step 7 until you add the desired VCFA resources."
fi

log "All steps complete. ✅"
