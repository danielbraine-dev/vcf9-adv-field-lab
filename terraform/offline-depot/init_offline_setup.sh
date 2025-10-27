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

step4_bootstrap_oda() {
  echo "[4] Trust ODA certificate on SDDC Manager…"

  SDDC_HOST="10.1.1.5"
  SDDC_USER="vcf"
  SDDC_PASS="VMware123!VMware123!"    # SSH password for vcf
  SU_PASS="VMware123!VMware123!"       # password su - expects (change to root’s if needed)
  CACERTS_PATH="/usr/lib/jvm/openjdk-java17-headless.x86_g4/lib/security/cacerts"

  LOCAL_SCRIPT="${ROOT_DIR}/scripts/sddc_trust_oda_cert.sh"
  [[ -f "$LOCAL_SCRIPT" ]] || { error "Missing $LOCAL_SCRIPT"; exit 1; }
  [[ -x "$LOCAL_SCRIPT" ]] || chmod +x "$LOCAL_SCRIPT" || true

  SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"

  # Ensure tools locally
  if ! command -v sshpass >/dev/null 2>&1; then
    log "Installing sshpass…"
    sudo apt-get update -y && sudo apt-get install -y sshpass
  fi
  if ! command -v expect >/dev/null 2>&1; then
    log "Installing expect…"
    sudo apt-get update -y && sudo apt-get install -y expect
  fi

  # Copy the trust script up to SDDC Manager
  log "Copying trust script to ${SDDC_HOST}…"
  sshpass -p "$SDDC_PASS" scp $SSH_OPTS "$LOCAL_SCRIPT" "${SDDC_USER}@${SDDC_HOST}:/tmp/" || { error "SCP failed"; exit 1; }

  # Export vars so Expect can read them via env()
  export SDDC_HOST SDDC_USER SDDC_PASS SU_PASS CACERTS_PATH

  # Run expect with debug enabled (-d) so you can see interaction if it hangs
  log "Running trust script on SDDC Manager as root via su - …"
  expect -d <<'EOF'
    log_user 1
    set timeout 1200

    # Pull from environment
    set host $env(SDDC_HOST)
    set user $env(SDDC_USER)
    set sshpass $env(SDDC_PASS)
    set supass $env(SU_PASS)
    set cacerts $env(CACERTS_PATH)

    # Common prompt regexes
    set user_prompt  {[\r\n].*[\$>\]]\s*$}
    set root_prompt  {[\r\n].*#\s*$}

    # Start SSH with a TTY so su interacts properly
    spawn sshpass -p $sshpass ssh -tt -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR $user@$host

    # Land on a shell prompt
    expect {
      -re "(?i)password:" { send -- "$sshpass\r"; exp_continue }
      -re $user_prompt    { }
      timeout             { send_error "ERROR: SSH connection timed out\n"; exit 10 }
      eof                 { send_error "ERROR: SSH connection failed\n"; exit 11 }
    }

    # Quick precheck for the PEM file (must already be there from ODA script)
    send -- "test -f /tmp/selfsigned-cert.pem && echo __PEM_OK__ || echo __PEM_MISSING__\r"
    expect {
      -re "__PEM_OK__"      { }
      -re "__PEM_MISSING__" { send_error "ERROR: /tmp/selfsigned-cert.pem not found on SDDC Manager\n"; exit 12 }
      timeout               { send_error "ERROR: PEM precheck timed out\n"; exit 13 }
    }

    # Become root
    send -- "su -\r"
    expect {
      -re "(?i)password:" { send -- "$supass\r" }
      timeout             { send_error "ERROR: No password prompt from su -\n"; exit 14 }
    }

    # Wait for root prompt
    expect {
      -re $root_prompt { }
      timeout          { send_error "ERROR: Did not get a root prompt after su -\n"; exit 15 }
    }

    # Export env and run the trust script as root
    send -- "export CACERTS_PATH=\"$cacerts\"; bash -lc 'set -euo pipefail; bash /tmp/sddc_trust_oda_cert.sh && echo __TRUST_DONE__'\r"
    expect {
      -re "__TRUST_DONE__" { }
      -re $root_prompt     { exp_continue }   ;# stream root shell output
      timeout              { send_error "ERROR: Trust script timed out\n"; exit 16 }
    }

    # Exit root shell and SSH
    send -- "exit\r"
    expect {
      -re $user_prompt { }
      timeout          { }
    }
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
