#!/usr/bin/env bash
set -euo pipefail

# --------- Config via env ---------
: "${VCFA_URL:?set VCFA_URL (e.g. https://auto-a.site-a.vcf.lab)}"
: "${VCFA_ORG:?set VCFA_ORG (e.g. showcase-all-apps)}"
: "${VCFA_USER:?set VCFA_USER}"
: "${VCFA_PASSWORD:?set VCFA_PASSWORD}"

# Optional:
: "${VCFA_ALLOW_UNVERIFIED_SSL:=1}"             # 1 to skip TLS verify
: "${VCFA_OIDC_REALM:=}"                        # e.g. "vcfa" (Keycloak)
: "${VCFA_CLIENT_ID:=}"                         # if IdP requires client credentials
: "${VCFA_CLIENT_SECRET:=}"                     # if IdP requires client credentials
: "${VCFA_CREATE_TOKEN_PATH:=}"                 # e.g. "/api/tokens" if your VCFA exposes an API-token mint endpoint
: "${VCFA_TOKEN_NAME:=tf-bootstrap}"
: "${VCFA_TOKEN_TTL_DAYS:=30}"
: "${TF_OUT_DIR:=$(pwd)}"                       # where to write secrets.auto.tfvars.json

# --------- Helpers ---------
norm_url() { case "$1" in http://*|https://*) printf "%s" "$1" ;; *) printf "https://%s" "$1" ;; esac; }
JQ() { jq -e "$@" >/dev/null 2>&1; }            # test-only
curl_json() { curl -sS "${CURL_INSECURE[@]}" -H "Accept: application/json" "$@"; }
curl_head() { curl -sS -o /dev/null -w "%{http_code}" "${CURL_INSECURE[@]}" "$@"; }

[[ "${VCFA_ALLOW_UNVERIFIED_SSL}" == "1" ]] && CURL_INSECURE=(-k) || CURL_INSECURE=()

VCFA_URL="$(norm_url "${VCFA_URL}")"

echo "==> Discovering token endpoint from ${VCFA_URL}"

discover_token_endpoint() {
  local base="$1"

  # 1) Try top-level OIDC discovery
  local url="${base%/}/.well-known/openid-configuration"
  if [[ "$(curl_head "$url")" == "200" ]]; then
    local te
    te="$(curl_json "$url" | jq -r '.token_endpoint // empty' || true)"
    [[ -n "$te" ]] && { echo "$te"; return 0; }
  fi

  # 2) Try common Keycloak realms (including user-provided)
  local realms=()
  [[ -n "${VCFA_OIDC_REALM}" ]] && realms+=("${VCFA_OIDC_REALM}")
  realms+=("vcfa" "master" "default" "services" "system")
  for r in "${realms[@]}"; do
    url="${base%/}/realms/${r}/.well-known/openid-configuration"
    if [[ "$(curl_head "$url")" == "200" ]]; then
      local te
      te="$(curl_json "$url" | jq -r '.token_endpoint // empty' || true)"
      [[ -n "$te" ]] && { echo "$te"; return 0; }
    fi
  done

  # 3) Try well-known direct token endpoints we see in the wild
  for path in \
    "/oauth/token" \
    "/SAAS/auth/oauthtoken" \
    "/csp/gateway/am/api/auth/api-tokens/authorize"
  do
    url="${base%/}${path}"
    [[ "$(curl_head "$url")" == "200" ]] && { echo "$url"; return 0; }
  done

  return 1
}

TOKEN_ENDPOINT="$(discover_token_endpoint "${VCFA_URL}")" || {
  echo "!! Could not discover a token endpoint (404s everywhere)."
  echo "   • If you use Keycloak, set VCFA_OIDC_REALM, e.g.: export VCFA_OIDC_REALM=vcfa"
  echo "   • Or provide your exact endpoint via VCFA_CREATE_TOKEN_PATH if your platform mints tokens with a custom API."
  exit 1
}

echo "✓ Using token endpoint: ${TOKEN_ENDPOINT}"

# --------- Request an access token (password grant) ---------
# Build x-www-form-urlencoded body (URL-encode via jq)
form_kv() { printf %s "$1=$(printf %s "$2" | jq -sRr @uri)"; }

FORM="$(form_kv grant_type password)&$(form_kv username "${VCFA_USER}")&$(form_kv password "${VCFA_PASSWORD}")"
# Standard scopes (adjust if your IdP complains)
FORM="${FORM}&$(form_kv scope "openid offline_access")"
[[ -n "${VCFA_CLIENT_ID}"    ]] && FORM="${FORM}&$(form_kv client_id "${VCFA_CLIENT_ID}")"

# Some IdPs expect Basic auth when client_secret is set
AUTH_OPTS=()
if [[ -n "${VCFA_CLIENT_ID}" && -n "${VCFA_CLIENT_SECRET}" ]]; then
  AUTH_OPTS=(-u "${VCFA_CLIENT_ID}:${VCFA_CLIENT_SECRET}")
fi

echo "→ Requesting access token…"
TMP_RESP="$(mktemp)"
HTTP_CODE="$(curl -sS -o "${TMP_RESP}" -w "%{http_code}" "${CURL_INSECURE[@]}" \
  -H "Accept: application/json" -H "Content-Type: application/x-www-form-urlencoded" \
  "${AUTH_OPTS[@]}" -X POST --data "${FORM}" "${TOKEN_ENDPOINT}")"

if [[ "${HTTP_CODE}" != "200" ]]; then
  echo "!! Token endpoint returned HTTP ${HTTP_CODE}. First lines of the body:" >&2
  sed -n '1,120p' "${TMP_RESP}" >&2
  rm -f "${TMP_RESP}"
  exit 1
fi

# Parse JSON
if ! JQ . < "${TMP_RESP}"; then
  echo "!! Token endpoint did not return valid JSON. First lines:" >&2
  sed -n '1,120p' "${TMP_RESP}" >&2
  rm -f "${TMP_RESP}"
  exit 1
fi

ACCESS_TOKEN="$(jq -r '.access_token // empty' < "${TMP_RESP}")"
REFRESH_TOKEN="$(jq -r '.refresh_token // empty' < "${TMP_RESP}")"
rm -f "${TMP_RESP}"

[[ -z "${ACCESS_TOKEN}" ]] && { echo "!! access_token missing in response"; exit 1; }
echo "✓ Access token acquired"

# --------- (Optional) Mint a long-lived API token via platform API ---------
API_TOKEN=""
if [[ -n "${VCFA_CREATE_TOKEN_PATH}" ]]; then
  CREATE_URL="${VCFA_URL%/}${VCFA_CREATE_TOKEN_PATH}"
  echo "→ Creating API token at: ${CREATE_URL}"
  TMP_CREATE="$(mktemp)"
  HTTP_CODE="$(curl -sS -o "${TMP_CREATE}" -w "%{http_code}" "${CURL_INSECURE[@]}" \
    -H "Accept: application/json" -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -X POST --data @- "${CREATE_URL}" <<EOF
{"name":"${VCFA_TOKEN_NAME}","expiresInDays":${VCFA_TOKEN_TTL_DAYS},"org":"${VCFA_ORG}"}
EOF
)"
  if [[ "${HTTP_CODE}" == "200" || "${HTTP_CODE}" == "201" ]]; then
    if JQ . < "${TMP_CREATE}"; then
      API_TOKEN="$(jq -r '.token // .value // .apiToken // empty' < "${TMP_CREATE}")"
    fi
  else
    echo "!! API token mint endpoint returned HTTP ${HTTP_CODE}; falling back to access_token."
    sed -n '1,120p' "${TMP_CREATE}" >&2 || true
  fi
  rm -f "${TMP_CREATE}"
fi

# Fallback: use access token if no API token minted
if [[ -z "${API_TOKEN}" ]]; then
  API_TOKEN="${ACCESS_TOKEN}"
  echo "→ Using access token as provider api_token."
fi
echo "✓ Token ready"

# --------- Write Terraform vars ---------
mkdir -p "${TF_OUT_DIR}"
TFVARS="${TF_OUT_DIR%/}/secrets.auto.tfvars.json"
jq -n --arg url "${VCFA_URL}" \
      --arg org "${VCFA_ORG}" \
      --arg token "${API_TOKEN}" \
      --argjson allow_unverified $([[ "${VCFA_ALLOW_UNVERIFIED_SSL}" == "1" ]] && echo 1 || echo 0) \
'{
  vcfa_url: $url,
  vcfa_org: $org,
  vcfa_auth_type: "api_token",
  vcfa_token: $token,
  vcfa_allow_unverified_ssl: $allow_unverified
}' > "${TFVARS}"

echo "✓ Wrote ${TFVARS}"
echo "All set. Your Terraform provider can now use vcfa_token from that file."
