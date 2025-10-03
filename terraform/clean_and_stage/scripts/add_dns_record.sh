#!/usr/bin/env bash
set -euo pipefail

DNS_HOST="10.1.1.1"
DNS_ROOT_PASS='CHANGE_ME'   # <— embed the root password here
AVI_FQDN="avi-controller01-a.site-a.vcf.lab"
AVI_IP="$(awk -F= '/avi_mgmt_ip/{gsub(/"| /,"",$2);print $2}' terraform.tfvars)"

[[ -z "$AVI_IP" ]] && { echo "avi_mgmt_ip not set in terraform.tfvars"; exit 1; }

# Ensure sshpass is installed (apt is fine per your note)
if ! command -v sshpass >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -y && sudo apt-get install -y sshpass
  else
    echo "sshpass not found and apt-get not available" >&2
    exit 1
  fi
fi

# If you're running with TRACE=1 elsewhere, avoid echoing the password
XTRACE_OFF=0
if [[ "${TRACE:-0}" == "1" ]]; then
  set +x
  XTRACE_OFF=1
fi

# Pass AVI_IP/AVI_FQDN as env vars and run a small PowerShell script via STDIN
sshpass -p "$DNS_ROOT_PASS" \
  ssh -o StrictHostKeyChecking=no \
      -o PreferredAuthentications=password \
      -o PubkeyAuthentication=no \
      root@"${DNS_HOST}" \
      env AVI_IP="${AVI_IP}" AVI_FQDN="${AVI_FQDN}" pwsh -NoProfile -Command - <<'PS'
$config = Get-HoloDeckConfig | Import-HoloDeckConfig
$ip  = $env:AVI_IP
$dns = $env:AVI_FQDN
Set-HoloDeckDNSConfig -ConfigPath $config.ConfigPath -DNSRecord "$ip $dns"
PS

# Re-enable xtrace if we turned it off
if [[ "$XTRACE_OFF" -eq 1 ]]; then set -x; fi

echo "DNS record added: ${AVI_IP} ${AVI_FQDN}"
