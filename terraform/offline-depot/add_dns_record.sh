#!/usr/bin/env bash
set -euo pipefail

DNS_HOST="10.1.1.1"
DNS_ROOT_PASS='VMware123!VMware123!'   # <— embed the root password here
ODA_FQDN="oda.site-a.vcf.lab"
ODA_IP="10.1.1.190"

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

# Pass ODA_IP/ODA_FQDN as env vars and run a small PowerShell script via STDIN
sshpass -p "$DNS_ROOT_PASS" \
  ssh -o StrictHostKeyChecking=no \
      -o PreferredAuthentications=password \
      -o PubkeyAuthentication=no \
      root@"${DNS_HOST}" \
      env ODA_IP="${ODA_IP}" ODA_FQDN="${ODA_FQDN}" pwsh -NoProfile -Command - <<'PS'
$config = Get-HoloDeckConfig | Import-HoloDeckConfig
$ip  = $env:ODA_IP
$dns = $env:ODA_FQDN
Set-HoloDeckDNSConfig -ConfigPath $config.ConfigPath -DNSRecord "$ip $dns"
PS

# Re-enable xtrace if we turned it off
if [[ "$XTRACE_OFF" -eq 1 ]]; then set -x; fi

echo "DNS record added: ${ODA_IP} ${ODA_FQDN}"
