#!/usr/bin/env bash
set -euo pipefail

# ---------- CONFIG (override via env) ----------
: "${VCFA_URL:?Set VCFA_URL (e.g., https://vcfa.provider.lab)}"
: "${VCFA_ORG:?Set VCFA_ORG (e.g., showcase-all-apps)}"

# One of: password-based OIDC/OAuth OR already have a bearer
# For OIDC password grant flow (common in lab/airgapped setups):
: "${VCFA_USER:=}"          # username for bootstrap
: "${VCFA_PASSWORD:=}"      # password for bootstrap
: "${VCFA_OIDC_REALM:=}"    # if set, uses /realms/<realm>/protocol/openid-connect/token

# Endpoints — override if your VCFA differs
: "${VCFA_AUTH_PATH:=/oauth/token}"             # used when VCFA_OIDC_REALM is empty
: "${VCFA_CREATE_TOKEN_PATH:=/api/tokens}"      # API endpoint to create a long-lived API token
: "${VCFA_TEST_PATH:=/api/orgs}"                # a harmless GET to verify token works

# Token “metadata” when creating the long-lived API token
: "${VCFA_TOKEN_NAME:=tf-bootstrap}"
: "${VCFA_TOKEN_TTL_DAYS:=90}"

# Storage/Injection
: "${VCFA_TOKEN_FILE:=${HOME}/.secrets/vcfa.token}"   # file to store the minted API token
: "${PROJECT_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TF_SECRETS="${PROJECT_ROOT}/secrets.auto.tfvars.json"

# TLS
: "${VCFA_ALLOW_UNVERIFIED_SSL:=1}"             # 1 = allow; 0 = verify
CURL_INSECURE=()
[[ "${VCFA_ALLOW_UNVERIFIED_SSL}" == "1" ]] && CURL_INSECURE=(-k)

req() { curl -sS "${CURL_INSECURE[@]}" "$@"; }

# ---------- Resolve token URL ----------
if [[ -n "${VCFA_OIDC_REALM}" ]]; then
  TOKEN_URL="${VCFA_URL%/}/realms/${VCFA_OIDC_REALM}/protocol/openid-connect/token"
else
  TOKEN_URL="${VCFA_URL%/}${VCFA_AUTH_PATH}"
fi

CREATE_TOKEN_URL="${VCFA_URL%/}${VCFA_CREATE_TOKEN_PATH}"
TEST_URL="${VCFA_URL%/}${VCFA_TEST_PATH}"

# ---------- Get short-lived bearer via password grant (if user/pass provided) ----------
ACCESS_TOKEN=""
if [[ -n "${VCFA_USER}" && -n "${VCFA_PASSWORD}" ]]; then
  echo "→ Requesting access token from: ${TOKEN_URL}"
  # Most OIDC servers accept x-www-form-urlencoded password grant.
  # Adjust client_id/scope if your environment requires it.
  ACCESS_TOKEN="$(req -X POST \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data "grant_type=password&username=${VCFA_USER}&password=${VCFA_PASSWORD}&scope=openid offline_access" \
    "${TOKEN_URL}" | jq -r '.access_token // empty')"

  if [[ -z "${ACCESS_TOKEN}" ]]; then
    echo "!! Failed to obtain access token. Check TOKEN_URL / credentials / grant type." >&2
    exit 1
  fi
  echo "✓ Access token acquired"
fi

# ---------- Create a long-lived API token in VCFA ----------
# If your VCFA requires a different body shape, tweak here.
echo "→ Creating long-lived API token at: ${CREATE_TOKEN_URL}"
API_TOKEN="$(
  req -X POST \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    --data @- "${CREATE_TOKEN_URL}" <<EOF | jq -r '.token // .value // .apiToken // empty'
{
  "name": "${VCFA_TOKEN_NAME}",
  "expiresInDays": ${VCFA_TOKEN_TTL_DAYS},
  "org": "${VCFA_ORG}"
}
EOF
)"

if [[ -z "${API_TOKEN}" ]]; then
  echo "!! Failed to create API token. Adjust VCFA_CREATE_TOKEN_PATH or JSON body field names." >&2
  exit 1
fi
echo "✓ API token minted"

# ---------- Store token safely ----------
mkdir -p "$(dirname "${VCFA_TOKEN_FILE}")"
umask 177
printf "%s" "${API_TOKEN}" > "${VCFA_TOKEN_FILE}"
chmod 600 "${VCFA_TOKEN_FILE}"
echo "✓ Saved API token to ${VCFA_TOKEN_FILE}"

# ---------- Verify token works ----------
HTTP_CODE="$(curl -sS -o /dev/null -w "%{http_code}" "${CURL_INSECURE[@]}" \
  -H "Authorization: Bearer ${API_TOKEN}" "${TEST_URL}")"
if [[ "${HTTP_CODE}" != "200" && "${HTTP_CODE}" != "204" ]]; then
  echo "!! Token verification failed (GET ${TEST_URL} => ${HTTP_CODE}). Token might still be valid for Terraform, but check endpoint." >&2
else
  echo "✓ Token verified against ${TEST_URL} (${HTTP_CODE})"
fi

# ---------- Inject into Terraform (provider uses token auth) ----------
cat > "${TF_SECRETS}" <<EOF
{
  "vcfa_url": "${VCFA_URL}",
  "vcfa_org": "${VCFA_ORG}",
  "vcfa_auth_type": "token",
  "vcfa_token": "${API_TOKEN}",
  "vcfa_allow_unverified_ssl": ${VCFA_ALLOW_UNVERIFIED_SSL}
}
EOF

echo "✓ Wrote Terraform injection: ${TF_SECRETS}"
echo "All done."
