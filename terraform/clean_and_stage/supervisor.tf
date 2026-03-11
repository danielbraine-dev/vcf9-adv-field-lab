#########################################################
# Supervisor Data Lookups
#########################################################

data "vsphere_compute_cluster" "wld01" {
  name          = "cluster-wld01-01a"
  datacenter_id = data.vsphere_datacenter.avi_dc.id
}

data "vsphere_storage_policy" "vsan_default" {
  name = "vSAN Default Storage Policy"
}

data "vsphere_zone" "wld_a" {
  name = "z-wld-a"
}

# NSX Data Lookups for the VPC configuration
data "nsxt_policy_project" "default_project" {
  display_name = "Default"
}

data "nsxt_policy_vpc_connectivity_profile" "default_profile" {
  display_name = "Default VPC Connectivity Profile"
  project_id   = data.nsxt_policy_project.default_project.id
}

#########################################################
# vSphere Supervisor Deployment (VCF with Networking VPC)
#########################################################

resource "vsphere_supervisor" "wld01_sup" {
  cluster        = data.vsphere_compute_cluster.wld01.id
  storage_policy = data.vsphere_storage_policy.vsan_default.id
  zone_id        = data.vsphere_zone.wld_a.id

  # Management Network
  management_network {
    network      = data.vsphere_network.avi_net.id # mgmt-vds01-wld01-01a
    network_mode = "STATIC"
    ip_ranges {
      starting_address = "10.1.1.85"
      ip_count         = 11
    }
    subnet_mask        = "255.255.255.0"
    gateway            = "10.1.1.1"
    dns_servers        = ["10.1.1.1"]
    dns_search_domains = ["site-a.vcf.lab"]
    ntp_servers        = ["10.1.1.1"]
  }

  # Namespace/Workload Network
  namespaces_network_provider {
    nsx_vcf_vpc {
      project_id                  = data.nsxt_policy_project.default_project.id
      vpc_connectivity_profile_id = data.nsxt_policy_vpc_connectivity_profile.default_profile.id
      transit_gateway_ip_block    = "172.16.101.0/24"
      vpc_cidrs                   = ["172.16.201.0/24"]
      service_cidr                = "10.96.0.0/23"
      dns_servers                 = ["10.1.1.1"]
      ntp_servers                 = ["10.1.1.1"]
    }
  }
}
