############################
# Avi Controller OVA deploy (vSphere)
############################

variable "vsphere_cluster"  { type = string }
variable "vsphere_datastore"{ type = string }

variable "avi_ova_path"     { type = string }
variable "avi_vm_name"      { type = string }
variable "avi_mgmt_pg"      { type = string }
variable "avi_mgmt_ip"      { type = string }
variable "avi_mgmt_netmask" { type = string }
variable "avi_mgmt_gateway" { type = string }
variable "avi_dns_servers"  { type = list(string) }
variable "avi_ntp_servers"  { type = list(string) }
variable "avi_domain_search"{ type = string }
variable "avi_admin_password" { type = string, sensitive = true }

# Inventory lookups
data "vsphere_datacenter" "avi_dc" {
  name = var.vsphere_datacenter
}

data "vsphere_cluster" "avi_cluster" {
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

data "vsphere_resource_pool" "avi_rp" {
  name          = "${data.vsphere_cluster.avi_cluster.name}/Resources"
  datacenter_id = data.vsphere_datacenter.avi_dc.id
}

# Deploy OVA
resource "vsphere_virtual_machine" "avi_controller" {
  name             = var.avi_vm_name
  datastore_id     = data.vsphere_datastore.avi_ds.id
  resource_pool_id = data.vsphere_resource_pool.avi_rp.id

  num_cpus = 8
  memory   = 24576
  guest_id = "other3xLinux64Guest"
  wait_for_guest_net_timeout = 0

  network_interface {
    network_id   = data.vsphere_network.avi_net.id
    adapter_type = "vmxnet3"
  }

  disk {
    label            = "disk0"
    size             = 128
    eagerly_scrub    = false
    thin_provisioned = true
  }

  ovf_deploy {
    file_path      = var.avi_ova_path
    disk_provisioning = "thin"
    allow_unverified_ssl_cert = true
    ip_protocol    = "IPv4"

    # Map OVA networks to your portgroup
    network_map = {
      "Management" = data.vsphere_network.avi_net.id
    }
  }

  extra_config = {
    # Avi OVA cloud-init style properties (varies by OVA build)
    "guestinfo.controller.ip"       = var.avi_mgmt_ip
    "guestinfo.controller.gateway"  = var.avi_mgmt_gateway
    "guestinfo.controller.netmask"  = var.avi_mgmt_netmask
    "guestinfo.controller.dns"      = join(",", var.avi_dns_servers)
    "guestinfo.controller.ntp"      = join(",", var.avi_ntp_servers)
    "guestinfo.controller.domain"   = var.avi_domain_search
    "guestinfo.controller.admin_password" = var.avi_admin_password
  }
}
