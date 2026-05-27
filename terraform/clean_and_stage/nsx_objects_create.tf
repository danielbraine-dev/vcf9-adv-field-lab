############################
# NSX-T: Shared Services VPC & Subnets
############################

# 1. The Shared Services VPC
resource "nsxt_vpc" "shared_services" {
  display_name = "Shared-Services"
  description  = "VPC hosting the Avi Load Balancer Infrastructure"
  
  context {
    # Hardcode the string to bypass the failing data lookup
    project_id = "default"
  }
}

# 2. VPC Subnet: SE-mgmt
resource "nsxt_vpc_subnet" "se_mgmt" {
  display_name = "SE-mgmt"
  
  # Both project_id and vpc_id must live inside the context block
  context {
    project_id = "default"
    vpc_id     = nsxt_vpc.shared_services.id
  }
  
  access_mode  = "Public" 
  
  ip_addresses = ["10.4.100.254/25"]
  
  dhcp_config {
    mode = "DHCP_SERVER"
  }
}

# 3. VPC Subnet: SE-Data_VIP
resource "nsxt_vpc_subnet" "se_data_vip" {
  display_name = "SE-Data_VIP"
  
  context {
    project_id = "default"
    vpc_id     = nsxt_vpc.shared_services.id
  }
  
  access_mode  = "Public"
  
  ip_addresses = ["10.4.100.126/25"]
  
  dhcp_config {
    mode = "DHCP_SERVER"
  }
}
