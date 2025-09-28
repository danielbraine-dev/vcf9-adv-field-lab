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
  chmod +x "${ROOT_DIR}/dns_fix.sh"
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

# ---- VCFA provider ----
vcfa_endpoint    = "https://vcfa.provider.lab"
vcfa_token       = "<PUT_YOUR_VCFA_TOKEN_HERE>"

# ---- vSphere DC for Content Library lookup ----
vsphere_datacenter = "wld-01a-DC"

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

# ---- K8s (used later in Step 7 ONLY) ----
kubeconfig_path  = "~/.kube/config"
kube_context     = "sup-wld"
EOF
fi

# Terraform init (repo root)
log "Running terraform init…"
terraform -chdir="${ROOT_DIR}" init -upgrade

#-----------------------------
# 2) Remove existing VCFA configurations (imports + destroy)
#   NOTE: No kube contexts or kubernetes provider here.
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

# Read names from tfvars (best-effort)
read_tfvar() { awk -F= -v key="$1" '$1 ~ "^[[:space:]]*"key"[[:space:]]*$" {gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); gsub(/^"|"$|;$/,"",$2); print $2}' "${TFVARS_FILE}" | tail -n1; }
NS_NAME="$(read_tfvar ns_name || echo demo-namespace-vkrcg)"
ORG_CL_NAME="$(read_tfvar org_cl_name || echo showcase-content-library)"
PROVIDER_CL_NAME="$(read_tfvar provider_cl_name || echo provider-content-library)"
ORG_REG_NET_NAME="$(read_tfvar org_reg_net_name || echo showcase-all-appsus-west-region)"
PROVIDER_GW_NAME="$(read_tfvar provider_gw_name || echo provider-gateway-us-west)"
PROVIDER_IP_SPACE="$(read_tfvar provider_ip_space || echo ip-space-us-west)"
REGION_NAME="$(read_tfvar vcfa_region_name || echo us-west-region)"

log "Importing VCFA resources for cleanup…"
# Namespace in VCFA (project-scoped) — uses VCFA provider, not Kubernetes
terraform -chdir="${ROOT_DIR}" import -var="enable_vcfa_cleanup=true" 'vcfa_supervisor_namespace.project_ns[0]' "${ORG_ID}/${REGION_ID}/${NS_NAME}" || true
# Org CL
terraform -chdir="${ROOT_DIR}" import -var="enable_vcfa_cleanup=true" 'vcfa_content_library.org_cl[0]' "${ORG_ID}/${ORG_CL_NAME}" || true
# Provider CL
terraform -chdir="${ROOT_DIR}" import -var="enable_vcfa_cleanup=true" 'vcfa_content_library.provider_cl[0]' "${PROVIDER_CL_NAME}" || true
# Quota (org/region)
terraform -chdir="${ROOT_DIR}" import -var="enable_vcfa_cleanup=true" 'vcfa_region_quota.showcase_us_west[0]' "${ORG_ID}/${REGION_ID}" || true
# Org regional networking
terraform -chdir="${ROOT_DIR}" import -var="enable_vcfa_cleanup=true" 'vcfa_org_regional_networking.showcase_us_west[0]' "${ORG_ID}/${REGION_ID}/${ORG_REG_NET_NAME}" || true
# Provider gateway
terraform -chdir="${ROOT_DIR}" import -var="enable_vcfa_cleanup=true" 'vcfa_provider_gateway.us_west[0]' "${REGION_ID}/${PROVIDER_GW_NAME}" || true
# Provider IP space
terraform -chdir="${ROOT_DIR}" import -var="enable_vcfa_cleanup=true" 'vcfa_ip_space.us_west[0]' "${PROVIDER_IP_SPACE}" || true
# Region
terraform -chdir="${ROOT_DIR}" import -var="enable_vcfa_cleanup=true" 'vcfa_region.us_west[0]' "${REGION_NAME}" || true

log "Destroying imported VCFA resources…"
terraform -chdir="${ROOT_DIR}" apply -auto-approve -var="enable_vcfa_cleanup=false"

#-----------------------------
# 3) Remove Supervisor installed in vSphere
#-----------------------------
log "STEP 3: Removing Supervisor from vSphere…"
if [[ -x "${ROOT_DIR}/scripts/remove_supervisor.sh" ]]; then
  "${ROOT_DIR}/scripts/remove_supervisor.sh"
else
  warn "scripts/remove_supervisor.sh not found. Supervisor removal must be automated here (vCenter API/CLI)."
fi

#-----------------------------
# 4) Create NSX T1 + segment/DHCP + tags
#-----------------------------
log "Applying NSX/vSphere creation stack (Tier-1 + Segment + Content Library)…"
terraform -chdir="${ROOT_DIR}" apply -auto-approve \
  -target='nsxt_policy_tier1_gateway.se_mgmt' \
  -target='nsxt_policy_segment.se_mgmt' \
  -target='vsphere_content_library.avi_se'

#-----------------------------
# 5) Install AVI and related NSX configuration
#-----------------------------
log "STEP 5: Installing/Configuring AVI…"
if [[ -x "${ROOT_DIR}/scripts/install_avi.sh" ]]; then
  "${ROOT_DIR}/scripts/install_avi.sh"
else
  warn "scripts/install_avi.sh not found. Add your AVI controller/bootstrap & NSX integrations here (or Terraform AVI resources)."
fi

#-----------------------------
# 6) Install Supervisor in vSphere
#-----------------------------
log "STEP 6: Installing Supervisor in vSphere…"
if [[ -x "${ROOT_DIR}/scripts/install_supervisor.sh" ]]; then
  "${ROOT_DIR}/scripts/install_supervisor.sh"
else
  warn "scripts/install_supervisor.sh not found. Add your Workload Management enablement here."
fi

#-----------------------------
# 7) Post-Supervisor: create VCFA contexts & new VCFA config
#-----------------------------
log "Creating VCFA contexts (now that Supervisor exists)…"
vcf context create sup-wld \
  --endpoint 10.1.0.2 -u administrator@wld.sso \
  --insecure-skip-tls-verify --type k8s --auth-type basic || true

vcf context create vks-cluster-qxml \
  --endpoint 10.1.0.2 -u administrator@wld.sso \
  --insecure-skip-tls-verify \
  --workload-cluster-name kubernetes-cluster-qxml \
  --workload-cluster-namespace demo-namespace-vkrcg \
  --type k8s --auth-type basic || true

vcf context use sup-wld || warn "vcf context use sup-wld failed."

# Enable Kubernetes provider ONLY now (if you need it later in TF)
KUBE_PROVIDER_FILE="${ROOT_DIR}/z_kube_provider.auto.tf"
if [[ ! -f "${KUBE_PROVIDER_FILE}" ]]; then
  log "Enabling Kubernetes provider (post-Supervisor)…"
  cat > "${KUBE_PROVIDER_FILE}" <<'EOF'
provider "kubernetes" {
  config_path    = var.kubeconfig_path
  config_context = var.kube_context
}
EOF
fi

log "Applying NEW VCFA configuration (make resources in vcfa_create.tf)…"
if grep -q 'vcfa_' "${ROOT_DIR}"/vcfa_create.tf 2>/dev/null; then
  terraform -chdir="${ROOT_DIR}" apply -auto-approve
else
  warn "vcfa_create.tf not found yet. Add desired VCFA resources so new Supervisor/AVI are consumable, then re-run this script."
fi

log "All steps complete. ✅"
