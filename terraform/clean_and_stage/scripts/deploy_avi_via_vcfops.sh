#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# Variables
# ==========================================
SDDC_MGR_IP="10.1.1.5"             
SDDC_USER="administrator@vsphere.local"
SDDC_PASS="VMware123!VMware123!"        

DOMAIN_NAME="mgmt-a"                

AVI_VERSION="32.1.1.25377988"      
AVI_ADMIN_PASS="VMware123!VMware123!"  
AVI_FQDN="avi-controller01.site-a.vcf.lab"
AVI_IP="10.1.1.200"

MGMT_NETWORK_NAME="mgmt-vds01-wld01-01a" 
MGMT_SUBNET_MASK="255.255.255.0"
MGMT_GATEWAY="10.1.1.1"

# Disable xtrace to hide passwords if running in debug mode
XTRACE_OFF=0
if [[ "${TRACE:-0}" == "1" ]]; then
  set +x
  XTRACE_OFF=1
fi

echo "[*] Authenticating to SDDC Manager API at ${SDDC_MGR_IP}..."

# ==========================================
# 1. Fetch SDDC Manager Bearer Token
# ==========================================
TOKEN_RESP=$(curl -s -k -X POST "https://${SDDC_MGR_IP}/v1/tokens" \
  -H "Content-Type: application/json" \
  -d '{
    "username": "'"${SDDC_USER}"'",
    "password": "'"${SDDC_PASS}"'"
  }')

TOKEN=$(echo "$TOKEN_RESP" | jq -r '.accessToken' 2>/dev/null || true)

if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
  echo "[-] FATAL: Failed to authenticate to SDDC Manager."
  echo "    Response: $TOKEN_RESP"
  exit 1
fi
echo "  [+] Successfully authenticated."

# ==========================================
# 2. Look up the Workload Domain ID
# ==========================================
echo "[*] Looking up Domain ID for '${DOMAIN_NAME}'..."

DOMAIN_RESP=$(curl -s -k -X GET "https://${SDDC_MGR_IP}/v1/domains" \
  -H "Authorization: Bearer ${TOKEN}")

DOMAIN_ID=$(echo "$DOMAIN_RESP" | jq -r --arg name "$DOMAIN_NAME" '.elements[] | select(.name == $name) | .id')

if [[ -z "$DOMAIN_ID" || "$DOMAIN_ID" == "null" ]]; then
  echo "[-] FATAL: Could not find Domain ID for ${DOMAIN_NAME}."
  exit 1
fi
echo "  [+] Found Domain ID: $DOMAIN_ID"

# ==========================================
# 3. Construct the 1-Node Avi JSON Spec
# ==========================================
echo "[*] Generating 1-Node Avi Deployment Specification..."

# Note: For a 1-node deployment, the cluster IP/FQDN are safely set to the node's exact IP/FQDN
cat <<EOF > /tmp/avi_single_node_spec.json
{
  "loadBalancerName": "wld01-nsx-alb",
  "domainId": "$DOMAIN_ID",
  "version": "$AVI_VERSION",
  "formFactor": "SMALL",
  "clusterFqdn": "$AVI_FQDN",
  "clusterIpAddress": "$AVI_IP",
  "adminPassword": "$AVI_ADMIN_PASS",
  "nodes": [
    {
      "fqdn": "$AVI_FQDN",
      "ipAddress": "$AVI_IP",
      "networkName": "$MGMT_NETWORK_NAME",
      "subnetMask": "$MGMT_SUBNET_MASK",
      "gateway": "$MGMT_GATEWAY"
    }
  ]
}
EOF

# ==========================================
# 4. Trigger the Deployment API
# ==========================================
echo "[*] Sending Deployment Request to SDDC Manager..."

DEPLOY_RESP=$(curl -s -k -w "\n%{http_code}" -X POST "https://${SDDC_MGR_IP}/v1/load-balancers" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d @/tmp/avi_single_node_spec.json)

HTTP_CODE=$(echo "$DEPLOY_RESP" | tail -n1)
RESPONSE_BODY=$(echo "$DEPLOY_RESP" | sed '$d')

if [[ "$HTTP_CODE" != "200" && "$HTTP_CODE" != "202" ]]; then
  echo "[-] FATAL: SDDC Manager rejected the deployment request (HTTP $HTTP_CODE)."
  echo "    API Response: $RESPONSE_BODY"
  rm -f /tmp/avi_single_node_spec.json
  exit 1
fi

TASK_ID=$(echo "$RESPONSE_BODY" | jq -r '.id')
echo "  [+] Deployment successfully triggered! Task ID: $TASK_ID"

# ==========================================
# 5. Poll the Task Status
# ==========================================
echo "[*] Monitoring SDDC Manager Task Execution..."
echo "    (This will take approximately 15-30 minutes for the OVA deployment and initial configuration)"

while true; do
  TASK_RESP=$(curl -s -k -X GET "https://${SDDC_MGR_IP}/v1/tasks/${TASK_ID}" \
    -H "Authorization: Bearer ${TOKEN}")
  
  TASK_STATUS=$(echo "$TASK_RESP" | jq -r '.status')
  
  if [[ "$TASK_STATUS" == "Successful" ]]; then
    echo -e "\n[+] Success: Avi Controller is fully deployed and registered with VCF!"
    break
  elif [[ "$TASK_STATUS" == "Failed" || "$TASK_STATUS" == "Failed with exceptions" ]]; then
    echo -e "\n[-] FATAL: Deployment failed in SDDC Manager!"
    # Extract the error message string from the API
    ERROR_MSG=$(echo "$TASK_RESP" | jq -r '.errors[0].message' 2>/dev/null || echo "Unknown Error")
    echo "    Reason: $ERROR_MSG"
    exit 1
  else
    printf "."
    sleep 30
  fi
done

# Cleanup
rm -f /tmp/avi_single_node_spec.json
if [[ "$XTRACE_OFF" -eq 1 ]]; then set -x; fi

echo "[+] Step 5 Complete."
