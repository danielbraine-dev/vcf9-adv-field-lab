#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# Variables
# ==========================================
TECH_URL="http://technitium.vcf.lab:5380"  # Update to https://technitium.vcf.lab if SSL is enabled
TECH_USER="admin"
TECH_PASS='VMware123!VMware123!'                    # Update if your lab uses a different password

AVI_FQDN="avi-controller01.site-a.vcf.lab"
AVI_IP="10.1.1.200"

LB_ZONE="lb.site-a.vcf.lab"
LB_FORWARDER_IP="10.4.100.2"

echo "[*] Connecting to Technitium DNS API at ${TECH_URL}..."

# Disable xtrace to hide passwords if running in debug mode
XTRACE_OFF=0
if [[ "${TRACE:-0}" == "1" ]]; then
  set +x
  XTRACE_OFF=1
fi

# ==========================================
# 1. Authenticate to Technitium API
# ==========================================
# We use --data-urlencode for the password in case it contains special characters like '!'
LOGIN_RESP=$(curl -s -k -X POST "${TECH_URL}/api/user/login" \
  -d "user=${TECH_USER}" \
  --data-urlencode "pass=${TECH_PASS}")

LOGIN_STATUS=$(echo "$LOGIN_RESP" | jq -r '.status' 2>/dev/null || echo "failed")

if [[ "$LOGIN_STATUS" != "ok" ]]; then
    echo "[-] FATAL: Failed to authenticate to Technitium DNS."
    echo "    Response: $LOGIN_RESP"
    exit 1
fi

# Extract the API Token for subsequent requests
TOKEN=$(echo "$LOGIN_RESP" | jq -r '.token')
echo "  [+] Successfully authenticated to Technitium."

# ==========================================
# 2. Add Conditional Forwarder (Forwarder Zone)
# ==========================================
# This replaces the dnsmasq 'server=/lb.site-a.vcf.lab/10.4.100.2' logic
echo "[*] Configuring Conditional Forwarder for ${LB_ZONE} -> ${LB_FORWARDER_IP}..."

FWD_RESP=$(curl -s -k -X POST "${TECH_URL}/api/zones/create" \
  -d "token=${TOKEN}" \
  -d "zone=${LB_ZONE}" \
  -d "type=Forwarder" \
  -d "forwarder=${LB_FORWARDER_IP}")

FWD_STATUS=$(echo "$FWD_RESP" | jq -r '.status')
FWD_ERR=$(echo "$FWD_RESP" | jq -r '.errorMessage')

if [[ "$FWD_STATUS" == "ok" ]]; then
    echo "  [+] Success: Forwarder zone created."
elif [[ "$FWD_STATUS" == "error" && "$FWD_ERR" == *"already exists"* ]]; then
    echo "  [~] Forwarder zone already exists. Skipping."
else
    echo "  [-] Warning: Failed to create forwarder zone. Response: $FWD_RESP"
fi

# ==========================================
# 3. Add A Record for Avi Controller
# ==========================================
# This replaces adding the host to the dnsmasq hosts file
echo "[*] Configuring A Record for ${AVI_FQDN} -> ${AVI_IP}..."

A_REC_RESP=$(curl -s -k -X POST "${TECH_URL}/api/zones/records/add" \
  -d "token=${TOKEN}" \
  -d "domain=${AVI_FQDN}" \
  -d "type=A" \
  -d "ipAddress=${AVI_IP}")

A_REC_STATUS=$(echo "$A_REC_RESP" | jq -r '.status')
A_REC_ERR=$(echo "$A_REC_RESP" | jq -r '.errorMessage')

if [[ "$A_REC_STATUS" == "ok" ]]; then
    echo "  [+] Success: A Record created."
elif [[ "$A_REC_STATUS" == "error" && "$A_REC_ERR" == *"already exists"* ]]; then
    echo "  [~] A Record already exists. Skipping."
else
    echo "  [-] Warning: Failed to create A record. Response: $A_REC_RESP"
fi

# ==========================================
# 3b. Add PTR (Reverse Lookup) Record
# ==========================================
echo "[*] Configuring PTR Record for ${AVI_IP} -> ${AVI_FQDN}..."

# 1. Parse the IP to build the standard .in-addr.arpa zone and domain
IFS='.' read -r i1 i2 i3 i4 <<< "$AVI_IP"
REV_ZONE="${i3}.${i2}.${i1}.in-addr.arpa"
PTR_DOMAIN="${i4}.${REV_ZONE}"

# 2. Ensure the Reverse Zone exists in Technitium (Creates a Primary Zone)
REV_ZONE_RESP=$(curl -s -k -X POST "${TECH_URL}/api/zones/create" \
  -d "token=${TOKEN}" \
  -d "zone=${REV_ZONE}" \
  -d "type=Primary")

# 3. Inject the PTR Record
PTR_REC_RESP=$(curl -s -k -X POST "${TECH_URL}/api/zones/records/add" \
  -d "token=${TOKEN}" \
  -d "domain=${PTR_DOMAIN}" \
  -d "type=PTR" \
  -d "ptrName=${AVI_FQDN}")

PTR_REC_STATUS=$(echo "$PTR_REC_RESP" | jq -r '.status')
PTR_REC_ERR=$(echo "$PTR_REC_RESP" | jq -r '.errorMessage')

if [[ "$PTR_REC_STATUS" == "ok" ]]; then
    echo "  [+] Success: PTR Record created."
elif [[ "$PTR_REC_STATUS" == "error" && "$PTR_REC_ERR" == *"already exists"* ]]; then
    echo "  [~] PTR Record already exists. Skipping."
else
    echo "  [-] Warning: Failed to create PTR record. Response: $PTR_REC_RESP"
fi

# ==========================================
# 4. Add DHCP Scope for Avi SE Management
# ==========================================
echo "[*] Configuring DHCP Scope 'AVI SE Mgmt' (10.1.4.0/25)..."

# Using /api/dhcp/scopes/set creates the scope if it doesn't exist, or updates it if it does
DHCP_RESP=$(curl -s -k -X POST "${TECH_URL}/api/dhcp/scopes/set" \
  -d "token=${TOKEN}" \
  -d "name=AVI SE Mgmt" \
  -d "networkAddress=10.1.4.0" \
  -d "subnetMask=255.255.255.128" \
  -d "startIpAddress=10.1.4.2" \
  -d "endIpAddress=10.1.4.50" \
  -d "routerAddress=10.1.4.1" \
  -d "timeServerAddresses=10.1.1.1" \
  -d "dnsServerAddresses=10.1.1.1") 

DHCP_STATUS=$(echo "$DHCP_RESP" | jq -r '.status')
DHCP_ERR=$(echo "$DHCP_RESP" | jq -r '.errorMessage')

if [[ "$DHCP_STATUS" == "ok" ]]; then
    echo "  [+] Success: DHCP Scope created/updated."
elif [[ "$DHCP_STATUS" == "error" && "$DHCP_ERR" == *"already exists"* ]]; then
    echo "  [~] DHCP Scope already exists. Skipping."
else
    echo "  [-] Warning: Failed to configure DHCP scope. Response: $DHCP_RESP"
fi

# ==========================================
# 5. Logout / Invalidate Token
# ==========================================
curl -s -k -X POST "${TECH_URL}/api/user/logout" -d "token=${TOKEN}" >/dev/null

# Re-enable xtrace if we turned it off
if [[ "$XTRACE_OFF" -eq 1 ]]; then set -x; fi

echo "[+] Success: DNS record logic complete for ${AVI_IP} ${AVI_FQDN}"
