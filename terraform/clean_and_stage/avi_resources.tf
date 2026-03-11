######################################
# Avi Controller OVA deploy (vSphere)
######################################

# Inventory lookups
data "vsphere_datacenter" "avi_dc" {
  name = var.vsphere_datacenter
}

data "vsphere_compute_cluster" "avi_cluster" {
  name          = var.vsphere_cluster
  datacenter_id = data.vsphere_datacenter.avi_dc.id
}

data "vsphere_datastore" "avi_ds" {
  name          = var.vsphere_datastore
  datacenter_id = data.vsphere_datacenter.avi_dc.id
}

data "vsphere_network" "avi_net" {
  name          = var.avi_mgmt_pg
  datacenter_id = data.vsphere_datacenter.avi_dc.id
}
########################################
# vSphere: AVI Controller Resource Pool
#######################################
resource "vsphere_resource_pool" "avi" {
  name                    = "Avi-Controller"
  parent_resource_pool_id = data.vsphere_compute_cluster.avi_cluster.resource_pool_id
}
############################################
# vSphere: Local Content Library for AVI SE
############################################
resource "vsphere_content_library" "avi_se_cl" {
  name            = "AVI SE Content Library"
  description     = "Local content library for AVI SE artifacts"
  storage_backing = [data.vsphere_datastore.avi_ds.id]
}
#########################################################
# Credentials
#########################################################
resource "avi_cloudconnectoruser" "vcenter_admin" {
  name = "vCenter Admin"
  vcenter_credentials {
    username = "administrator@wld.sso"
    password = var.vsphere_password
  }
}

resource "avi_cloudconnectoruser" "nsx_admin" {
  name = "NSX Admin"
  nsxt_credentials {
    username = "admin"
    password = var.nsx_password
  }
}

#########################################################
# IPAM & DNS Profiles
#########################################################
resource "avi_ipamdnsproviderprofile" "avi_ipam" {
  name = "AVI IPAM"
  type = "IPAMDNS_TYPE_INTERNAL"
  internal_profile {
    ttl = 30
  }
}

resource "avi_ipamdnsproviderprofile" "avi_dns" {
  name = "AVI DNS"
  type = "IPAMDNS_TYPE_INTERNAL_DNS"
  internal_profile {
    dns_service_domain {
      domain_name = "lb.site-a.vcf.lab"
    }
    ttl = 30
  }
}

#########################################################
# SSL/TLS Certificate Generation
#########################################################
resource "tls_private_key" "avi" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "avi" {
  private_key_pem = tls_private_key.avi.private_key_pem

  subject {
    common_name         = "avi-controller01.site-a.vcf.lab"
    organization        = "Broadcom"
    organizational_unit = "VCF"
    locality            = "Reston"
    province            = "VA"
    country             = "US"
  }

  ip_addresses = [var.avi_mgmt_ip]
  dns_names    = ["avi-controller01.site-a.vcf.lab"]

  validity_period_hours = 87600 # 10 years
  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

# Upload the certificate to Avi
resource "avi_sslkeyandcertificate" "portal" {
  name = "avi-controller01.site-a.vcf.lab"
  type = "SSL_CERTIFICATE_TYPE_SYSTEM"
  certificate {
    self_signed = false # False because we generated it outside of Avi
    certificate = tls_self_signed_cert.avi.cert_pem
  }
  key = tls_private_key.avi.private_key_pem
}

# Export locally so your script can upload it to NSX in Step 7
resource "local_file" "avi_cert_pem" {
  content  = tls_self_signed_cert.avi.cert_pem
  filename = "${path.module}/out/avi-portal.crt"
}

resource "local_file" "avi_key_pem" {
  content  = tls_private_key.avi.private_key_pem
  filename = "${path.module}/out/avi-portal.key"
}

#########################################################
# System Configuration (Licensing & Portal Cert Swap)
#########################################################
resource "avi_systemconfiguration" "this" {
  # Forces the 20 Core Eval License
  default_license_tier = "ENTERPRISE" 
  
  # Ensure the Welcome Wizard stays locked out
  welcome_workflow_complete = true    

  # We must re-declare DNS and NTP here so Terraform doesn't overwrite 
  # what we did in Step 6 with blank values.
  dns_configuration {
    server_list {
      addr = var.avi_dns_servers[0]
      type = "V4"
    }
    search_domain = var.avi_domain_search
  }

  ntp_configuration {
    ntp_servers {
      server {
        addr = var.avi_ntp_servers[0]
        type = "V4"
      }
    }
  }

  portal_configuration {
    allow_basic_authentication     = false
    disable_remote_cli_shell       = false
    enable_clickjacking_protection = true
    enable_http                    = true
    enable_https                   = true
    password_strength_check        = true
    redirect_to_https              = true
    sslprofile_ref                 = "/api/sslprofile?name=System-Standard-Portal"
    
    # This detaches System-Default-Portal-Cert and attaches our custom cert
    sslkeyandcertificate_refs      = [avi_sslkeyandcertificate.portal.id]
  }

  global_tenant_config {
    se_in_provider_context       = true
    tenant_access_to_provider_se = true
    tenant_vrf                   = false
  }
}

##########################################################################
# Deploy OVA - Saving in-case I figure out how to do this instead of govc
##########################################################################

resource "vsphere_virtual_machine" "avi_controller" {
  name             = var.avi_vm_name
  datastore_id     = data.vsphere_datastore.avi_ds.id
  resource_pool_id = vsphere_resource_pool.avi.id

  num_cpus = 6
  memory   = 24576
  guest_id = "other3xLinux64Guest"

  depends_on = [
    vsphere_resource_pool.avi,
    vsphere_content_library.avi_se_cl
  ]

  network_interface {
    network_id   = data.vsphere_network.avi_net.id
    adapter_type = "vmxnet3"
  }

  ovf_deploy {
    local_ovf_path            = var.avi_ova_path
    disk_provisioning         = "thin"
    allow_unverified_ssl_cert = true
    ovf_network_map = {
      "Management" = data.vsphere_network.avi_net.id
    }
  }

  vapp {
    properties = {
      "avi.mgmt-ip.CONTROLLER"             = "10.1.1.200"
      "avi.mgmt-mask.CONTROLLER"           = "255.255.255.0"
      "avi.default-gw.CONTROLLER"          = "10.1.1.1"
    }
  }

  lifecycle {
    ignore_changes = [vapp[0].properties]
  }
}
