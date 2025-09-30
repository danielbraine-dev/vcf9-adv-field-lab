#!/usr/bin/env bash
set -euo pipefail

# --- Inputs you know by name (used for import keys) ---
ORG_ID="${ORG_ID:?set ORG_ID}"
REGION_ID="${REGION_ID:?set REGION_ID}"

NS_NAME="${NS_NAME:-}"                       # e.g. demo-namespace
ORG_CL_NAME="${ORG_CL_NAME:-}"               # org content library name
PROVIDER_GW_NAME="${PROVIDER_GW_NAME:-}"     # provider gateway display name
IP_SPACE_NAME="${IP_SPACE_NAME:-}"           # provider IP space display name
ORG_REG_NET_NAME="${ORG_REG_NET_NAME:-}"     # org regional networking display name
REGION_NAME="${REGION_NAME:-}"               # region display name

# --- Helpers ---
show() { terraform state show -no-color "$1" 2>/dev/null || true; }
grab() { awk -F' = ' -v k="$1" '$1 ~ ("^ *"k" *$"){print $2}' | sed -e 's/^"//' -e 's/"$//' ; }

# JSON accumulators
TMP_JSON="/tmp/vcfa-imported.auto.tfvars.json"
IPSPACE_BLOCKS="/tmp/vcfa-ipspace-internal-scope.txt"
: >"$TMP_JSON"
: >"$IPSPACE_BLOCKS"

echo "{" >>"$TMP_JSON"

# (1) Supervisor Namespace
if [[ -n "${NS_NAME}" ]]; then
  terraform import -allow-missing-config 'vcfa_supervisor_namespace.project_ns' "${ORG_ID}/${REGION_ID}/${NS_NAME}" || true
  echo "  \"vcfa_ns_name\": \"${NS_NAME}\"," >>"$TMP_JSON"
fi

# (2) Org CL
if [[ -n "${ORG_CL_NAME}" ]]; then
  terraform import -allow-missing-config 'vcfa_content_library.org_cl' "${ORG_ID}/${ORG_CL_NAME}" || true
  CL_SHOW="$(show vcfa_content_library.org_cl)"
  # storage_class_ids is a list
  CL_SCS="$(printf "%s\n" "$CL_SHOW" | awk '/^ *storage_class_ids *= *\[/,/^ *\]/')"
  if [[ -n "$CL_SCS" ]]; then
    echo "  \"vcfa_org_cl_name\": \"${ORG_CL_NAME}\"," >>"$TMP_JSON"
    echo "  \"vcfa_org_cl_storage_class_ids\": $(printf "%s" "$CL_SCS" | sed 's/ *= */: /;1s/ *= */: /')," >>"$TMP_JSON"
  fi
fi

# (3) Provider Gateway
if [[ -n "${PROVIDER_GW_NAME}" ]]; then
  terraform import -allow-missing-config 'vcfa_provider_gateway.us_west' "${REGION_ID}/${PROVIDER_GW_NAME}" || true
  PG_SHOW="$(show vcfa_provider_gateway.us_west)"
  T0_ID="$(printf "%s" "$PG_SHOW" | grab tier0_gateway_id)"
  IP_SPACES="$(printf "%s" "$PG_SHOW" | awk '/^ *ip_space_ids *= *\[/,/^ *\]/')"
  echo "  \"vcfa_provider_gw_name\": \"${PROVIDER_GW_NAME}\"," >>"$TMP_JSON"
  [[ -n "$T0_ID" ]]  && echo "  \"vcfa_tier0_gateway_id\": \"${T0_ID}\"," >>"$TMP_JSON"
  [[ -n "$IP_SPACES" ]] && echo "  \"vcfa_ip_space_ids\": $(printf "%s" "$IP_SPACES" | sed 's/ *= */: /;1s/ *= */: /')," >>"$TMP_JSON"
fi

# (4) Provider IP Space
if [[ -n "${IP_SPACE_NAME}" ]]; then
  terraform import -allow-missing-config 'vcfa_ip_space.us_west' "${IP_SPACE_NAME}" || true
  IS_SHOW="$(show vcfa_ip_space.us_west)"
  MAX_IP="$(printf "%s" "$IS_SHOW" | grab default_quota_max_ip_count)"
  MAX_SUBNET="$(printf "%s" "$IS_SHOW" | grab default_quota_max_subnet_size)"
  MAX_CIDR="$(printf "%s" "$IS_SHOW" | grab default_quota_max_cidr_count)"
  echo "  \"vcfa_ip_space_name\": \"${IP_SPACE_NAME}\"," >>"$TMP_JSON"
  [[ -n "$MAX_IP"     ]] && echo "  \"vcfa_default_quota_max_ip_count\": ${MAX_IP}," >>"$TMP_JSON"
  [[ -n "$MAX_SUBNET" ]] && echo "  \"vcfa_default_quota_max_subnet_size\": ${MAX_SUBNET}," >>"$TMP_JSON"
  [[ -n "$MAX_CIDR"   ]] && echo "  \"vcfa_default_quota_max_cidr_count\": ${MAX_CIDR}," >>"$TMP_JSON"

  # Capture required internal_scope { ... } blocks
  printf "%s\n" "$IS_SHOW" | awk '/^ *internal_scope *{/,/^ *}/' > "$IPSPACE_BLOCKS" || true
fi

# (5) Org Region Quota (no extra fields)
echo "  \"vcfa_org_id\": \"${ORG_ID}\","   >>"$TMP_JSON"
echo "  \"vcfa_region_id\": \"${REGION_ID}\"," >>"$TMP_JSON"

# (6) Org Regional Networking
if [[ -n "${ORG_REG_NET_NAME}" ]]; then
  terraform import -allow-missing-config 'vcfa_org_regional_networking.showcase_us_west' "${ORG_ID}/${REGION_ID}/${ORG_REG_NET_NAME}" || true
  ORN_SHOW="$(show vcfa_org_regional_networking.showcase_us_west)"
  PGW_ID="$(printf "%s" "$ORN_SHOW" | grab provider_gateway_id)"
  echo "  \"vcfa_org_reg_net_name\": \"${ORG_REG_NET_NAME}\"," >>"$TMP_JSON"
  [[ -n "$PGW_ID" ]] && echo "  \"vcfa_provider_gateway_id\": \"${PGW_ID}\"," >>"$TMP_JSON"
fi

# (7) Region
if [[ -n "${REGION_NAME}" ]]; then
  terraform import -allow-missing-config 'vcfa_region.us_west' "${REGION_NAME}" || true
  R_SHOW="$(show vcfa_region.us_west)"
  NSX_MGR_ID="$(printf "%s" "$R_SHOW" | grab nsx_manager_id)"
  SPN="$(printf "%s" "$R_SHOW" | awk '/^ *storage_policy_names *= *\[/,/^ *\]/')"
  SUPS="$(printf "%s" "$R_SHOW" | awk '/^ *supervisor_ids *= *\[/,/^ *\]/')"
  echo "  \"vcfa_region_name\": \"${REGION_NAME}\"," >>"$TMP_JSON"
  [[ -n "$NSX_MGR_ID" ]] && echo "  \"vcfa_nsx_manager_id\": \"${NSX_MGR_ID}\"," >>"$TMP_JSON"
  [[ -n "$SPN" ]] && echo "  \"vcfa_storage_policy_names\": $(printf "%s" "$SPN" | sed 's/ *= */: /;1s/ *= */: /')," >>"$TMP_JSON"
  [[ -n "$SUPS" ]] && echo "  \"vcfa_supervisor_ids\": $(printf "%s" "$SUPS" | sed 's/ *= */: /;1s/ *= */: /')," >>"$TMP_JSON"
fi

# Trim trailing comma and close JSON
# (simple: add dummy and then clean with sed)
echo "  \"_done\": true" >>"$TMP_JSON"
sed -i 's/, *"_done": true/"_done": true/' "$TMP_JSON"
echo "}" >>"$TMP_JSON"

echo
echo "Wrote: $TMP_JSON"
echo "Now copy the internal_scope block(s) into vcfa_ip_space.us_west:"
echo "---------------------------------------------------------------"
if [[ -s "$IPSPACE_BLOCKS" ]]; then
  cat "$IPSPACE_BLOCKS"
else
  echo "(No internal_scope found—double-check the IP space state.)"
fi
