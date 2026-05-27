############################
# NSX-T: Shared Services VPC & Subnets
############################

# 1. Look up the default Project
data "nsxt_policy_project" "default" {
  display_name = "default"
}

# 2. The Shared Services VPC
resource "nsxt_vpc" "shared_services" {
  display_name = "Shared-Services"
  description  = "VPC hosting the Avi Load Balancer Infrastructure"
  
  context {
    project_id = data.nsxt_policy_project.default.id
  }
}

# 3. VPC Subnet: SE-mgmt
resource "nsxt_vpc_subnet" "se_mgmt" {
  display_name = "SE-mgmt"
  
  # FIX 1: vpc_id must be inside the context block
  context {
    project_id = data.nsxt_policy_project.default.id
    vpc_id     = nsxt_vpc.shared_services.id
  }
  
  access_mode  = "PUBLIC" 
  
  # FIX 2: Define the static gateway IP directly as a list
  ip_addresses = ["10.4.100.254/25"]
  
  # FIX 3: DNS and DHCP ranges are natively handled here now
  dhcp_config {
    mode         = "DHCP_SERVER"
    dns_servers  = ["10.1.1.1"]
    dhcp_ranges  = ["10.4.100.130-10.4.100.160"]
  }
}

# 4. VPC Subnet: SE-Data_VIP
resource "nsxt_vpc_subnet" "se_data_vip" {
  display_name = "SE-Data_VIP"
  
  context {
    project_id = data.nsxt_policy_project.default.id
    vpc_id     = nsxt_vpc.shared_services.id
  }
  
  access_mode  = "PUBLIC"
  
  ip_addresses = ["10.4.100.126/25"]
  
  dhcp_config {
    mode         = "DHCP_SERVER"
    dns_servers  = ["10.1.1.1"]
    dhcp_ranges  = ["10.4.100.5-10.4.100.60"]
  }
}
