#!/usr/bin/env bash
set -euo pipefail

CERT_SRC="/tmp/selfsigned-cert.pem"
CERT_DEST="/etc/ssl/certs/selfsigned-cert.pem"
ALIAS="${ALIAS:-oda-vcf-labs}"

log(){ printf "\n\033[1;36m%s\033[0m\n" "$*"; }
warn(){ printf "\n\033[1;33m%s\033[0m\n" "$*"; }
err(){ printf "\n\033[1;31m%s\033[0m\n" "$*"; }

if [[ ! -f "$CERT_SRC" ]]; then
  err "Missing $CERT_SRC on SDDC Manager. Copy it there first."; exit 1
fi

# 1) Install the PEM under /etc/ssl/certs and rehash
log "Installing PEM to $CERT_DEST…"
sudo cp -f "$CERT_SRC" "$CERT_DEST"
sudo chmod 644 "$CERT_DEST"

if [[ -x /usr/bin/rehash_ca_certificates.sh ]]; then
  log "Rehashing CA store…"
  sudo /usr/bin/rehash_ca_certificates.sh
else
  warn "/usr/bin/rehash_ca_certificates.sh not found; continuing."
fi

# 2) Find a Java cacerts keystore (or override via $CACERTS_PATH)
CACERTS_PATH="${CACERTS_PATH:-}"
if [[ -z "$CACERTS_PATH" ]]; then
  # Look for a Java 17 cacerts file
  CANDIDATES=(
    /usr/lib/jvm/*/lib/security/cacerts
    /usr/lib/jvm/java-17-openjdk*/lib/security/cacerts
    /usr/lib/jvm/openjdk-*/lib/security/cacerts
  )
  for c in "${CANDIDATES[@]}"; do
    for f in $c; do
      [[ -f "$f" ]] && CACERTS_PATH="$f" && break 2
    done
  done
fi
if [[ -z "$CACERTS_PATH" || ! -f "$CACERTS_PATH" ]]; then
  err "Could not locate Java cacerts keystore. Set CACERTS_PATH and re-run."; exit 1
fi
log "Using cacerts keystore: $CACERTS_PATH"

# 3) Import into Java truststore (non-interactive, password 'changeit')
log "Importing certificate into Java cacerts with alias '$ALIAS'…"
sudo keytool -importcert -trustcacerts \
  -alias "$ALIAS" \
  -file "$CERT_DEST" \
  -keystore "$CACERTS_PATH" \
  -storepass changeit \
  -noprompt

# 4) Disable depot certificate check in LCM app properties
PROP1="/opt/vmware/vcf/lcm/lcm-app/conf/application-prod.properties"
PROP2="/opt/vmware/vcf/lcm/lcm-app/conf/application-prod.properites"  # (typo variant, handle both)
for F in "$PROP1" "$PROP2"; do
  [[ -f "$F" ]] || continue
  log "Updating lcm.depot.adapter.certificateCheckEnabled=false in $F"
  if grep -q '^lcm\.depot\.adapter\.certificateCheckEnabled=' "$F"; then
    sudo sed -i 's/^lcm\.depot\.adapter\.certificateCheckEnabled=.*/lcm.depot.adapter.certificateCheckEnabled=false/' "$F"
  else
    echo 'lcm.depot.adapter.certificateCheckEnabled=false' | sudo tee -a "$F" >/dev/null
  fi
done

log "SDDC Manager trust configuration completed."
