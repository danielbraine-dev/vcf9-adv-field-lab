############################
# NSX-T: Shared Services VPC & Subnets
############################

# 1. Grab the Default Project and Connectivity Profile
data "nsxt_vpc_connectivity_profile" "default_profile" {
  context {
    project_id = "default"
  }
  display_name = "default" 
}

# 2. The Shared Services VPC
resource "nsxt_vpc" "shared_services" {
  id           = "ss-vpc" # This sets the "Short log identifier" in the UI
  display_name = "Shared-Services"
  description  = "VPC hosting shared services"
  
  context {
    project_id = "default"
  }
}

# 3. Attach the VPC to the Transit Gateway
resource "nsxt_vpc_attachment" "tgw_attach" {
  display_name            = "avi-vpc-tgw-attachment"
  vpc_path                = nsxt_vpc.shared_services.path
  connectivity_profile_id = data.nsxt_vpc_connectivity_profile.default_profile.id
  
  context {
    project_id = "default"
  }
}

# 4. VPC Subnet: SE-mgmt
resource "nsxt_vpc_subnet" "se_mgmt" {
  display_name = "SE-mgmt"
  
  context {
    project_id = "default"
    vpc_id     = nsxt_vpc.shared_services.id
  }
  
  access_mode  = "Public" 
  
  # This tells the UI to turn "Auto allocate" OFF and use this static CIDR
  ip_addresses = ["10.4.100.254/25"]
  
  # Maps to the "DHCP Server" radio button in your screenshot
  dhcp_config {
    mode = "DHCP_SERVER"
  }

  depends_on = [nsxt_vpc_attachment.tgw_attach]
}

# 5. VPC Subnet: SE-Data_VIP
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

  depends_on = [nsxt_vpc_attachment.tgw_attach]
}
