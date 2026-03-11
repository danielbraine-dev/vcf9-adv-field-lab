#!/usr/bin/env bash
set -euo pipefail

VCFA_URL="${1}"
VCFA_TOKEN="${2}"
NSX_HOST="${3}"
NSX_USER="${4}"
NSX_PASS="${5}"

log()   { printf "\n\033[1;36m%s\033[0m\n" "$*"; }
warn()  { printf "\n\033[1;33m%s\033[0m\n" "$*"; }

log "Authenticating to VCFA ($VCFA_URL)..."
BEARER_TOKEN=$(curl -sk -X POST "${VCFA_URL}/iaas/api/login" \
  -H "Content-Type: application/json" \
  -d "{\"refreshToken\": \"${VCFA_TOKEN}\"}" | jq -r .token)

[[ "$BEARER_TOKEN" == "null" || -z "$BEARER_TOKEN" ]] && { echo "[-] VCFA Login failed! Check your token."; exit 1; }

##################################################
# 1. VCFA: Update IP Space (Idempotent)
##################################################
log "Enforcing VCFA IP Space state..."
curl -sk -H "Authorization: Bearer ${BEARER_TOKEN}" "${VCFA_URL}/iaas/api/network-ip-spaces" > /tmp/vcfa_spaces.json

# IDEMPOTENT SEARCH: Look for EITHER the old default name OR our new desired name
SPACE_ID=$(jq -r '(.content // .results)[]? | select(.name=="us-west-region-Default IP Space" or .name=="us-east-region-IP Space" or .display_name=="us-west-region-Default IP Space" or .display_name=="us-east-region-IP Space") | .id' /tmp/vcfa_spaces.json | head -n1)

if [[ -n "$SPACE_ID" ]]; then
    curl -sk -H "Authorization: Bearer ${BEARER_TOKEN}" "${VCFA_URL}/iaas/api/network-ip-spaces/${SPACE_ID}" > /tmp/vcfa_space.json
    
    # Forcefully overwrite the payload with our desired end-state every time
    jq '(.name = "us-east-region-IP Space") | (.display_name = "us-east-region-IP Space") | (.cidr = "10.1.0.0/26")' /tmp/vcfa_space.json > /tmp/vcfa_space_updated.json
    
    curl -sk -X PUT -H "Authorization: Bearer ${BEARER_TOKEN}" -H "Content-Type: application/json" -d @/tmp/vcfa_space_updated.json "${VCFA_URL}/iaas/api/network-ip-spaces/${SPACE_ID}" > /dev/null
    echo "[+] VCFA IP Space state enforced (us-east-region-IP Space, 10.1.0.0/26)."
else
    warn "[-] Could not locate target IP Space by old or new name. Moving on."
fi

##################################################
# 2. VCFA: Update Provider Gateway (Idempotent)
##################################################
log "Enforcing VCFA Provider Gateway state..."
curl -sk -H "Authorization: Bearer ${BEARER_TOKEN}" "${VCFA_URL}/iaas/api/provider-gateways" > /tmp/vcfa_pgs.json

# IDEMPOTENT SEARCH: Look for EITHER the old default name OR our new desired name
PG_ID=$(jq -r '(.content // .results)[]? | select(.name=="us-west-region-Default Provider Gateway" or .name=="us-east-region-PG" or .display_name=="us-west-region-Default Provider Gateway" or .display_name=="us-east-region-PG") | .id' /tmp/vcfa_pgs.json | head -n1)

if [[ -n "$PG_ID" ]]; then
    curl -sk -H "Authorization: Bearer ${BEARER_TOKEN}" "${VCFA_URL}/iaas/api/provider-gateways/${PG_ID}" > /tmp/vcfa_pg.json
    
    # Forcefully overwrite the name to the desired end-state
    jq '(.name = "us-east-region-PG") | (.display_name = "us-east-region-PG")' /tmp/vcfa_pg.json > /tmp/vcfa_pg_updated.json
    
    curl -sk -X PUT -H "Authorization: Bearer ${BEARER_TOKEN}" -H "Content-Type: application/json" -d @/tmp/vcfa_pg_updated.json "${VCFA_URL}/iaas/api/provider-gateways/${PG_ID}" > /dev/null
    echo "[+] VCFA Provider Gateway state enforced (us-east-region-PG)."
else
    warn "[-] Could not locate target Provider Gateway by old or new name. Moving on."
fi

##################################################
# 3. Wait & NSX-T: Update VPC Profile (Idempotent)
##################################################
log "Waiting 15 seconds to ensure VCFA syncs state down to NSX-T..."
sleep 15

log "Enforcing NSX-T VPC Profile state..."
# Find the dynamically synced IP Space in NSX using our desired name
curl -sk -u "${NSX_USER}:${NSX_PASS}" "https://${NSX_HOST}/policy/api/v1/infra/ip-spaces" > /tmp/nsx_spaces.json
NSX_SPACE_PATH=$(jq -r '.results[] | select(.display_name=="us-east-region-IP Space") | .path' /tmp/nsx_spaces.json | head -n1)

[[ -z "$NSX_SPACE_PATH" ]] && { echo "[-] Failed to find the synced us-east-region-IP Space in NSX-T! VCFA sync may be delayed."; exit 1; }

curl -sk -u "${NSX_USER}:${NSX_PASS}" "https://${NSX_HOST}/policy/api/v1/orgs/default/projects/default/vpc-connectivity-profiles" > /tmp/nsx_profiles.json
PROFILE_ID=$(jq -r '.results[] | select(.display_name=="Default VPC Connectivity Profile" or .display_name=="default") | .id' /tmp/nsx_profiles.json | head -n1)

if [[ -n "$PROFILE_ID" ]]; then
    curl -sk -u "${NSX_USER}:${NSX_PASS}" "https://${NSX_HOST}/policy/api/v1/orgs/default/projects/default/vpc-connectivity-profiles/${PROFILE_ID}" > /tmp/nsx_profile.json
    
    # Overwrite the external IP space array with our target path. If it's already there, this changes nothing.
    jq --arg path "$NSX_SPACE_PATH" '.external_ip_space_paths = [$path]' /tmp/nsx_profile.json > /tmp/nsx_profile_updated.json
    
    curl -sk -X PUT -u "${NSX_USER}:${NSX_PASS}" -H "Content-Type: application/json" -d @/tmp/nsx_profile_updated.json "https://${NSX_HOST}/policy/api/v1/orgs/default/projects/default/vpc-connectivity-profiles/${PROFILE_ID}" > /dev/null
    echo "[+] NSX-T VPC Profile mapping enforced!"
fi

# Clean up
rm -f /tmp/vcfa_*.json /tmp/nsx_*.json
