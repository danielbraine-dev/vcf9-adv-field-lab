############################
# NSX-T: Shared Services VPC & Subnets
############################

# 1. Build the Connectivity Profile (The API equivalent of the green UI toggle)
resource "nsxt_vpc_connectivity_profile" "avi_profile" {
  display_name = "avi-vpc-connectivity-profile"
  
  context {
    project_id = "default"
  }
  
  # Hardcoded exactly to your VCF 9 lab's Transit Gateway path
  transit_gateway_path = "/orgs/default/projects/transit-gateways/default"
}

# 2. The Shared Services VPC
resource "nsxt_vpc" "shared_services" {
  nsx_id       = "ss-vpc" 
  display_name = "Shared-Services"
  description  = "VPC hosting shared services"
  
  context {
    project_id = "default"
  }
}

# 3. Attach the VPC to the Transit Gateway
resource "nsxt_vpc_attachment" "tgw_attach" {
  display_name             = "avi-vpc-tgw-attachment"
  parent_path              = nsxt_vpc.shared_services.path
  
  vpc_connectivity_profile = nsxt_vpc_connectivity_profile.avi_profile.path
}

# 4. VPC Subnet: SE-mgmt
resource "nsxt_vpc_subnet" "se_mgmt" {
  display_name = "SE-mgmt"
  
  context {
    project_id = "default"
    vpc_id     = nsxt_vpc.shared_services.id
  }
  
  access_mode  = "Public" 
  ip_addresses = ["10.4.100.254/25"]
  
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
