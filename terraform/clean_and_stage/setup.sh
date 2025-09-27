#!/usr/bin/env bash
set -Eeuo pipefail

# ============ helpers ============
log()  { printf "\n\033[1;34m[INFO]\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m[WARN]\033[0m %s\n" "$*"; }
die()  { printf "\n\033[1;31m[ERR]\033[0m %s\n" "$*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing '$1' in PATH."; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEANUP_DIR="${ROOT_DIR}/vcfa_cleanup"   # optional
CREATE_DIR="${ROOT_DIR}"                 # your current root with nsx + vsphere

# ============ secrets/env ============
# Provide a ./secrets.env file with:
#   VCFA_URL=https://your-vcfa-fqdn
#   VCFA_USERNAME=...
#   VCFA_PASSWORD=...
#   VC_URL=https://vc-wld01-a.site-a.vcf.lab
#   VC_USER=administrator@wld.sso
#   VC_PASS=...
#   VC_CLUSTER_NAME=<cluster hosting Supervisor to remove/reinstall>   # e.g. wld-01a-cl
if [[ -f "${ROOT_DIR}/secrets.env" ]]; then
  # shellcheck disable=SC1091
  source "${ROOT_DIR}/secrets.env"
else
  warn "No secrets.env found. The script will still run, but VCFA and vCenter API calls will be skipped."
fi

# ============ preflight ============
for bin in bash curl jq terraform; do need "$bin"; done
[[ -f "${ROOT_DIR}/commands.txt" ]] || die "commands.txt not found next to setup.sh"
[[ -f "${ROOT_DIR}/dns_fix.sh" ]] || warn "dns_fix.sh not found; continuing without DNS fix."

# ============ functions ============

run_commands_txt() {
  log "Running commands.txt bootstrap…"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    log "Executing: $line"
    # shellcheck disable=SC2086
    bash -lc "$line" || warn "Command failed (continuing): $line"
  done < "${ROOT_DIR}/commands.txt"
}

apply_dns_fix() {
  if [[ -x "${ROOT_DIR}/dns_fix.sh" ]]; then
    log "Applying DNS fix…"
    (cd "${ROOT_DIR}" && ./dns_fix.sh)
  else
    warn "dns_fix.sh not executable or missing; skipping."
  fi
}

get_vcfa_access_token() {
  # Uses the documented VCF 9.x flow: refresh token via Identity Service, then access token via IaaS.
  # Doc ref for flow you provided. :contentReference[oaicite:0]{index=0}
  [[ -n "${VCFA_URL:-}" && -n "${VCFA_USERNAME:-}" && -n "${VCFA_PASSWORD:-}" ]] || {
    warn "VCFA_URL/VCFA_USERNAME/VCFA_PASSWORD not set — skipping VCFA auth.";
    return 1; }

  log "Fetching VCFA refresh token…"
  local refresh token
  refresh="$(curl -sk -X POST "${VCFA_URL}/csp/gateway/am/api/login?access_token" \
    -H 'Content-Type: application/json' -H 'Accept: application/json' \
    -d "{\"username\":\"${VCFA_USERNAME}\",\"password\":\"${VCFA_PASSWORD}\"}" | jq -r '.refresh_token')"

  [[ -n "$refresh" && "$refresh" != "null" ]] || die "Failed to get VCFA refresh token (check creds/URL)."

  log "Exchanging refresh token for access token…"
  token="$(curl -sk -X POST "${VCFA_URL}/iaas/api/login" \
    -H 'Content-Type: application/json' -H 'Accept: application/json' \
    -d "{\"refreshToken\":\"${refresh}\"}" | jq -r '.token')"

  [[ -n "$token" && "$token" != "null" ]] || die "Failed to get VCFA access token."
  export TF_VAR_vcfa_endpoint="${VCFA_URL}"
  export TF_VAR_vcfa_token="${token}"
  log "VCFA access token exported to TF_VAR_vcfa_token."
}

vc_login_session() {
  # Returns a vCenter session ID in global var VC_SESSION
  [[ -n "${VC_URL:-}" && -n "${VC_USER:-}" && -n "${VC_PASS:-}" ]] || {
    warn "VC_URL/VC_USER/VC_PASS not set — skipping vCenter API calls.";
    return 1; }
  log "Creating vCenter API session…"

  # Try modern endpoint first
  VC_SESSION="$(curl -sk -X POST "${VC_URL}/api/session" -u "${VC_USER}:${VC_PASS}" | jq -r '.')"
  if [[ -z "$VC_SESSION" || "$VC_SESSION" == "null" ]]; then
    # Fallback to cis session (older)
    VC_SESSION="$(curl -sk -X POST "${VC_URL}/rest/com/vmware/cis/session" -u "${VC_USER}:${VC_PASS}" | jq -r '.value')"
  fi
  [[ -n "$VC_SESSION" && "$VC_SESSION" != "null" ]] || die "Failed to obtain vCenter session."
  log "vCenter session established."
}

disable_supervisor() {
  # Uses vSphere Automation "namespace-management/clusters" disable API.
  # POST https://{server}/api/vcenter/namespace-management/clusters/{cluster}?action=disable . :contentReference[oaicite:1]{index=1}
  [[ -n "${VC_CLUSTER_NAME:-}" ]] || { warn "VC_CLUSTER_NAME not set; skipping Supervisor disable."; return 0; }
  vc_login_session || return 0

  log "Resolving cluster MoID for '${VC_CLUSTER_NAME}'…"
  # vSphere 8 REST list clusters by name
  local cluster_id
  cluster_id="$(curl -sk -G "${VC_URL}/api/vcenter/cluster" \
    -H "vmware-api-session-id: ${VC_SESSION}" \
    --data-urlencode "filter.names=${VC_CLUSTER_NAME}" | jq -r '.[0].cluster // .value[0].cluster')"

  [[ -n "$cluster_id" && "$cluster_id" != "null" ]] || die "Could not resolve cluster ID for '${VC_CLUSTER_NAME}'."

  log "Disabling vSphere Namespaces (Supervisor) on cluster '${VC_CLUSTER_NAME}' (${cluster_id})…"
  curl -sk -X POST \
    "${VC_URL}/api/vcenter/namespace-management/clusters/${cluster_id}?action=disable" \
    -H "vmware-api-session-id: ${VC_SESSION}" >/dev/null

  log "Disable request submitted. This tears down Supervisor control-plane & worker nodes."
}

tf_init_if_needed() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  if [[ ! -d "${dir}/.terraform" ]]; then
    log "terraform init in ${dir}…"
    terraform -chdir="$dir" init -upgrade -input=false
  fi
}

tf_apply_create_stack() {
  log "Applying CREATE stack (NSX T1 + Segment + vSphere Content Library)…"
  tf_init_if_needed "${CREATE_DIR}"
  terraform -chdir="${CREATE_DIR}" apply -auto-approve
}

tf_apply_vcfa_cleanup() {
  # Optional: will only run if vcfa_cleanup/ exists
  [[ -d "${CLEANUP_DIR}" ]] || { warn "No vcfa_cleanup/ directory found — skipping VCFA cleanup step."; return 0; }
  get_vcfa_access_token || { warn "VCFA token not acquired — skipping VCFA cleanup step."; return 0; }

  log "Running VCFA cleanup Terraform (imports/destroys should be modeled in this module)…"
  tf_init_if_needed "${CLEANUP_DIR}"
  terraform -chdir="${CLEANUP_DIR}" apply -auto-approve
}

# (placeholder) Install/configure NSX ALB via Terraform if avi*.tf is present
maybe_apply_avi() {
  if ls "${CREATE_DIR}"/avi*.tf >/dev/null 2>&1; then
    log "Found AVI Terraform; applying…"
    terraform -chdir="${CREATE_DIR}" apply -auto-approve -target='avi_*' || warn "AVI apply had issues; review above."
  else
    warn "No AVI Terraform (*.tf) found. Skipping Step 5 for now."
  fi
}

# (placeholder) Supervisor enablement (needs inputs)
enable_supervisor_placeholder() {
  warn "Supervisor enablement (Step 6) is not automated yet — it needs your networking/storage inputs."
  warn "Once you confirm those, I can wire a REST-based enablement call similar to disable."
}

# (placeholder) VCFA (re)creation after Supervisor/AVI is ready
vcfa_create_placeholder() {
  if [[ -d "${ROOT_DIR}/vcfa_create" ]]; then
    log "Applying VCFA (re)creation Terraform…"
    tf_init_if_needed "${ROOT_DIR}/vcfa_create"
    terraform -chdir="${ROOT_DIR}/vcfa_create" apply -auto-approve
  else
    warn "No vcfa_create/ directory found — skipping Step 7 for now."
  fi
}

# ============ main flow ============

log "1) Setup tools in lab and apply fixes"
run_commands_txt
apply_dns_fix

log "2) Remove existing VCFA configurations"
tf_apply_vcfa_cleanup

log "3) Remove Supervisor from vSphere (disable vSphere Namespaces)"
disable_supervisor

log "4) Create NSX T1 + Segment + tags/DHCP and vSphere Content Library"
tf_apply_create_stack

log "5) Install/configure AVI (if Terraform present)"
maybe_apply_avi

log "6) Install Supervisor in vSphere (placeholder, needs inputs)"
enable_supervisor_placeholder

log "7) Make new configuration changes in VCFA (placeholder: apply vcfa_create/ if present)"
vcfa_create_placeholder

log "All done (for configured stages). Review WARN lines for any skipped steps."
