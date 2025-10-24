#!/usr/bin/env bash
set -euo pipefail

CERT_SRC="/tmp/selfsigned-cert.pem"
CERT_DEST="/etc/ssl/certs/selfsigned-cert.pem"
ALIAS="${ALIAS:-oda-vcf-labs}"

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

# Locate Java cacerts keystore (or override with CACERTS_PATH)
CACERTS_PATH="${CACERTS_PATH:-}"
if [[ -z "$CACERTS_PATH" ]]; then
  CANDIDATES=(
    /usr/lib/jvm/*/lib/security/cacerts
    /usr/lib/jvm/java-17-openjdk*/lib/security/cacerts
    /usr/lib/jvm/openjdk-*/lib/security/cacerts
    /usr/lib/jvm/openjdk-java17-headless.x86_g4/lib/security/cacerts
  )
  for c in "${CANDIDATES[@]}"; do
    for f in $c; do
      [[ -f "$f" ]] && CACERTS_PATH="$f" && break 2
    done
  done
fi
[[ -n "$CACERTS_PATH" && -f "$CACERTS_PATH" ]] || { err "Could not locate Java cacerts; set CACERTS_PATH and re-run."; exit 1; }
log "Using cacerts keystore: $CACERTS_PATH"

log "Importing certificate into Java cacerts with alias '$ALIAS'…"
keytool -importcert -trustcacerts \
  -alias "$ALIAS" \
  -file "$CERT_DEST" \
  -keystore "$CACERTS_PATH" \
  -storepass changeit \
  -noprompt

# Update LCM property (handle both spellings)
PROP1="/opt/vmware/vcf/lcm/lcm-app/conf/application-prod.properties"
PROP2="/opt/vmware/vcf/lcm/lcm-app/conf/application-prod.properites"
for F in "$PROP1" "$PROP2"; do
  [[ -f "$F" ]] || continue
  log "Setting lcm.depot.adapter.certificateCheckEnabled=false in $F"
  if grep -q '^lcm\.depot\.adapter\.certificateCheckEnabled=' "$F"; then
    sed -i 's/^lcm\.depot\.adapter\.certificateCheckEnabled=.*/lcm.depot.adapter.certificateCheckEnabled=false/' "$F"
  else
    echo 'lcm.depot.adapter.certificateCheckEnabled=false' >> "$F"
  fi
done

log "SDDC Manager trust configuration completed."
