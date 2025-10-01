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
provider "vcfa" {
  url          = var.vcfa_endpoint
  org          = var.vcfa_org_name
  token        = var.vcfa_token
}
