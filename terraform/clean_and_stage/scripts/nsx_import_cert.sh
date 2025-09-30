#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TFVARS="${ROOT_DIR}/terraform.tfvars"

# Read a simple key=value from terraform.tfvars (string values with or without quotes)
read_tfvar() {
  local key="$1"
  awk -F= -v k="$key" '
    $1 ~ "^[[:space:]]*"k"[[:space:]]*$" {
      v=$2
      gsub(/^[[:space:]]+|[[:space:]]+$/,"",v)
      gsub(/^"|"$|;$/,"",v)
      print v
    }' "$TFVARS" | tail -n1
}

NSX_HOST="$(read_tfvar nsx_host || true)"
NSX_USER="$(read_tfvar nsx_username || true)"
NSX_PASS="$(read_tfvar nsx_password || true)"
CERT_NAME="$(read_tfvar avi_cert_name || echo avi-portal-cert)"

[[ -z "${NSX_HOST}" || -z "${NSX_USER}" || -z "${NSX_PASS}" ]] && {
  echo "Missing nsx_host/nsx_username/nsx_password in terraform.tfvars"; exit 2;
}

# Extract the PEM for tls_self_signed_cert.avi from TF state
CERT_PEM="$(
  terraform -chdir="${ROOT_DIR}" state show -no-color tls_self_signed_cert.avi \
    | awk 'BEGIN{s=0}
/^\s*cert_pem\s*=\s*<<EOT/ {s=1; next}
s { print; if ($0 ~ /^EOT$/) exit }' \
    | sed '/^EOT$/d'
)"

if [[ -z "${CERT_PEM}" ]]; then
  echo "Could not extract cert_pem from Terraform state (tls_self_signed_cert.avi)."
  exit 2
fi

# Helper to JSON-encode PEM safely
json_pem="$(printf '%s' "$CERT_PEM" | jq -Rs .)"

echo "Attempting NSX Manager API import…"
status=$(curl -sk -w "%{http_code}" -o /tmp/nsx_cert_resp.json \
  -u "${NSX_USER}:${NSX_PASS}" \
  -H "Content-Type: application/json" \
  -X POST "https://${NSX_HOST}/api/v1/trust-management/certificates?action=import" \
  --data-binary @- <<JSON
{
  "display_name": "${CERT_NAME}",
  "pem_encoded": ${json_pem}
}
JSON
)

if [[ "$status" =~ ^2 ]]; then
  echo "✅ Imported certificate via Manager API."
  exit 0
fi

echo "Manager API import failed (HTTP ${status}). Trying Policy API import…"

# Derive a Policy object id (letters/digits/hyphen)
CERT_ID="$(echo "${CERT_NAME}" | tr -c 'A-Za-z0-9' '-' | tr '[:upper:]' '[:lower:]')"

status2=$(curl -sk -w "%{http_code}" -o /tmp/nsx_cert_resp2.json \
  -u "${NSX_USER}:${NSX_PASS}" \
  -H "Content-Type: application/json" \
  -X PUT "https://${NSX_HOST}/policy/api/v1/infra/certificates/${CERT_ID}?action=import" \
  --data-binary @- <<JSON
{
  "pem_encoded": ${json_pem}
}
JSON
)

if [[ "$status2" =~ ^2 ]]; then
  echo "✅ Imported certificate via Policy API."
  exit 0
fi

echo "❌ Both Manager and Policy API imports failed."
echo "  - Manager API status: ${status} (see /tmp/nsx_cert_resp.json)"
echo "  - Policy  API status: ${status2} (see /tmp/nsx_cert_resp2.json)"
exit 1
