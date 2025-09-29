############################
# NSX-T: Tier-1 SE-mgmt and related config
############################

# DHCP server/profile used by segments (server address left blank per your model)
resource "nsxt_policy_dhcp_server" "common_dhcp" {
  display_name     = "common_dhcp"
  description      = "DHCP server servicing AVI SE Segments"
  server_addresses = ["100.96.0.1/30"]
}

resource "nsxt_policy_tier1_gateway" "se_mgmt" {
  display_name       = "SE-mgmt"
  description        = "Tier-1 for SE management"
  edge_cluster_path  = var.edge_cluster_path
  dhcp_config_path   = nsxt_policy_dhcp_server.common_dhcp.path
  tier0_path         = var.t0_path
  ha_mode            = "ACTIVE_STANDBY"
  pool_allocation    = "ROUTING"

  tag {
    scope = var.nsx_tag_scope
    tag   = var.nsx_tag
  }

  route_advertisement_types = [
    "TIER1_STATIC_ROUTES",
    "TIER1_DNS_FORWARDER_IP",
    "TIER1_CONNECTED",
    "TIER1_NAT",
    "TIER1_LB_VIP",
    "TIER1_LB_SNAT"
  ]
}

# NSX-T: Segment SE-mgmt with segment-local DHCP
resource "nsxt_policy_segment" "se_mgmt" {
  display_name        = "SE-mgmt"
  transport_zone_path = var.overlay_tz_path
  connectivity_path   = nsxt_policy_tier1_gateway.se_mgmt.path

  subnet {
    cidr        = "10.10.5.1/24"
    dhcp_ranges = ["10.10.5.2-10.10.5.20"]

    dhcp_v4_config {
      server_address = "10.10.5.254/24"
      dns_servers    = ["10.1.1.1"]
      lease_time     = 86400
    }
  }

  tag {
    scope = var.nsx_tag_scope
    tag   = var.nsx_tag
  }
}


