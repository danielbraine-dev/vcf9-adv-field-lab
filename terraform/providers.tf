terraform {
  required_version = ">= 1.6.0"

  required_providers {
    nsxt = {
      source  = "vmware/nsxt"
      version = ">= 3.9.0"
    }
    vsphere = {
      source  = "hashicorp/vsphere"
      version = ">= 2.5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.29.0"
    }
    # VCFA provider placeholder (uncomment when you add the correct source):
    # vcfa = {
    #   source  = "vmware/vcfa"
    #   version = ">= 0.1.0"
    # }
  }
}

# --- NSX-T (active) ---
provider "nsxt" {
  host                 = var.nsx_host
  username             = var.nsx_username
  password             = var.nsx_password
  allow_unverified_ssl = var.nsx_allow_unverified_ssl
  # If you use Global Manager / alt enforcement points, set below accordingly.
  # global_manager     = false
  # enforcement_point  = "default"
}

# --- vSphere (placeholder) ---
provider "vsphere" {
  user                 = var.vsphere_user
  password             = var.vsphere_password
  vsphere_server       = var.vsphere_server
  allow_unverified_ssl = true
}

# --- Kubernetes (placeholder, leave commented until you supply kubeconfig) ---
# provider "kubernetes" {
#   config_path = var.kubeconfig_path
#   config_context = var.kube_context
# }

# --- VCF-A (placeholder) ---
# provider "vcfa" {
#   endpoint = var.vcfa_endpoint
#   token    = var.vcfa_token
# }
