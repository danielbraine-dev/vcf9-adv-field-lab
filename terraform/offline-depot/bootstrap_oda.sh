#!/usr/bin/env bash
set -euo pipefail

# ---------- Inputs from ENV (set by remote-exec) ----------
: "${SUDO_PASS:?missing SUDO_PASS}"
: "${SRC_HOST:?missing SRC_HOST}"
: "${SRC_USER:?missing SRC_USER}"
: "${SRC_PATH:?missing SRC_PATH}"
: "${SRC_PASS:?missing SRC_PASS}"

# Optional SDDC Manager creds (defaults ok for your lab)
VCF_HOST="${VCF_HOST:-10.1.1.5}"
VCF_USER="${VCF_USER:-vcf}"
VCF_PASS="${VCF_PASS:-}"   # empty => try key-based auth

# Sudo helpers (don’t re-sudo if already root)
if [[ $EUID -eq 0 ]]; then
  SUDO=""; echosudo(){ "$@"; }
else
  SUDO="sudo -S -p ''"
  echosudo(){ printf "%s\n" "$SUDO_PASS" | sudo -S -p '' "$@"; }
fi

PROPS_FILE="/root/vdt/conf/application-prodv2.properties"
TOKEN_DIR="/home/admin"
GEN_TOKEN_LOCAL="${TOKEN_DIR}/genToken.sh"
TOKEN_FILE="${TOKEN_DIR}/d-token"
WEB_ROOT="/var/www"
BUILD_DIR="${WEB_ROOT}/build"
SSL_KEY="/etc/ssl/private/selfsigned.key"
SSL_CRT="/etc/ssl/certs/selfsigned.crt"
NGINX_SITE_NAME="depot"
NGINX_SITES_AVAILABLE="/etc/nginx/sites-available"
NGINX_SITES_ENABLED="/etc/nginx/sites-enabled"
NGINX_CONF_D="/etc/nginx/conf.d"
IPTABLES_SAVE_PATH="/etc/systemd/scripts/ip4save"
CN_FQDN="oda.site-a.vcf.lab"

log(){ printf "\n\033[1;36m%s\033[0m\n" "$*"; }
warn(){ printf "\n\033[1;33m%s\033[0m\n" "$*"; }
err(){ printf "\n\033[1;31m%s\033[0m\n" "$*"; }

require_file(){ ${SUDO:-sudo} test -f "$1" || { err "Missing required file: $1"; exit 1; }; }
ensure_dir(){ [[ -d "$1" ]] || echosudo mkdir -p "$1"; }

# Make sure admin/root won’t expire again (best-effort; ignore if not allowed)
echosudo chage -M 99999 -I -1 -E -1 root || true
echosudo chage -M 99999 -I -1 -E -1 admin || true

# Wait patiently for the VDT properties file (first boot can be slow)
log "Waiting for ${PROPS_FILE} to appear…"
for _ in $(seq 1 120); do
  if ${SUDO:-sudo} test -f "${PROPS_FILE}"; then log "Found ${PROPS_FILE}"; break; fi
  sleep 5
done
# Proceed even if missing; the sed/appending below is resilient
if ! ${SUDO:-sudo} test -f "${PROPS_FILE}"; then warn "Still missing ${PROPS_FILE}; will append property safely"; fi

# 2–4) Update Broadcom depot host (hyphenated as requested)
log "Ensuring depot host is dl-pstg.broadcom.com in ${PROPS_FILE}…"
if ${SUDO:-sudo} test -f "${PROPS_FILE}"; then
  ${SUDO:-sudo} bash -lc "grep -q '^lcm.depot.adapter.host=' '${PROPS_FILE}'" \
    && ${SUDO:-sudo} bash -lc "sed -E -i 's#^lcm.depot.adapter.host=.*#lcm.depot.adapter.host=dl-pstg.broadcom.com#' '${PROPS_FILE}'" \
    || ${SUDO:-sudo} bash -lc "printf '%s\n' 'lcm.depot.adapter.host=dl-pstg.broadcom.com' >> '${PROPS_FILE}'"
else
  # create file with the property if it truly doesn't exist yet
  echosudo mkdir -p "$(dirname "${PROPS_FILE}")"
  echosudo bash -lc "printf '%s\n' 'lcm.depot.adapter.host=dl-pstg.broadcom.com' > '${PROPS_FILE}'"
fi

# Fetch genToken.sh via scp (password auth with sshpass)
log "Ensuring ${GEN_TOKEN_LOCAL} exists (scp from ${SRC_USER}@${SRC_HOST})…"
if [[ ! -f "${GEN_TOKEN_LOCAL}" ]]; then
  SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
  if ! command -v sshpass >/dev/null 2>&1; then
    log "Installing sshpass…"
    echosudo apt-get update -y
    echosudo DEBIAN_FRONTEND=noninteractive apt-get install -y sshpass
  fi
  sshpass -p "${SRC_PASS}" scp ${SSH_OPTS} \
    "${SRC_USER}@${SRC_HOST}:${SRC_PATH}" "${GEN_TOKEN_LOCAL}"
  chmod +x "${GEN_TOKEN_LOCAL}"
else
  warn "genToken.sh already present; skipping scp."
fi

# 6–7) Generate token and strip surrounding double quotes
log "Generating Broadcom depot token with genToken.sh…"
if [[ ! -s "${TOKEN_FILE}" ]]; then
  (cd "${TOKEN_DIR}" && ./genToken.sh > d-token)
fi
if [[ -s "${TOKEN_FILE}" ]]; then
  sed -E -i 's/^"(.*)"$/\1/' "${TOKEN_FILE}"
else
  err "Token file ${TOKEN_FILE} is empty after genToken.sh"
  exit 1
fi

# 8) Download depot files (only if empty)
log "Downloading depot binaries if needed…"
ensure_dir "${BUILD_DIR}"
DOWNLOAD_CMD=(/root/vdt/bin/vcf-download-tool binaries download
  --depot-store="${BUILD_DIR}"
  --depot-download-token-file="${TOKEN_FILE}"
  --ceip=disable
  --vcf-version=9.0.1
)
if [[ -z "$(ls -A "${BUILD_DIR}" 2>/dev/null)" ]]; then
  echosudo "${DOWNLOAD_CMD[@]}"
else
  warn "Build directory ${BUILD_DIR} not empty, skipping download."
fi

# 9) Permissions on /var/www
log "Setting permissions on ${WEB_ROOT}…"
echosudo chown -R nginx "${WEB_ROOT}"
echosudo chgrp -R nginx "${WEB_ROOT}"
echosudo chmod -R 750 "${WEB_ROOT}"
echosudo chmod g+s "${WEB_ROOT}"

# 10) Self-signed TLS certs (CN only)
log "Ensuring self-signed TLS cert exists…"
if [[ ! -f "${SSL_KEY}" || ! -f "${SSL_CRT}" ]]; then
  echosudo mkdir -p "$(dirname "${SSL_KEY}")" "$(dirname "${SSL_CRT}")"
  echosudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
    -keyout "${SSL_KEY}" -out "${SSL_CRT}" \
    -subj "/C=US/ST=Virginia/L=Reston/O=VMware/OU=VMware Engineering/CN=${CN_FQDN}"
  echosudo chmod 600 "${SSL_KEY}"
  echosudo chmod 644 "${SSL_CRT}"
else
  warn "TLS files already exist; skipping creation."
fi

# Nginx server block for 443 with your cipher prefs
log "Configuring nginx server for HTTPS on 443…"
if [[ -d "${NGINX_SITES_AVAILABLE}" && -d "${NGINX_SITES_ENABLED}" ]]; then
  NGINX_FILE="${NGINX_SITES_AVAILABLE}/${NGINX_SITE_NAME}"
  NGINX_LINK="${NGINX_SITES_ENABLED}/${NGINX_SITE_NAME}"
else
  NGINX_FILE="${NGINX_CONF_D}/${NGINX_SITE_NAME}.conf"
  NGINX_LINK=""
  echosudo mkdir -p "${NGINX_CONF_D}"
fi

cat >/tmp/nginx_depot.conf <<'CONF'
server {
    listen 443 ssl;
    server_name oda.site-a.vcf.lab;

    ssl_certificate     /etc/ssl/certs/selfsigned.crt;
    ssl_certificate_key /etc/ssl/private/selfsigned.key;

    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    root /var/www;
    index index.html;

    ssl_session_timeout 5m;
    ssl_session_cache shared:SSL:1m;

    location / {
        try_files $uri $uri/ =404;
        autoindex on;
    }

    error_page 500 502 503 504 /50x.html;
    location = /50x.html {
        root /var/www/build;
    }
}
CONF

if [[ ! -f "${NGINX_FILE}" ]] || ! cmp -s /tmp/nginx_depot.conf "${NGINX_FILE}"; then
  echosudo cp /tmp/nginx_depot.conf "${NGINX_FILE}"
fi
rm -f /tmp/nginx_depot.conf

if [[ -n "${NGINX_LINK:-}" && ! -L "${NGINX_LINK}" ]]; then
  echosudo ln -sf "${NGINX_FILE}" "${NGINX_LINK}"
fi

# Ensure 50x page exists
echosudo bash -lc 'mkdir -p /var/www/build && echo "<h1>Service Temporarily Unavailable</h1>" > /var/www/build/50x.html' || true

echosudo nginx -t
echosudo systemctl restart nginx
echosudo systemctl enable nginx || true

# 11) Open TCP/443 via iptables and persist
log "Opening TCP/443 via iptables…"
if ! ${SUDO:-sudo} iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null; then
  echosudo iptables -I INPUT -p tcp --dport 443 -j ACCEPT
else
  warn "iptables rule for 443 already present."
fi
echosudo mkdir -p "$(dirname "${IPTABLES_SAVE_PATH}")"
echosudo bash -lc "iptables-save > '${IPTABLES_SAVE_PATH}'"

# 12) Export cert as PEM and copy to SDDC Manager
log "Exporting TLS cert to PEM and copying to ${VCF_USER}@${VCF_HOST}:/tmp …"
CERT_PEM="${HOME}/selfsigned-cert.pem"
cp -f "${SSL_CRT}" "${CERT_PEM}"
chmod 644 "${CERT_PEM}"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
if [[ -n "${VCF_PASS}" ]]; then
  if ! command -v sshpass >/dev/null 2>&1; then
    log "Installing sshpass for password-based scp…"
    echosudo apt-get update -y
    echosudo DEBIAN_FRONTEND=noninteractive apt-get install -y sshpass
  fi
  sshpass -p "${VCF_PASS}" scp ${SSH_OPTS} "${CERT_PEM}" "${VCF_USER}@${VCF_HOST}:/tmp/"
else
  scp ${SSH_OPTS} "${CERT_PEM}" "${VCF_USER}@${VCF_HOST}:/tmp/"
fi
log "PEM copied to ${VCF_HOST}:/tmp/$(basename "${CERT_PEM}")"

log "Bootstrap complete."
