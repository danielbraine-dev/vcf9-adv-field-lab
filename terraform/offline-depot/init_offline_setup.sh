#!/usr/bin/env bash
set -euo pipefail

# Enable tracing with TRACE=1 ./setup.sh …
[[ "${TRACE:-0}" == "1" ]] && set -x

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  
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

step3_deploy_oda(){
  
  #-----------------------------
  # Terraform init (repo root)
  #-----------------------------
  log "Running terraform init…"
  terraform -chdir="${ROOT_DIR}" init -upgrade
  terraform -chdir="${ROOT_DIR}" validate
  
  
  #-----------------------------
  # Install Offline Depot Appliance
  #-----------------------------
 
  ODA_OVA_FILENAME="${ODA_OVA_FILENAME:-$(ls -1 "${ROOT_DIR}"/*.ova 2>/dev/null | head -n1 | xargs -n1 basename)}"
  ODA_OVA_PATH="${ROOT_DIR}/${ODA_OVA_FILENAME}"
  
  if [[ ! -f "${ODA_OVA_PATH}" ]]; then
    error "Could not find an .ova in ${ROOT_DIR}. Place the ODA OVA next to init_offline_setup.sh or set ODA_OVA_FILENAME."
    exit 1
  fi
  
  log "Adding DNS record for Offline Depot Appliance…"
  bash "${ROOT_DIR}/add_oda_dns_record.sh"
  
  log "Deploying Offline Depot Appliance OVA via Terraform…"
  terraform -chdir="${ROOT_DIR}" apply -auto-approve -target='vsphere_virtual_machine.oda_appliance'

  log "Bootstrapping Offline Depot Appliance"
  terraform -chdir="${ROOT_DIR}" apply -auto-approve -target='null_resource.oda_bootstrap'
  pause
}

do_step() {
  case "$1" in
    1) step1_install_tools;;
    2) step2_dns_fix;;
    3) step3_deploy_oda;;
    4) step4_bootstrap_oda;;
    5) step5_download_token;;
    6) step6_download_depot;;
    7) step7_create_nsx_objects;;
    8) step8_deploy_avi;;
    9) step9_create_cert;;
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
