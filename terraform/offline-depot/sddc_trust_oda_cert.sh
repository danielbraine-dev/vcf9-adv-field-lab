#!/usr/bin/env bash
set -euo pipefail

CERT_SRC="/tmp/selfsigned-cert.pem"
CERT_DEST="/etc/ssl/certs/selfsigned-cert.pem"
ALIAS="${ALIAS:-oda-vcf-labs}" # Using the alias from your instructions
PROPERTIES_FILE="/opt/vmware/vcf/lcm/lcm-app/conf/application-prod.properties"

log(){ printf "\n\033[1;36m%s\033[0m\n" "$*"; }
warn(){ printf "\n\033[1;33m%s\033[0m\n" "$*"; }
err(){ printf "\n\033[1;31m%s\033[0m\n" "$*"; }

if [[ $EUID -ne 0 ]]; then err "Run this script as root (via su -)." ; exit 1; fi

if [[ ! -f "$CERT_SRC" ]]; then
  err "Missing $CERT_SRC on SDDC Manager. Copy it there first."; exit 1
fi

log "Installing PEM to $CERT_DEST…"
cp -f "$CERT_SRC" "$CERT_DEST"
chmod 644 "$CERT_DEST"

if [[ -x /usr/bin/rehash_ca_certificates.sh ]]; then
  log "Rehashing CA store…"
  /usr/bin/rehash_ca_certificates.sh
else
  warn "/usr/bin/rehash_ca_certificates.sh not found; continuing."
fi

# ---
# UPDATED: Rely on CACERTS_PATH being passed from init_offline_setup.sh
# ---
if [[ -z "${CACERTS_PATH:-}" || ! -f "$CACERTS_PATH" ]]; then
  err "CACERTS_PATH env var is not set or file not found: '$CACERTS_PATH'"; 
  exit 1
fi
log "Using cacerts keystore: $CACERTS_PATH"


# ---
# UPDATED: Make keytool command idempotent (safe to re-run)
# 1. Delete the alias first (ignore error if it doesn't exist)
# 2. Import the new certificate
# ---
log "Removing old certificate with alias '$ALIAS' (if it exists)…"
keytool -delete -alias "$ALIAS" \
  -keystore "$CACERTS_PATH" \
  -storepass secretpassword -noprompt \
  || warn "Alias '$ALIAS' not found, or keystore empty. This is safe to ignore."

log "Importing new certificate into Java cacerts with alias '$ALIAS'…"
keytool -importcert -trustcacerts \
  -alias "$ALIAS" \
  -file "$CERT_DEST" \
  -keystore "$CACERTS_PATH" \
  -storepass secretpassword \
  -noprompt

# ---
# UPDATED: Use the single, correctly-spelled properties file
# ---
if [[ -f "$PROPERTIES_FILE" ]]; then
  log "Setting lcm.depot.adapter.certificateCheckEnabled=false in $PROPERTIES_FILE"
  if grep -q '^lcm\.depot\.adapter\.certificateCheckEnabled=' "$PROPERTIES_FILE"; then
    # Update existing line
    sed -i 's/^lcm\.depot\.adapter\.certificateCheckEnabled=.*/lcm.depot.adapter.certificateCheckEnabled=false/' "$PROPERTIES_FILE"
  else
    # Add new line if it doesn't exist
    echo '' >> "$PROPERTIES_FILE" # ensure newline
    echo 'lcm.depot.adapter.certificateCheckEnabled=false' >> "$PROPERTIES_FILE"
  fi
else
  warn "Properties file not found: $PROPERTIES_FILE"
fi

# ---
# ADDED: Restart the lcm service as per your instructions
# ---
log "Restarting lcm service…"
systemctl restart lcm

log "SDDC Manager trust configuration completed."
