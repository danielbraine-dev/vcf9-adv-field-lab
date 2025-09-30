/*******************************
 * avi_nsx_cloud.tf
 * - Creates Avi CloudConnector users (NSX-T & vCenter)
 * - Creates Avi NSX-T Cloud
 * - Registers vCenter to that Cloud and selects Content Library
 *******************************/

################################
# Variables
################################
variable "nsxt_cloudname"           { type = string }                    # e.g., "nsxt-cloud"
variable "nsxt_cloud_prefix"        { 
  type = string
  default="avi-wld01-a" 
}
# Management (SE mgmt) segment lives under this T1 and segment id
variable "mgmt_lr_id"               { type = string }                    # T1 logical router ID for mgmt
variable "mgmt_segment_id"          { type = string }                    # NSX segment id string for mgmt

# Data / VIP segment lives under this T1 and segment id
variable "data_segment_name"          { 
  type = string
  default="SE-Data_VIP"
}                   

# Names for connector users created in Avi
variable "nsxt_avi_user"            { 
  type = string
  default = "nsxt-conn-user" 
}
variable "vcenter_avi_user"         { 
  type = string
  default = "vcenter-conn-user" 
}

# IPAM/DNS + SE Group specifics
variable "vip_network_name"         { 
  type = string
  default = "Dummy-Net"
}                    
variable "ipam_dns_name"            { 
  type = string  
  default = "avi-internal-ipamdns" 
}
variable "se_group_name"            { 
  type = string 
  default = "wld1-se-group" 
}
variable "se_ha_mode"               { 
  type = string
  default = "HA_MODE_SHARED" 
}
variable "se_min"                   { 
  type = number
  default = 1 
}
variable "se_max"                   { 
  type = number
  default = 2 
}
variable "se_name_prefix"           { 
  type = string
  default = "wld1-sup-se-" 
}

# Break the Cloud<->IPAM cycle by deferring IPAM attach to Pass B
variable "attach_ipam_now"          { 
  type = bool
  default = false 
}


################################
# Lookups
################################
# NSX-T Transport Zone (by display name)
data "nsxt_policy_transport_zone" "nsx_tr_zone" {
  display_name = var.transport_zone_name
}
# NSX-T Data T1  (by display name)
data "nsxt_policy_tier1_gateway" "data_vip_t1" {
  display_name = var.wld1_t1_name
}
# Data Segment ID
data "nsxt_policy_segment" "se_data_vip" {
  display_name = var.data_segment_name
}

################################
# Cloud connector users in Avi
################################
# NSX-T user (credentials stored in Avi)
resource "avi_cloudconnectoruser" "nsx_t_user" {
  name       = var.nsxt_avi_user
  tenant_ref = var.avi_tenant

  nsxt_credentials {
    username = var.nsx_username
    password = var.nsx_password
  }
}

# vCenter user (credentials stored in Avi)
resource "avi_cloudconnectoruser" "vcenter_user" {
  name       = var.vcenter_avi_user
  tenant_ref = var.avi_tenant

  vcenter_credentials {
    username = var.vsphere_user
    password = var.vsphere_password
  }
}

################################
# Avi NSX-T Cloud (Pass A creates without IPAM, Pass B updates WITH IPAM)
################################
resource "avi_cloud" "nsx_t_cloud" {
  depends_on   = [avi_cloudconnectoruser.nsx_t_user]
  name         = var.nsxt_cloudname
  tenant_ref   = var.avi_tenant
  vtype        = "CLOUD_NSXT"
  obj_name_prefix = var.nsxt_cloud_prefix

  nsxt_configuration {
    nsxt_url            = var.nsx_host
    transport_zone      = data.nsxt_transport_zone.nsx_tr_zone.path

    # Management network for Controllers/SEs (overlay segment under mgmt T1)
    management_segment {
      tier1_lr_id = nsxt_policy_tier1_gateway.se_mgmt.id
      segment_id  = nsxt_policy_segment.se_mgmt.id
    }

    # Data/VIP segment(s) attached under a T1 (manual mode)
    tier1_segment_config {
      segment_config_mode = "TIER1_SEGMENT_MANUAL"
      manual {
        tier1_lrs {
          tier1_lr_id = data.nsxt_policy_tier1_gateway.data_vip_t1.id
          segment_id  = data.nsxt_policy_segment.se_data_vip.id
        }
      }
    }

    automate_dfw_rules   = false
    nsxt_credentials_ref = avi_cloudconnectoruser.nsx_t_user.uuid
  }
  # Attach IPAM/DNS only when attach_ipam_now=true (Pass B)
  ipam_provider_ref = var.ipam_provider_url
  dns_provider_ref  = var.dns_provider_url
}

################################
# Register vCenter into the Cloud + Content Library
################################
resource "avi_vcenterserver" "vc_01" {
  depends_on               = [
    avi_cloudconnectoruser.vcenter_user,
    avi_cloud.nsx_t_cloud
  ]

  name                     = var.vsphere_server
  tenant_ref               = var.avi_tenant

  # Attach this vCenter to the NSX-T Cloud we just created
  cloud_ref                = avi_cloud.nsx_t_cloud.uuid

  vcenter_url              = var.vsphere_server
  vcenter_credentials_ref  = avi_cloudconnectoruser.vcenter_user.uuid

  # Select the existing vCenter Content Library (for SE image storage)
  content_lib {
    id = vsphere_content_library.avi_se_cl.id
  }
}

################################
# Discover VIP network after Cloud exists (Pass B)
################################
data "avi_network" "vip" {
  name      = var.vip_network_name
  cloud_ref = avi_cloud.nsx_t_cloud.url
  depends_on = [avi_cloud.nsx_t_cloud]
}

################################
# IPAM/DNS profile (internal) using the discovered VIP network (Pass B)
################################
resource "avi_ipamdnsproviderprofile" "internal" {
  name = var.ipam_dns_name
  type = "IPAMDNS_TYPE_INTERNAL_DNS"

  internal_profile {
    usable_network_refs = [data.avi_network.vip.url]
  }

  depends_on = [data.avi_network.vip]
}

################################
# Service Engine Group (Pass B)
################################
resource "avi_serviceenginegroup" "default" {
  name      = var.se_group_name
  cloud_ref = avi_cloud.nsx_t_cloud.uuid

  ha_mode        = var.se_ha_mode
  min_se         = var.se_min
  max_se         = var.se_max
  se_name_prefix = var.se_name_prefix

  # Ensure vCenter is registered before we start placing SEs
  depends_on = [
    avi_vcenterserver.vc_01,
    avi_cloud.nsx_t_cloud
  ]
}


################################
# Helpful outputs
################################
output "avi_nsx_cloud_uuid" {
  value       = avi_cloud.nsx_t_cloud.uuid
  description = "UUID of the Avi NSX-T Cloud"
}

output "avi_vcenter_uuid" {
  value       = avi_vcenterserver.vc_01.uuid
  description = "UUID of the registered vCenter in Avi"
}

output "avi_ipam_profile_url" {
  value       = avi_ipamdnsproviderprofile.internal.url
  description = "URL/ref of the IPAM/DNS profile"
}

output "avi_se_group_uuid" {
  value       = avi_serviceenginegroup.default.uuid
  description = "UUID of the Service Engine Group"
}


