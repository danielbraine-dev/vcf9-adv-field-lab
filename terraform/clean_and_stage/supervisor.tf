#########################################################
# Supervisor Data Lookups
#########################################################

data "vsphere_datacenter" "dc" {
  name = "wld-01a-DC"
}

data "vsphere_compute_cluster" "wld01" {
  name          = "cluster-wld01-01a"
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_storage_policy" "vsan_default" {
  name = "vSAN Default Storage Policy"
}

data "vsphere_network" "mgmt_net" {
  name          = "mgmt-vds01-wld01-01a"
  datacenter_id = data.vsphere_datacenter.dc.id
}

#########################################################
# vSphere Supervisor V2 Deployment (VCF with VPC)
#########################################################

resource "vsphere_supervisor_v2" "wld01_sup" {
  # Single-zone deployments strictly use the 'cluster' attribute
  cluster = data.vsphere_compute_cluster.wld01.id
  name    = "wld01-sup"

  #######################################################
  # Control Plane (Screenshot 1: Management Network)
  #######################################################
  control_plane {
    size           = "SMALL"
    count          = 3
    storage_policy = data.vsphere_storage_policy.vsan_default.id

    network {
      backing {
        network = data.vsphere_network.mgmt_net.id
      }
      
      services {
        dns {
          servers        = ["10.1.1.1"]
          search_domains = ["site-a.vcf.lab"]
        }
        ntp {
          servers = ["10.1.1.1"]
        }
      }

      ip_management {
        dhcp_enabled    = false
        # Schema requires Gateway + Mask in CIDR notation
        gateway_address = "10.1.1.1/24" 
        
        ip_assignment {
          assignee = "NODE"
          range {
            address = "10.1.1.85"
            count   = 11
          }
        }
      }
    }
  }

  #######################################################
  # Workloads (Screenshot 2: Workload/VPC Network)
  #######################################################
  workloads {
    network {
      # Enable VPC Backing
      nsx_vpc {} 
      
      # NSX-T natively uses "default" as the ID for factory objects
      nsx_project              = "default"
      vpc_connectivity_profile = "default" 

      # Private (VPC) CIDRs
      default_private_cidr {
        address = "172.16.201.0"
        prefix  = 24
      }

      services {
        dns {
          servers        = ["10.1.1.1"]
          search_domains = ["site-a.vcf.lab"]
        }
        ntp {
          servers = ["10.1.1.1"]
        }
      }

      ip_management {
        dhcp_enabled = false
        
        # Service CIDR (10.96.0.0/23 = 512 IPs)
        ip_assignment {
          assignee = "SERVICE"
          range {
            address = "10.96.0.0"
            count   = 512
          }
        }

        # Supervisor Transit Gateway IP Block (172.16.101.0/24 = 256 IPs)
        ip_assignment {
          assignee = "EGRESS" 
          range {
            address = "172.16.101.0"
            count   = 256
          }
        }
      }
    }

    # Schema requires the edge block to be defined
    edge {
      provider = "NSX"
    }

    # Schema requires Kube API options
    kube_api_server_options {
      security {
        certificate_dns_names = [
          "site-a.vcf.lab"
        ]
      }
    }
  }
}
