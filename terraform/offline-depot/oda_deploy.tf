############################
# ODA Controller OVA deploy (vSphere)
############################

############################
# Base vSphere Variables
############################
variable "vsphere_datacenter" {
  description = "Target datacenter name"
  type        = string
  default     = "wld-01a-DC"
}
variable "vsphere_cluster" {
  description = "Target cluster name"
  type        = string
  default     = "cluster-wld01-01a "
}
variable "vsphere_datastore" {
  description = "Target datastore"
  type        = string
  default     = "cluster-wld01-01a-vsan01"
}
variable "vsphere_mgmt_pg" {
  description = "Target dvPg for mgmt appliances"
  type        = string
  default     = "mgmt-vds01-wld01-01a"
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
variable "oda_ova_path" {
  type    = string
  default = "/home/holuser/Downloads/vcf-offline-depot-appliance-0.1.3.ova"
}
variable "oda_vm_name" {
  type    = string
  default = "vcf-offline-depot-appliance-0.1.3"
}
variable "oda_hostname" {
  type    = string
  default = "oda.site-a.vcf.lab"
}
variable "oda_mgmt_ip" {
  type    = string
  default = "10.1.1.190"
}
variable "oda_mgmt_netmask" {
  type    = string
  default = "24 (255.255.255.0)"
}
variable "oda_mgmt_gateway" {
  type    = string
  default = "10.1.1.1"
}
variable "oda_dns_servers" {
  type    = list(string)
  default = ["10.1.1.1"]
}
variable "oda_ntp_servers" {
  type    = list(string)
  default = ["10.1.1.1"]
}
variable "oda_domain_search" {
  type    = string
  default = "site-a.vcf.lab"
}
variable "oda_admin_password" {
  type      = string
  sensitive = true
  default   = "VMware123!VMware123!"
}


############################
# Source host (for genToken script via SCP)
############################
variable "hol_source_host"     { 
  type = string  
  default = "10.1.10.130" 
}
variable "hol_source_user"     { 
  type = string  
  default = "holuser" 
}
variable "hol_source_path"     { 
  type = string  
  default = "/home/holuser/Downloads/vcf9-adv-field-lab/terraform/offline-depot/generate.sh" 
}
variable "hol_source_password" { 
  type = string  
  sensitive = true 
  default = "VMware123!VMware123!" 
}


############################
# Deploy Offline Depot Appliance OVA
############################
resource "vsphere_virtual_machine" "oda_appliance" {
  name             = var.oda_vm_name
  datacenter_id    = data.vsphere_datacenter.oda_dc.id
  datastore_id     = data.vsphere_datastore.oda_ds.id
  resource_pool_id = data.vsphere_compute_cluster.oda_cluster.resource_pool_id
  firmware = "efi"
  scsi_type = "pvscsi"

  num_cpus = 2
  memory   = 2048
  guest_id = "other3xLinux64Guest"

  # Optional: wait for guest tools network (your OVA might not use tools yet)
  wait_for_guest_net_timeout = 0

  network_interface {
    network_id   = data.vsphere_network.oda_net.id
    adapter_type = "vmxnet3"
  }

  ovf_deploy {
    local_ovf_path            = var.oda_ova_path
    disk_provisioning         = "thin"
    allow_unverified_ssl_cert = true
    ip_protocol               = "IPv4"

    # Map OVA networks to your portgroup
    ovf_network_map = {
      "dvportgroup-2001" = data.vsphere_network.oda_net.id
    }
  }

  vapp {
    properties = {
      "guestinfo.ipaddress"        = var.oda_mgmt_ip,
      "guestinfo.gateway"          = var.oda_mgmt_gateway,
      "guestinfo.netmask"          = var.oda_mgmt_netmask,
      "guestinfo.dns"              = join(",", var.oda_dns_servers),
      "guestinfo.ntp"              = join(",", var.oda_ntp_servers),
      "guestinfo.hostname"         = var.oda_hostname,
      "guestinfo.domain"           = var.oda_domain_search,
      "guestinfo.admin_password"   = var.oda_admin_password,
      "guestinfo.enable_ping"      = "True",
      "guestinfo.enable_jupyter"   = "True",
      "guestinfo.enable_ssh"       = "True",
      "guestinfo.download_token"   = "",
      "guestinfo.vcf_version"      = "9.0.1",
      "guestinfo.skip_dl"          = "False"
  }
 }

  lifecycle {
    ignore_changes = [disk, vapp[0].properties]
  }

}
############################
# Post-deploy bootstrap over SSH
############################
resource "null_resource" "oda_bootstrap" {
  depends_on = [vsphere_virtual_machine.oda_appliance]
  triggers = { always = timestamp() }

  connection {
    type     = "ssh"
    host     = var.oda_mgmt_ip
    user     = "admin"
    password = var.oda_admin_password
    timeout  = "20m"
    agent    = false
  }

  # Upload the script as a real file (no HCL parsing headaches)
  provisioner "file" {
    source      = "${path.module}/bootstrap_oda.sh"
    destination = "/home/admin/bootstrap_oda.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "set -euxo pipefail",
  
      # normalize line endings & exec bit
      "sed -i 's/\\r$//' /home/admin/bootstrap_oda.sh || true",
      "chmod +x /home/admin/bootstrap_oda.sh",
  
      # ensure log file exists (avoid hard-coded group)
      "sudo mkdir -p /var/log && sudo touch /var/log/bootstrap_oda.log && sudo chown admin:$(id -gn admin) /var/log/bootstrap_oda.log || sudo chmod 666 /var/log/bootstrap_oda.log",
  
      # wait for cloud-init to finish if present
      "if command -v cloud-init >/dev/null 2>&1; then script -q -e -c \"sudo cloud-init status --wait || true\" /dev/null; fi",
  
      # run the bootstrap **with a TTY** and full env; on failure, dump the log
      "script -q -e -c \"env SUDO_PASS='${var.oda_admin_password}' SRC_HOST='${var.hol_source_host}' SRC_USER='${var.hol_source_user}' SRC_PATH='${var.hol_source_path}' SRC_PASS='${var.hol_source_password}' bash -lc '/home/admin/bootstrap_oda.sh 2>&1 | tee -a /var/log/bootstrap_oda.log'\" /dev/null || (echo '--- BOOTSTRAP LOG ---'; sudo tail -n +200 /var/log/bootstrap_oda.log || true; exit 1)"
    ]
  }

}

