#!/usr/bin/env bash
set -euo pipefail

VC_FQDN="$(awk -F= '/vsphere_server/{gsub(/"| /,"",$2);print $2}' terraform.tfvars)"
VC_USER="$(awk -F= '/vsphere_user/{gsub(/"| /,"",$2);print $2}' terraform.tfvars)"
VC_PASS="$(awk -F= '/vsphere_password/{gsub(/"| /,"",$2);print $2}' terraform.tfvars)"
CLUSTER_NAME="$(awk -F= '/vsphere_cluster/{gsub(/"| /,"",$2);print $2}' terraform.tfvars)"

[[ -z "$VC_FQDN" || -z "$VC_USER" || -z "$VC_PASS" || -z "$CLUSTER_NAME" ]] && { echo "Missing vCenter creds or cluster name"; exit 1; }

base="https://${VC_FQDN}"
SESSION=$(curl -sk -X POST -u "${VC_USER}:${VC_PASS}" "${base}/api/session")
[[ -z "$SESSION" ]] && { echo "vCenter auth failed"; exit 1; }
authH="vmware-api-session-id: ${SESSION}"

# Lookup cluster moid
CLUSTER_ID=$(curl -sk -H "$authH" "${base}/api/vcenter/cluster?filter.names=${CLUSTER_NAME}" | jq -r '.[0].cluster')
[[ -z "$CLUSTER_ID" || "$CLUSTER_ID" == "null" ]] && { echo "Cluster not found: $CLUSTER_NAME"; exit 1; }

# Build enable spec from terraform.tfvars (you may need to adjust keys per your vCenter build)
# NOTE: This is a skeleton; supply storage policies, dvSwitch ID, edge cluster, T0, etc.
cat > /tmp/nsx_wld_enable_spec.json <<'JSON'
{
  "cluster": "__CLUSTER_ID__",
  "size": "TINY",
  "workload_network": {
    "nsx_projects": [{ "name": "__NSX_PROJECT__" }],
    "vpc_connectivity_profile": "__VPC_PROFILE__",
    "external_ip_blocks": [{
      "name": "__EXT_BLOCK_NAME__",
      "cidr": "__EXT_BLOCK_CIDR__",
      "range": "__EXT_BLOCK_RANGE__"
    }],
    "transit_gateway_ip_blocks": [{
      "name": "__TGW_BLOCK_NAME__",
      "cidr": "__TGW_BLOCK_CIDR__",
      "range": "__TGW_BLOCK_RANGE__"
    }],
    "vpc_cidrs": __VPC_CIDRS__,
    "service_cidr": "__SERVICE_CIDR__",
    "dns_servers": __DNS__,
    "ntp_servers": __NTP__
  },
  "management_network": {
    "mode": "STATICRANGE",
    "address_range": "__MGMT_RANGE__",
    "subnet_mask": "__MGMT_MASK__",
    "gateway": "__MGMT_GW__",
    "dns_servers": __DNS__,
    "search_domains": [ "__DNS_SEARCH__" ],
    "ntp_servers": __NTP__
  }
}
JSON

# replace tokens with tfvars values
MGMT_RANGE="$(awk -F= '/sup_mgmt_ip_range/{gsub(/"| /,"",$2);print $2}' terraform.tfvars)"
MGMT_MASK="$(awk -F= '/sup_mgmt_netmask/{gsub(/"| /,"",$2);print $2}' terraform.tfvars)"
MGMT_GW="$(awk -F= '/sup_mgmt_gateway/{gsub(/"| /,"",$2);print $2}' terraform.tfvars)"
DNS_JSON="$(awk -F= '/sup_dns_servers/{print $2}' terraform.tfvars)"
NTP_JSON="$(awk -F= '/sup_ntp_servers/{print $2}' terraform.tfvars)"
DNS_SEARCH="$(awk -F= '/sup_dns_search/{gsub(/"| /,"",$2);print $2}' terraform.tfvars)"
NSX_PROJECT="$(awk -F= '/nsx_project_name/{gsub(/"| /,"",$2);print $2}' terraform.tfvars)"
VPC_PROFILE="$(awk -F= '/nsx_vpc_connectivity_profile/{gsub(/"| /,"",$2);print $2}' terraform.tfvars)"
EXT_BLOCK_NAME="$(awk -F= '/ext_ipblock_name/{gsub(/"| /,"",$2);print $2}' terraform.tfvars)"
EXT_BLOCK_CIDR="$(awk -F= '/ext_ipblock_cidr/{gsub(/"| /,"",$2);print $2}' terraform.tfvars)"
EXT_BLOCK_RANGE="$(awk -F= '/ext_ipblock_range/{gsub(/"| /,"",$2);print $2}' terraform.tfvars)"
TGW_BLOCK_NAME="$(awk -F= '/tgw_ipblock_name/{gsub(/"| /,"",$2);print $2}' terraform.tfvars)"
TGW_BLOCK_CIDR="$(awk -F= '/tgw_ipblock_cidr/{gsub(/"| /,"",$2);print $2}' terraform.tfvars)"
TGW_BLOCK_RANGE="$(awk -F= '/tgw_ipblock_range/{gsub(/"| /,"",$2);print $2}' terraform.tfvars)"
VPC_CIDRS_JSON="$(awk -F= '/workload_vpc_cidrs/{print $2}' terraform.tfvars)"
SERVICE_CIDR="$(awk -F= '/service_cidr/{gsub(/"| /,"",$2);print $2}' terraform.tfvars)"

sed -i "s#__CLUSTER_ID__#${CLUSTER_ID}#g" /tmp/nsx_wld_enable_spec.json
sed -i "s#__MGMT_RANGE__#${MGMT_RANGE}#g" /tmp/nsx_wld_enable_spec.json
sed -i "s#__MGMT_MASK__#${MGMT_MASK}#g" /tmp/nsx_wld_enable_spec.json
sed -i "s#__MGMT_GW__#${MGMT_GW}#g" /tmp/nsx_wld_enable_spec.json
sed -i "s#__DNS__#${DNS_JSON}#g" /tmp/nsx_wld_enable_spec.json
sed -i "s#__NTP__#${NTP_JSON}#g" /tmp/nsx_wld_enable_spec.json
sed -i "s#__DNS_SEARCH__#${DNS_SEARCH}#g" /tmp/nsx_wld_enable_spec.json
sed -i "s#__NSX_PROJECT__#${NSX_PROJECT}#g" /tmp/nsx_wld_enable_spec.json
sed -i "s#__VPC_PROFILE__#${VPC_PROFILE}#g" /tmp/nsx_wld_enable_spec.json
sed -i "s#__EXT_BLOCK_NAME__#${EXT_BLOCK_NAME}#g" /tmp/nsx_wld_enable_spec.json
sed -i "s#__EXT_BLOCK_CIDR__#${EXT_BLOCK_CIDR}#g" /tmp/nsx_wld_enable_spec.json
sed -i "s#__EXT_BLOCK_RANGE__#${EXT_BLOCK_RANGE}#g" /tmp/nsx_wld_enable_spec.json
sed -i "s#__TGW_BLOCK_NAME__#${TGW_BLOCK_NAME}#g" /tmp/nsx_wld_enable_spec.json
sed -i "s#__TGW_BLOCK_CIDR__#${TGW_BLOCK_CIDR}#g" /tmp/nsx_wld_enable_spec.json
sed -i "s#__TGW_BLOCK_RANGE__#${TGW_BLOCK_RANGE}#g" /tmp/nsx_wld_enable_spec.json
sed -i "s#__VPC_CIDRS__#${VPC_CIDRS_JSON}#g" /tmp/nsx_wld_enable_spec.json
sed -i "s#__SERVICE_CIDR__#${SERVICE_CIDR}#g" /tmp/nsx_wld_enable_spec.json

echo "Submitting Supervisor enable request…"
# POST /api/vcenter/namespace-management/clusters/{cluster}?action=enable
curl -sk -X POST -H "vmware-api-session-id: ${SESSION}" \
  -H "Content-Type: application/json" \
  -d @/tmp/nsx_wld_enable_spec.json \
  "${base}/api/vcenter/namespace-management/clusters/${CLUSTER_ID}?action=enable"

echo "Enable request submitted. Monitor vCenter for progress."
