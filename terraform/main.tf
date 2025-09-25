############################
# Local exec bootstrap
############################
resource "null_resource" "bootstrap_local" {
  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-lc"]
    command = <<'EOF'
sudo sed -i '0,/multiverse/s/multiverse/multiverse main restricted universe/' /etc/apt/sources.list.d/ubuntu.sources \
  && sudo apt update -y \
  && sudo apt install git -y \
  && cd ~/Downloads \
  && git clone https://github.com/daniel-braine.dev/vcf9-adv-field-lab.git \
  && cd vcf9-adv-field-lab \
  && chmod +x setup.sh \
  && ./setup.sh
EOF
  }
}

############################
# NSX-T: Tier-1 SE-mgmt
############################
resource "nsxt_policy_tier1_gateway" "se_mgmt" {
  display_name     = "SE-mgmt"
  description      = "Tier-1 for SE management"
  tier0_path       = var.t0_path
  edge_cluster_path = var.edge_cluster_path
  ha_mode          = "ACTIVE_STANDBY"

  # Router advertisement types as requested:
  route_advertisement_types = [
    "TIER1_STATIC_ROUTES",
    "TIER1_DNS_FORWARDER_IP",
    "TIER1_CONNECTED",
    "TIER1_NAT",
    "TIER1_LB_VIP",
    "TIER1_LB_SNAT"
  ]
}

############################
# NSX-T: Segment SE-mgmt with segment-local DHCP
############################
resource "nsxt_policy_segment" "se_mgmt" {
  display_name        = "SE-mgmt"
  transport_zone_path = var.overlay_tz_path
  connectivity_path   = nsxt_policy_tier1_gateway.se_mgmt.path

  # Optional: associate a DHCP profile used for Local DHCP Server.
  # Some provider versions expose this via a dhcp_config block. If your
  # version doesn't support it, leave it commented as the segment-local
  # config below still applies; just ensure the profile exists in NSX.
  # dhcp_config {
  #   resource_type     = "SegmentDhcpV4Config"
  #   dhcp_profile_path = var.dhcp_profile_path
  # }

  subnet {
    # Segment gateway (your interface/gateway IP for the subnet)
    cidr = "10.10.5.1/24"

    # Segment-embedded DHCP (Local DHCP Server on the segment)
    dhcp_ranges = ["10.10.5.2-10.10.5.20"]

    dhcp_v4_config {
      # This is the *segment-local* DHCP server IP (per your spec)
      server_address = "10.10.5.254/24"
      dns_servers    = ["10.1.1.1"]
      # lease_time   = 86400 # (optional) seconds
    }
  }

  # Attach to your overlay TZ; no VLAN since it's overlay.
  # Additional advanced_config, tags, etc. can be added as needed.
}
