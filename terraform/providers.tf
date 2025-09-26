terraform {
  required_version = ">= 1.6.0"

  required_providers {
    nsxt = {
      source  = "vmware/nsxt"
      version = ">= 3.9.0"
    }
    avi = {
          source  = "vmware.com/avi/avi"
          version = "31.1.1"
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
  host                  = nsx-wld01-a.site-a.vcf.lab
  username              = admin
  password              = VMware123!VMware123!
  allow_unverified_ssl  = true
  max_retries           = 10
  retry_min_delay       = 500
  retry_max_delay       = 5000
  retry_on_status_codes = [429]
}

# --- AVI ---
provider "avi" {
  avi_username = "admin"
  avi_tenant = "admin"
  avi_password = "VMware123!VMware123!"
  avi_controller = "10.1.1.200"
  avi_version = "31.1.2"
}
# --- vSphere ---
provider "vsphere" {
  user                 = administrator@wld.sso
  password             = VMware123!VMware123!
  vsphere_server       = vc-wld01-a.site-a.vcf.lab
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
