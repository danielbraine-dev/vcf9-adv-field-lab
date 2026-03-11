#!/usr/bin/env bash
set -euo pipefail

# Variables
DNS_HOST="10.1.10.129"
DNS_ROOT_PASS='VMware1234!'   # Update if your lab uses a different password
AVI_FQDN="avi-controller01.site-a.vcf.lab"
AVI_IP="10.1.1.200"

# Ensure sshpass is installed
if ! command -v sshpass >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    sudo apt-get update -y && sudo apt-get install -y sshpass
  else
    echo "sshpass not found and apt-get not available" >&2
    exit 1
  fi
fi

# Disable xtrace to hide passwords if running in debug mode
XTRACE_OFF=0
if [[ "${TRACE:-0}" == "1" ]]; then
  set +x
  XTRACE_OFF=1
fi

echo "Connecting to K8s DNS node (${DNS_HOST}) to update dnsmasq..."

# Execute standard bash commands over SSH instead of PowerShell
sshpass -p "$DNS_ROOT_PASS" \
  ssh -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o PreferredAuthentications=password \
      -o PubkeyAuthentication=no \
      root@"${DNS_HOST}" \
      env AVI_IP="${AVI_IP}" AVI_FQDN="${AVI_FQDN}" bash -s <<'EOF'
set -euo pipefail

cd /holodeck-runtime/dnsmasq
FILE="dnsmasq_configmap.yaml"

if [[ ! -f "$FILE" ]]; then
    echo "Error: $FILE not found on the remote host!"
    exit 1
fi

echo "Modifying $FILE..."

# 1. Update dnsmasq.conf section (Idempotent check)
if ! grep -q "server=/lb.site-a.vcf.lab/10.4.100.2" "$FILE"; then
    # Use sed to append the lines immediately after 'dnsmasq.conf: |' 
    # The \x20 adds exactly 4 spaces to maintain YAML indentation
    sed -i '/dnsmasq\.conf:[[:space:]]*|/a \    server=/lb.site-a.vcf.lab/10.4.100.2\n    local=/lb.site-a.vcf.lab/' "$FILE"
    echo "  -> Added lb.site-a.vcf.lab forwarders to dnsmasq.conf"
else
    echo "  -> Forwarders already exist in dnsmasq.conf. Skipping."
fi

# 2. Update hosts section (Idempotent check)
if ! grep -q "$AVI_FQDN" "$FILE"; then
    # Use sed to append the IP and FQDN immediately after 'hosts: |'
    sed -i "/hosts:[[:space:]]*|/a \    ${AVI_IP} ${AVI_FQDN}" "$FILE"
    echo "  -> Added ${AVI_FQDN} to hosts list"
else
    echo "  -> ${AVI_FQDN} already exists in hosts list. Skipping."
fi

# 3. Apply the ConfigMap
echo "Applying new ConfigMap to the cluster..."
kubectl apply -f "$FILE"

# 4. Find and delete the dnsmasq pod to force a reload
POD_NAME=$(kubectl get pods -n default | grep dnsmasq | awk '{print $1}' | head -n 1)

if [[ -n "$POD_NAME" ]]; then
    echo "Deleting pod $POD_NAME to load new config..."
    kubectl delete pod "$POD_NAME" -n default
    echo "DNS update complete!"
else
    echo "Warning: Could not find a running dnsmasq pod to restart."
fi
EOF

# Re-enable xtrace if we turned it off
if [[ "$XTRACE_OFF" -eq 1 ]]; then set -x; fi

echo "[+] Success: DNS record logic complete for ${AVI_IP} ${AVI_FQDN}"
