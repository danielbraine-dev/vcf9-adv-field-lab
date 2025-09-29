#!/usr/bin/env bash
set -euo pipefail

VC_FQDN="$(terraform output -raw vsphere_server 2>/dev/null || true)"
VC_FQDN="${VC_FQDN:-$(awk -F= '/vsphere_server/{gsub(/"| /,"",$2);print $2}' terraform.tfvars)}"
VC_USER="${VC_USER:-$(awk -F= '/vsphere_user/{gsub(/"| /,"",$2);print $2}' terraform.tfvars)}"
VC_PASS="${VC_PASS:-$(awk -F= '/vsphere_password/{gsub(/"| /,"",$2);print $2}' terraform.tfvars)}"
CLUSTER_NAME="${CLUSTER_NAME:-$(awk -F= '/vsphere_cluster/{gsub(/"| /,"",$2);print $2}' terraform.tfvars)}"

[[ -z "$VC_FQDN" || -z "$VC_USER" || -z "$VC_PASS" || -z "$CLUSTER_NAME" ]] && { echo "Missing vCenter creds or cluster name"; exit 1; }

base="https://${VC_FQDN}"
# 1) Session
SESSION=$(curl -sk -X POST -u "${VC_USER}:${VC_PASS}" "${base}/api/session")
[[ -z "$SESSION" ]] && { echo "vCenter auth failed"; exit 1; }
authH="vmware-api-session-id: ${SESSION}"

# 2) Lookup cluster id
CLUSTER_ID=$(curl -sk -H "$authH" "${base}/api/vcenter/cluster?filter.names=${CLUSTER_NAME}" | jq -r '.[0].cluster')
[[ -z "$CLUSTER_ID" || "$CLUSTER_ID" == "null" ]] && { echo "Cluster not found: $CLUSTER_NAME"; exit 1; }

echo "Disabling Supervisor on cluster ${CLUSTER_NAME} (${CLUSTER_ID})…"
# 3) Disable via namespace-management Clusters API
# POST /api/vcenter/namespace-management/clusters/{cluster}?action=disable
curl -sk -X POST -H "$authH" "${base}/api/vcenter/namespace-management/clusters/${CLUSTER_ID}?action=disable" -o /dev/null

echo "Requested disable. Polling state…"
for i in {1..60}; do
  state=$(curl -sk -H "$authH" "${base}/api/vcenter/namespace-management/clusters/${CLUSTER_ID}" | jq -r '.config_status // .state // empty')
  echo "  state=${state}"
  [[ "$state" == "DISABLED" || "$state" == "NOT_CONFIGURED" || "$state" == "null" || -z "$state" ]] && break
  sleep 10
done

echo "Supervisor disable request completed (check vCenter if lingering tasks remain)."
