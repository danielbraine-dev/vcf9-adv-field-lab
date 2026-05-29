#########################################################
# NSX-T: Avi SE Management VLAN Segment
#########################################################

# Look up the existing VLAN Transport Zone
data "nsxt_policy_transport_zone" "vlan_tz" {
  display_name = "nsx-vlan-transportzone"
}

# Create the VLAN-backed Segment for SE Management
resource "nsxt_policy_segment" "se_mgmt_vlan15" {
  display_name        = "wld01-a-se-mgmt-vlan15"
  description         = "VLAN 15 segment for Avi Service Engine Management (DHCP via Technitium)"
  transport_zone_path = data.nsxt_policy_transport_zone.vlan_tz.path
  vlan_ids            = ["15"]
}

############################
# NSX-T: Shared Services VPC & Subnets
############################

# 1. The Shared Services VPC
resource "nsxt_vpc" "shared_services" {
  nsx_id       = "ss-vpc" 
  display_name = "Shared-Services"
  description  = "VPC hosting shared services"
  
  # Explicit Private IP Block for this VPC
  private_ips  = ["10.4.100.0/24"]
  
  # Bypasses the random 100.64.x.x Services Subnet
  load_balancer_vpc_endpoint {
    enabled = false
  }
  
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
  ipv4_subnet_size = 128
  
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
  ipv4_subnet_size = 128
  
  dhcp_config {
    mode = "DHCP_SERVER"
  }

  depends_on = [nsxt_vpc_attachment.tgw_attach]
}
