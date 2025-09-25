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
  host                 = nsx-wld01-a.site-a.vcf.lab
  username             = admin
  password             = VMware123!VMware123!
  allow_unverified_ssl = true
}

# --- vSphere (placeholder) ---
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
