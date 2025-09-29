#!/usr/bin/env bash
set -euo pipefail

DNS_HOST="10.1.1.1"
AVI_FQDN="avi-controller01-a.site-a.vcf.lab"
AVI_IP="$(awk -F= '/avi_mgmt_ip/{gsub(/"| /,"",$2);print $2}' terraform.tfvars)"

[[ -z "$AVI_IP" ]] && { echo "avi_mgmt_ip not set in terraform.tfvars"; exit 1; }

# Use pwsh on remote HoloDeck box to add DNS record
ssh -o StrictHostKeyChecking=no root@"${DNS_HOST}" <<'REMOTE'
pwsh -NoProfile -Command '
  $config = Get-HoloDeckConfig | Import-HoloDeckConfig
  Set-HoloDeckDNSConfig -ConfigPath $config.ConfigPath -DNSRecord "'"${AVI_IP} ${AVI_FQDN}"'"
'
REMOTE

echo "DNS record added: ${AVI_IP} ${AVI_FQDN}"
