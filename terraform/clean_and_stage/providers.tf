terraform {
  required_version = ">= 1.6.0"

  required_providers {
    nsxt = {
      source  = "vmware/nsxt"
      version = ">= 3.10.0"
    }
    avi = {
      source  = "vmware/avi"
      version = "31.1.1"
    }
    vsphere = {
      source  = "vmware/vsphere"
      version = ">= 2.15.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.38.0"
    }
    vcfa = {
      source  = "vmware/vcfa"
      version = ">= 1.0.0"
    }
    tls = { 
      source = "hashicorp/tls" 
      version = ">=4.1.0"
    }
  }
}

# --- NSX-T ---
provider "nsxt" {
  host                  = var.nsx_host
  username              = var.nsx_username
  password              = var.nsx_password
  allow_unverified_ssl  = var.nsx_allow_unverified_ssl
  max_retries           = 10
  retry_min_delay       = 500
  retry_max_delay       = 5000
  retry_on_status_codes = [429]
}

# --- Avi (NSX ALB) ---
provider "avi" {
  avi_username   = var.avi_username
  avi_password   = var.avi_password
  avi_tenant     = var.avi_tenant
  avi_controller = var.avi_controller
  avi_version    = var.avi_version
}

# --- vSphere ---
provider "vsphere" {
  user                 = var.vsphere_user
  password             = var.vsphere_password
  vsphere_server       = var.vsphere_server
  allow_unverified_ssl = true
}

# --- Kubernetes (optional; uncomment and set vars to use) ---
# provider "kubernetes" {
#   config_path    = var.kubeconfig_path
#   config_context = var.kube_context
# }

# --- VCFA ---
# Where to store tokens
locals {
  auth_dir              = "${path.root}/.auth"
  tenant_token_path     = "${local.auth_dir}/vcfa_tenant_token.json"
  system_token_path     = "${local.auth_dir}/vcfa_system_token.json"
}

# Ensure .auth exists (once)
resource "null_resource" "auth_dir" {
  provisioner "local-exec" {
    command = "mkdir -p ${local.auth_dir}"
  }
}

# --------- Providers used ONLY to create API tokens (user/password auth) ----------
provider "vcfa" {
  alias                = "tenant_password"
  url                  = var.vcfa_endpoint
  org                  = var.vcfa_org_name
  user                 = "admin"
  password             = "VMware123!VMware123!"
  auth_type            = "integrated"
  allow_unverified_ssl = true
}

provider "vcfa" {
  alias    = "system_password"
  url      = var.vcfa_endpoint
  org      = "System"
  user      = "admin"
  password  = "VMware123!VMware123!"
  auth_type = "integrated"
  allow_unverified_ssl = true
}

# Mint tokens once and write them to files
resource "vcfa_api_token" "tenant" {
  provider         = vcfa.tenant_password
  name             = "tenant_automation"
  file_name        = local.tenant_token_path
  allow_token_file = true
  depends_on       = [null_resource.auth_dir]
}

resource "vcfa_api_token" "system" {
  provider         = vcfa.system_password
  name             = "system_automation"
  file_name        = local.system_token_path
  allow_token_file = true
  depends_on       = [null_resource.auth_dir]

}

# --------- Providers used by ALL resources and data sources (token-file auth) ----------
provider "vcfa" {
  url                   = var.vcfa_endpoint
  org                   = var.vcfa_org_name
  auth_type             = "api_token_file"
  allow_api_token_file  = true
  api_token_file        = local.tenant_token_path
  allow_unverified_ssl  = true
}

provider "vcfa" {
  alias                = "tenant"
  url                  = var.vcfa_endpoint
  org                  = var.vcfa_org_name
  auth_type            = "api_token_file"
  allow_api_token_file = true
  api_token_file       = local.tenant_token_path
  allow_unverified_ssl = true
}

provider "vcfa" {
  alias                = "system"
  url                  = var.vcfa_endpoint
  org                  = "System"
  auth_type            = "api_token_file"
  allow_api_token_file = true
  api_token_file       = local.system_token_path
  allow_unverified_ssl = true
}
