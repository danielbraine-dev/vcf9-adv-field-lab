#!/usr/bin/env bash
set -euo pipefail

NSX_HOST="$(awk -F= '/nsx_host/{gsub(/"| /,"",$2);print $2}' terraform.tfvars)"
NSX_USER="$(awk -F= '/nsx_username/{gsub(/"| /,"",$2);print $2}' terraform.tfvars)"
NSX_PASS="$(awk -F= '/nsx_password/{gsub(/"| /,"",$2);print $2}' terraform.tfvars)"
AVI_IP="$(awk -F= '/avi_mgmt_ip/{gsub(/"| /,"",$2);print $2}' terraform.tfvars)"

[[ -z "$NSX_HOST" || -z "$NSX_USER" || -z "$NSX_PASS" || -z "$AVI_IP" ]] && { echo "Missing NSX or AVI vars"; exit 1; }

# 1) Run ALB onboarding workflow (your exact payload)
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
