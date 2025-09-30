#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 4 ]]; then
  echo "Usage: $0 <NSX_HOST> <NSX_USER> <NSX_PASS> <CERT_PEM_PATH> [display_name]"
  exit 2
fi

NSX_HOST="$1"
NSX_USER="$2"
NSX_PASS="$3"
CERT_PEM_PATH="$4"
DISPLAY_NAME="${5:-avi-portal-cert}"

if [[ ! -f "$CERT_PEM_PATH" ]]; then
  echo "Certificate file not found: $CERT_PEM_PATH" >&2
  exit 3
fi

# JSON-escape the PEM with jq (-R: raw; -s: slurp entire file)
JSON_PAYLOAD="$(jq -Rn --arg pem "$(cat "$CERT_PEM_PATH")" --arg name "$DISPLAY_NAME" \
  '{display_name:$name, pem_encoded:$pem}')"

echo "→ Uploading certificate '$DISPLAY_NAME' to NSX trust store at https://$NSX_HOST/…"

# NSX Manager trust-management API (import cert without private key)
# POST /api/v1/trust-management/certificates?action=import
# Body: { "display_name": "...", "pem_encoded": "-----BEGIN CERTIFICATE-----\n...\n" }
resp="$(curl -sk -u "$NSX_USER:$NSX_PASS" \
  -H "Content-Type: application/json" \
  -X POST "https://${NSX_HOST}/api/v1/trust-management/certificates?action=import" \
  -d "$JSON_PAYLOAD")"

# Basic success check
if echo "$resp" | jq -e 'has("id") or has("uuid") or has("results")' >/dev/null 2>&1; then
  echo "✔ NSX cert import request accepted."
else
  echo "✖ NSX cert import appears to have failed:"
  echo "$resp"
  exit 4
fi
