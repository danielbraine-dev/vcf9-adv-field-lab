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
  user                 = "administrator@wld.sso"
  password             = "VMware123!VMware123!"
  vsphere_server       = "vc-wld01-a.site-a.vcf.lab"
  allow_unverified_ssl = true
}






