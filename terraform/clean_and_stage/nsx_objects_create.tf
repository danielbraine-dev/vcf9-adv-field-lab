############################
# NSX-T: Shared Services VPC & Subnets
############################

# 1. The Shared Services VPC (Now with its own Local IP Block!)
resource "nsxt_vpc" "shared_services" {
  nsx_id       = "ss-vpc" 
  display_name = "Shared-Services"
  description  = "VPC hosting shared services"
  
  # This explicitly gives the VPC its own Private IP Block to carve from
  private_ips  = ["10.4.100.0/24"]
  
  context {
    project_id = "default"
  }
}

# 2. Attach the VPC to the Default Connectivity Profile
resource "nsxt_vpc_attachment" "tgw_attach" {
  display_name             = "avi-vpc-tgw-attachment"
  parent_path              = nsxt_vpc.shared_services.path
  
  # Wired directly to the Default profile 
  vpc_connectivity_profile = "/orgs/default/projects/default/vpc-connectivity-profiles/default"
}

# 3. VPC Subnet: SE-mgmt
resource "nsxt_vpc_subnet" "se_mgmt" {
  display_name = "SE-mgmt"
  
  context {
    project_id = "default"
    vpc_id     = nsxt_vpc.shared_services.id
  }
  
  access_mode      = "Private" 
  
  # NSX automatically carves the first /25 out of the VPC's 10.4.100.0/24 block
  ipv4_subnet_size = 25
  
  dhcp_config {
    mode = "DHCP_SERVER"
  }

  depends_on = [nsxt_vpc_attachment.tgw_attach]
}

# 4. VPC Subnet: SE-Data_VIP (Placeholder)
resource "nsxt_vpc_subnet" "se_data_vip" {
  display_name = "SE-Data_VIP"
  
  context {
    project_id = "default"
    vpc_id     = nsxt_vpc.shared_services.id
  }
  
  access_mode      = "Private"
  
  # NSX automatically carves the next /25 out of the VPC's 10.4.100.0/24 block
  ipv4_subnet_size = 25
  
  dhcp_config {
    mode = "DHCP_SERVER"
  }

  depends_on = [nsxt_vpc_attachment.tgw_attach]
}
