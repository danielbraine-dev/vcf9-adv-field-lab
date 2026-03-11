############################
# Avi Controller OVA deploy (vSphere)
############################

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

# vSphere: AVI Controller Resource Pool
resource "vsphere_resource_pool" "avi" {
  name                    = "Avi-Controller"
  parent_resource_pool_id = data.vsphere_compute_cluster.avi_cluster.resource_pool_id
}

# vSphere: Local Content Library for AVI SE
resource "vsphere_content_library" "avi_se_cl" {
  name            = "AVI SE Content Library"
  description     = "Local content library for AVI SE artifacts"
  storage_backing = [data.vsphere_datastore.avi_ds.id]
}

# Deploy OVA
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
