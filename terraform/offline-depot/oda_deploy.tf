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
variable "vsphere_datastore"{ 
  description = "Target datastore"
  type        = string 
  default     = "vsan-mgmt-01a"
}
variable "vsphere_mgmt_pg"{ 
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
variable "oda_ova_path"     { 
  type          = string 
  default       = "~/Downloads/vcf-offline-depot-appliance-0.1.3.ova"
}
variable "oda_vm_name"      { 
  type          = string
  default       = "vcf-offline-depot-appliance-0.1.3"
}
variable "oda_hostname"     {
  type          = string
  default       = "oda.site-a.vcf.lab"
}
variable "oda_mgmt_ip"      { 
  type          = string
  default       = "10.1.1.190"
}
variable "oda_mgmt_netmask" { 
  type          = string
  default       = "24 (255.255.255.0)"
}
variable "oda_mgmt_gateway" {
  type          = string
  default       = "10.1.1.1"
}
variable "oda_dns_servers"  { 
  type = list(string) 
  default = [10.1.1.1]
}
variable "oda_ntp_servers"  { 
  type = list(string)
  default = [10.1.1.1]
}
variable "oda_domain_search"{ 
  type = string
  default = "site-a.vcf.local"
}
variable "oda_admin_password" { 
  type = string
  sensitive = true
  default = "VMware123!VMware123!"
}


############################
# Deploy Offline Depot Appliance OVA
############################
resource "vsphere_virtual_machine" "oda_controller" {
  name             = var.oda_vm_name
  datastore_id     = data.vsphere_datastore.oda_ds.id
  resource_pool_id = data.vsphere_compute_cluster.cluster.resource_pool_id

  num_cpus = 2
  memory   = 2048
  guest_id = "other3xLinux64Guest"
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

  extra_config = {
    # oda OVA cloud-init style properties (varies by OVA build)
    "guestinfo.ipaddress"       = var.oda_mgmt_ip
    "guestinfo.gateway"  = var.oda_mgmt_gateway
    "guestinfo.netmask"  = var.oda_mgmt_netmask
    "guestinfo.dns"      = join(",", var.oda_dns_servers)
    "guestinfo.ntp"      = join(",", var.oda_ntp_servers)
    "guestinfo.hostname" = var.oda_hostname
    "guestinfo.domain"   = var.oda_domain_search
    "guestinfo.admin_password" = var.oda_admin_password
    "guestinfo.enable_ping"    = True
    "guestinfo.enable_jupyter" = True
    "guestinfo.enable_ssh"     = True
    "guestinfo.download_token" = ""
    "guestinfo.vcf_version"    = "9.0.1"
    "guestinfo.skip_dl"        = False
  }
}
