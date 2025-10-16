############################
# ODA Controller OVA deploy (vSphere)
############################

############################
# Base vSphere Variables
############################
variable "vsphere_datacenter" {
  description = "Target datacenter name"
  type        = string
  default     = "dc-a"
}
variable "vsphere_cluster" {
  description = "Target cluster name"
  type        = string
  default     = "cluster-mgmt-01a"
}
variable "vsphere_datastore" {
  description = "Target datastore"
  type        = string
  default     = "vsan-mgmt-01a"
}
variable "vsphere_mgmt_pg" {
  description = "Target dvPg for mgmt appliances"
  type        = string
  default     = "mgmt-vds-01-mgmt-01a"
}

############################
# vSphere Inventory lookups
############################
data "vsphere_datacenter" "oda_dc" {
  name = var.vsphere_datacenter
}

data "vsphere_compute_cluster" "oda_cluster" {
  name          = var.vsphere_cluster
  datacenter_id = data.vsphere_datacenter.oda_dc.id
}

data "vsphere_datastore" "oda_ds" {
  name          = var.vsphere_datastore
  datacenter_id = data.vsphere_datacenter.oda_dc.id
}

data "vsphere_network" "oda_net" {
  name          = var.vsphere_mgmt_pg
  datacenter_id = data.vsphere_datacenter.oda_dc.id
}

############################
# OVA Variable Insertion
############################
variable "oda_ova_path" {
  type    = string
  default = "~/Downloads/vcf-offline-depot-appliance-0.1.3.ova"
}
variable "oda_vm_name" {
  type    = string
  default = "vcf-offline-depot-appliance-0.1.3"
}
variable "oda_hostname" {
  type    = string
  default = "oda.site-a.vcf.lab"
}
variable "oda_mgmt_ip" {
  type    = string
  default = "10.1.1.190"
}
variable "oda_mgmt_netmask" {
  type    = string
  default = "24 (255.255.255.0)"
}
variable "oda_mgmt_gateway" {
  type    = string
  default = "10.1.1.1"
}
variable "oda_dns_servers" {
  type    = list(string)
  default = ["10.1.1.1"]
}
variable "oda_ntp_servers" {
  type    = list(string)
  default = ["10.1.1.1"]
}
variable "oda_domain_search" {
  type    = string
  default = "site-a.vcf.local"
}
variable "oda_admin_password" {
  type      = string
  sensitive = true
  default   = "VMware123!VMware123!"
}

############################
# Deploy Offline Depot Appliance OVA
############################
resource "vsphere_virtual_machine" "oda_appliance" {
  name             = var.oda_vm_name
  datastore_id     = data.vsphere_datastore.oda_ds.id
  resource_pool_id = data.vsphere_compute_cluster.oda_cluster.resource_pool_id

  num_cpus = 2
  memory   = 2048
  guest_id = "other3xLinux64Guest"

  # Optional: wait for guest tools network (your OVA might not use tools yet)
  wait_for_guest_net_timeout = 0

  network_interface {
    network_id   = data.vsphere_network.oda_net.id
    adapter_type = "vmxnet3"
  }

  disk {
    label            = "disk0"
    size             = 332
    eagerly_scrub    = false
    thin_provisioned = true
  }

  ovf_deploy {
    local_ovf_path            = var.oda_ova_path
    disk_provisioning         = "thin"
    allow_unverified_ssl_cert = true
    ip_protocol               = "IPv4"

    # Map OVA networks to your portgroup
    ovf_network_map = {
      "Management" = data.vsphere_network.oda_net.id
    }
  }

  # Cloud-init style guestinfo (depends on OVA)
  extra_config = {
    "guestinfo.ipaddress"        = var.oda_mgmt_ip,
    "guestinfo.gateway"          = var.oda_mgmt_gateway,
    "guestinfo.netmask"          = var.oda_mgmt_netmask,
    "guestinfo.dns"              = join(",", var.oda_dns_servers),
    "guestinfo.ntp"              = join(",", var.oda_ntp_servers),
    "guestinfo.hostname"         = var.oda_hostname,
    "guestinfo.domain"           = var.oda_domain_search,
    "guestinfo.admin_password"   = var.oda_admin_password,
    "guestinfo.enable_ping"      = true,
    "guestinfo.enable_jupyter"   = true,
    "guestinfo.enable_ssh"       = true,
    "guestinfo.download_token"   = "",
    "guestinfo.vcf_version"      = "9.0.1",
    "guestinfo.skip_dl"          = false
  }
}

############################
# Post-deploy bootstrap over SSH
############################
resource "null_resource" "oda_bootstrap" {
  depends_on = [vsphere_virtual_machine.oda_appliance]

  # Bump to force re-run
  triggers = {
    always = timestamp()
  }

  connection {
    type     = "ssh"
    host     = var.oda_mgmt_ip # or vsphere_virtual_machine.oda_appliance.default_ip_address
    user     = "admin"
    password = var.oda_admin_password
    timeout  = "15m"
    agent    = false
  }

  provisioner "file" {
    destination = "/home/admin/bootstrap_oda.sh"
    content     = <<-BASH
      #!/usr/bin/env bash
      set -euo pipefail

      SUDO_PASS='${var.oda_admin_password}'
      SUDO="sudo -S -p ''"
      echosudo(){ printf "%s\\n" "$SUDO_PASS" | ${SUDO} "$@"; }

      PROPS_FILE="/root/vdt/conf/application-prodv2.properties"
      TOKEN_DIR="/home/admin"
      TOKEN_SCRIPT="${TOKEN_DIR}/getToken.sh"
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

      log(){ printf "\\n\\033[1;36m%s\\033[0m\\n" "$*"; }
      warn(){ printf "\\n\\033[1;33m%s\\033[0m\\n" "$*"; }
      err(){ printf "\\n\\033[1;31m%s\\033[0m\\n" "$*"; }

      require_file(){ [[ -f "$1" ]] || { err "Missing required file: $1"; exit 1; }; }
      ensure_dir(){ [[ -d "$1" ]] || echosudo mkdir -p "$1"; }

      # 2–4) Update Broadcom depot host in properties file
      log "Ensuring depot host is dl.pstg.broadcom.com in ${PROPS_FILE}…"
      require_file "${PROPS_FILE}"
      echosudo cp "${PROPS_FILE}" "${PROPS_FILE}.bak" || true
      if ${SUDO} bash -c "grep -q '^lcm.depot.adapter.host=' '${PROPS_FILE}'"; then
        ${SUDO} bash -c "sed -E -i 's#^lcm.depot.adapter.host=.*#lcm.depot.adapter.host=dl-pstg.broadcom.com#' '${PROPS_FILE}'"
      else
        ${SUDO} bash -c "printf '%s\\n' 'lcm.depot.adapter.host=dl-pstg.broadcom.com' >> '${PROPS_FILE}'"
      fi

      # 6–7) Generate token and strip surrounding double quotes
      log "Generating Broadcom depot token…"
      require_file "${TOKEN_SCRIPT}" || true
      [[ -x "${TOKEN_SCRIPT}" ]] || chmod +x "${TOKEN_SCRIPT}" || true

      if [[ ! -s "${TOKEN_FILE}" ]]; then
        (cd "${TOKEN_DIR}" && ./getToken.sh > d-token)
      fi
      if [[ -s "${TOKEN_FILE}" ]]; then
        sed -E -i 's/^"(.*)"$/\\1/' "${TOKEN_FILE}"
      else
        err "Token file ${TOKEN_FILE} is empty after getToken.sh"
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

      # 10) Create self-signed TLS certs if not already present
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

      NGINX_CONF_CONTENT="$(cat <<'CONF'
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
)"
      TMP_NGX="$(mktemp)"
      printf "%s\\n" "${NGINX_CONF_CONTENT}" > "${TMP_NGX}"
      if [[ ! -f "${NGINX_FILE}" ]] || ! cmp -s "${TMP_NGX}" "${NGINX_FILE}"; then
        echosudo cp "${TMP_NGX}" "${NGINX_FILE}"
      fi
      rm -f "${TMP_NGX}"

      if [[ -n "${NGINX_LINK:-}" && ! -L "${NGINX_LINK}" ]]; then
        echosudo ln -sf "${NGINX_FILE}" "${NGINX_LINK}"
      fi

      echosudo nginx -t
      echosudo systemctl restart nginx
      echosudo systemctl enable nginx || true

      # 11) Open TCP/443 via iptables and persist
      log "Opening TCP/443 via iptables…"
      if ! ${SUDO} iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null; then
        echosudo iptables -I INPUT -p tcp --dport 443 -j ACCEPT
      else
        warn "iptables rule for 443 already present."
      fi
      echosudo mkdir -p "$(dirname "${IPTABLES_SAVE_PATH}")"
      echosudo iptables-save | ${SUDO} tee "${IPTABLES_SAVE_PATH}" >/dev/null

      log "Bootstrap complete."
    BASH
  }

  provisioner "remote-exec" {
    inline = [
      # Make it executable and run with sudo (password via stdin)
      "chmod +x /home/admin/bootstrap_oda.sh",
      "echo '${var.oda_admin_password}' | sudo -S -p '' bash /home/admin/bootstrap_oda.sh"
    ]
  }
}
