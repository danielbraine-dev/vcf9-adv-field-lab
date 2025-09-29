#!/usr/bin/env bash
set -euo pipefail

NSX_HOST="$(awk -F= '/nsx_host/{gsub(/"| /,"",$2);print $2}' terraform.tfvars)"
NSX_USER="$(awk -F= '/nsx_username/{gsub(/"| /,"",$2);print $2}' terraform.tfvars)"
NSX_PASS="$(awk -F= '/nsx_password/{gsub(/"| /,"",$2);print $2}' terraform.tfvars)"
AVI_IP="$(awk -F= '/avi_mgmt_ip/{gsub(/"| /,"",$2);print $2}' terraform.tfvars)"

[[ -z "$NSX_HOST" || -z "$NSX_USER" || -z "$NSX_PASS" || -z "$AVI_IP" ]] && { echo "Missing NSX or AVI vars"; exit 1; }

# 1) Grab Avi controller server cert
PEM="avi_controller.pem"
echo "Exporting Avi controller certificate to ${PEM}…"
echo | openssl s_client -connect "${AVI_IP}:443" -showcerts 2>/dev/null | openssl x509 -outform PEM > "${PEM}"

# 2) Import cert to NSX trust store
echo "Importing Avi cert into NSX trust store…"
curl -sk -u "${NSX_USER}:${NSX_PASS}" \
  -H "Content-Type: application/json" \
  -X POST "https://${NSX_HOST}/api/v1/trust-management/certificates?action=import" \
  --data-binary @"<(jq -Rn --arg pem "$(cat ${PEM})" '{pem_encoded: $pem, display_name: "avi-controller-cert"}')"

# 3) Run ALB onboarding workflow (your exact payload)
echo "Running ALB onboarding workflow in NSX…"
curl -sk -X PUT "https://${NSX_HOST}/policy/api/v1/infra/alb-onboarding-workflow" \
  -H 'X-Allow-Overwrite: True' \
  -H 'Content-Type: application/json' \
  -u "${NSX_USER}:${NSX_PASS}" \
  --data-raw "{
    \"owned_by\": \"LCM\",
    \"cluster_ip\": \"${AVI_IP}\",
    \"infra_admin_username\": \"admin\",
    \"infra_admin_password\": \"VMware123!VMware123!\",
    \"dns_servers\": [\"10.1.1.1\"],
    \"ntp_servers\": [\"10.1.1.1\"]
  }"

echo "NSX ALB onboarding call submitted."
