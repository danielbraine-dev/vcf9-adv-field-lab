#!/usr/bin/env bash
set -euo pipefail

NSX_HOST="${1:-nsx-wld01-a.site-a.vcf.lab}"
NSX_USER="${2:-admin}"
NSX_PASS="${3:-VMware123!VMware123!}"
AVI_IP="${4:-10.1.1.200}"
AVI_USER="${5:-admin}"
AVI_PASS="${6:-VMware123!VMware123!}"

echo "Initiating ALB onboarding workflow on NSX ($NSX_HOST)..."

# Execute the PUT request and capture the response
RESPONSE=$(curl -s -k -u "${NSX_USER}:${NSX_PASS}" --location --request PUT "https://${NSX_HOST}/policy/api/v1/infra/alb-onboarding-workflow" \
--header 'X-Allow-Overwrite: True' \
--header 'Content-Type: application/json' \
--data-raw "{
\"owned_by\": \"LCM\",
\"cluster_ip\": \"${AVI_IP}\",
\"infra_admin_username\": \"${AVI_USER}\",
\"infra_admin_password\": \"${AVI_PASS}\"
}")

# Validate the output for the DEACTIVATE_PROVIDER status
if echo "$RESPONSE" | grep -q '"status"\s*:\s*"DEACTIVATE_PROVIDER"'; then
    echo "[+] NSX ALB onboarding workflow successful! Trust established."
else
    echo "[-] Failed! Unexpected response from NSX:"
    echo "$RESPONSE"
    exit 1
fi
