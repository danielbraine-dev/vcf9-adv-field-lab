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
  
  context {
    project_id = data.nsxt_policy_project.default.id
    vpc_id     = nsxt_vpc.shared_services.id
  }
  
  access_mode  = "Public" 
  
  # NSX IPAM will automatically calculate the DHCP range based on this /25
  ip_addresses = ["10.4.100.254/25"]
  
  dhcp_config {
    mode = "DHCP_SERVER"
  }
}

# 4. VPC Subnet: SE-Data_VIP
resource "nsxt_vpc_subnet" "se_data_vip" {
  display_name = "SE-Data_VIP"
  
  context {
    project_id = data.nsxt_policy_project.default.id
    vpc_id     = nsxt_vpc.shared_services.id
  }
  
  access_mode  = "Public"
  
  # NSX IPAM will automatically calculate the DHCP range based on this /25
  ip_addresses = ["10.4.100.126/25"]
  
  dhcp_config {
    mode = "DHCP_SERVER"
  }
}
