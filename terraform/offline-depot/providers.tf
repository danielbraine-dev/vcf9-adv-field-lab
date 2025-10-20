terraform {
  required_version = ">= 1.6.0"

  required_providers {
    vsphere = {
      source  = "vmware/vsphere"
      version = ">= 2.15.0"
    }
  }
}

# --- vSphere ---
provider "vsphere" {
  user                 = "administrator@vsphere.local"
  password             = "VMware123!VMware123!"
  vsphere_server       = "vc-mgmt-a.site-a.vcf.lab"
  allow_unverified_ssl = true
}






