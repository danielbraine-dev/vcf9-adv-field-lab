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

step4_conf_sddc_trust() {
  echo "[4] Trust ODA certificate on SDDC Manager…"

  SDDC_HOST="10.1.1.5"
  SDDC_USER="vcf"
  SDDC_PASS="VMware123!VMware123!"    # SSH password for vcf
  SU_PASS="VMware123!VMware123!"       # Password su expects (set to *root* password if required)
  CACERTS_PATH="/usr/lib/jvm/openjdk-java17-headless.x86_g4/lib/security/cacerts"

  LOCAL_SCRIPT="${ROOT_DIR}/sddc_trust_oda_cert.sh"
  [[ -f "$LOCAL_SCRIPT" ]] || { error "Missing $LOCAL_SCRIPT"; exit 1; }
  [[ -x "$LOCAL_SCRIPT" ]] || chmod +x "$LOCAL_SCRIPT" || true

  SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"

  # Tools we need locally
  if ! command -v sshpass >/dev/null 2>&1; then
    log "Installing sshpass…"
    sudo apt-get update -y && sudo apt-get install -y sshpass
  fi
  if ! command -v expect >/dev/null 2>&1; then
    log "Installing expect…"
    sudo apt-get update -y && sudo apt-get install -y expect
  fi

  # Copy the script to SDDC Manager
  log "Copying trust script to ${SDDC_HOST}…"
  sshpass -p "$SDDC_PASS" scp $SSH_OPTS "$LOCAL_SCRIPT" "${SDDC_USER}@${SDDC_HOST}:/tmp/"

  # Use expect to SSH, then su - to root, export CACERTS_PATH, and run the script
  log "Running trust script on SDDC Manager as root via su - …"
  expect <<'EOF'
    set timeout 1200
    # Variables from shell env
    set host [exec bash -lc "printf %s ${SDDC_HOST}"]
    set user [exec bash -lc "printf %s ${SDDC_USER}"]
    set sshpass [exec bash -lc "printf %s ${SDDC_PASS}"]
    set supass [exec bash -lc "printf %s ${SU_PASS}"]
    set cacerts [exec bash -lc "printf %s ${CACERTS_PATH}"]

    # Start SSH with a TTY (-tt) so su interacts properly
    spawn sshpass -p $sshpass ssh -tt -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 $user@$host

    expect {
      -re "(?i)password:" { send -- "$sshpass\r"; exp_continue }
      -re "[$#] $" { }
    }

    # Become root
    send -- "su -\r"
    expect {
      -re "(?i)password:" { send -- "$supass\r" }
      timeout { exit 2 }
    }

    # Confirm root shell (prompt ends with # usually)
    expect -re "# $"

    # Export env and run script
    send -- "export CACERTS_PATH=\"$cacerts\"; bash /tmp/sddc_trust_oda_cert.sh\r"
    expect {
      -re "# $" { }
      timeout { exit 3 }
    }

    # Exit root shell and SSH
    send -- "exit\r"
    expect -re "\\$ $"
    send -- "exit\r"
    expect eof
EOF

  echo "[4] SDDC Manager trust configuration completed."
  pause
}



do_step() {
  case "$1" in
    1) step1_install_tools;;
    2) step2_dns_fix;;
    3) step3_deploy_oda;;
    4) step4_conf_sddc_trust;;
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
    for n in {1..9}; do do_step "$n"; done
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
