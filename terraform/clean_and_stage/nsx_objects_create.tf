############################
# NSX-T: Shared Services VPC & Subnets
############################

# 1. Look up the default Project (which inherently binds to the lab's TGW)
data "nsxt_policy_project" "default" {
  display_name = "default"
}

# 2. VPC Service Profile (Handles DNS, NTP, and DHCP)
resource "nsxt_vpc_service_profile" "avi_vpc_profile" {
  display_name = "AVI-VPC-Service-Profile"
  description  = "Service profile for the Shared Services VPC"
  
  context {
    project_id = data.nsxt_policy_project.default.id
  }
  
  # Enable DHCP Server config
  dhcp_profile {
    dhcp_config_mode = "SERVER"
  }
  
  # Configure DNS Forwarder
  dns_profile {
    dns_forwarder_ips = ["10.1.1.1"]
  }
  
  # Configure explicitly defined NTP Servers
  ntp_profile {
    ntp_servers = ["10.1.1.1"]
  }
}

# 3. The Shared Services VPC
resource "nsxt_vpc" "shared_services" {
  display_name = "Shared-Services"
  description  = "VPC hosting the Avi Load Balancer Infrastructure"
  
  context {
    project_id = data.nsxt_policy_project.default.id
  }
  
  # Attach the Service Profile created above
  service_profile_id = nsxt_vpc_service_profile.avi_vpc_profile.id
  
  # We intentionally omit the Avi LB enablement here so it doesn't conflict 
  # with the manual Cloud creation in Step 8.
}

# 4. VPC Subnet: SE-mgmt
resource "nsxt_vpc_subnet" "se_mgmt" {
  display_name = "SE-mgmt"
  vpc_id       = nsxt_vpc.shared_services.id
  
  context {
    project_id = data.nsxt_policy_project.default.id
  }
  
  access_mode  = "PUBLIC" 
  
  ipv4_subnet {
    network      = "10.4.100.128/25"
    gateway_ip   = "10.4.100.254"
    dhcp_ranges  = ["10.4.100.130-10.4.100.160"]
  }
}

# 5. VPC Subnet: SE-Data_VIP
resource "nsxt_vpc_subnet" "se_data_vip" {
  display_name = "SE-Data_VIP"
  vpc_id       = nsxt_vpc.shared_services.id
  
  context {
    project_id = data.nsxt_policy_project.default.id
  }
  
  access_mode  = "PUBLIC"
  
  ipv4_subnet {
    network      = "10.4.100.0/25"
    gateway_ip   = "10.4.100.126"
    dhcp_ranges  = ["10.4.100.5-10.4.100.60"]
  }
}
