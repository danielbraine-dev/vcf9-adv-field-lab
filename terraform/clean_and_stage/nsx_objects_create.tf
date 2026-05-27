############################
# NSX-T: Shared Services VPC & Subnets
############################

# 1. The Shared Services VPC
resource "nsxt_vpc" "shared_services" {
  display_name = "Shared-Services"
  description  = "VPC hosting the Avi Load Balancer Infrastructure"
  
  # By omitting the 'context' block, NSX automatically deploys this 
  # into the default infrastructure space and binds it to the default TGW.
}

# 2. VPC Subnet: SE-mgmt
resource "nsxt_vpc_subnet" "se_mgmt" {
  display_name = "SE-mgmt"
  
  # NSX policy resources link via "path", not "id"
  vpc_path     = nsxt_vpc.shared_services.path
  
  access_mode  = "Public" 
  
  ip_addresses = ["10.4.100.254/25"]
  
  dhcp_config {
    mode = "DHCP_SERVER"
  }
}

# 3. VPC Subnet: SE-Data_VIP
resource "nsxt_vpc_subnet" "se_data_vip" {
  display_name = "SE-Data_VIP"
  
  vpc_path     = nsxt_vpc.shared_services.path
  
  access_mode  = "Public"
  
  ip_addresses = ["10.4.100.126/25"]
  
  dhcp_config {
    mode = "DHCP_SERVER"
  }
}
