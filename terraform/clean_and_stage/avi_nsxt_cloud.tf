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
variable "nsxt_cloud_prefix"        { type = string, default="avi-wld01-a" }                    # e.g., "wld-"

# Management (SE mgmt) segment lives under this T1 and segment id
variable "mgmt_lr_id"               { type = string }                    # T1 logical router ID for mgmt
variable "mgmt_segment_id"          { type = string }                    # NSX segment id string for mgmt

# Data / VIP segment lives under this T1 and segment id
variable "data_lr_id"               { type = string }                    # T1 logical router ID for data/VIP
variable "data_segment_id"          { type = string }                    # NSX segment id string for data/VIP

# vCenter & Content Library
variable "content_library_name"     { type = string }                    # existing CL in vCenter
variable "vcenter_id"               { type = string }                    # name/ID label you want shown in Avi

# Names for connector users created in Avi
variable "nsxt_avi_user"            { type = string, default = "nsxt-conn-user" }
variable "vcenter_avi_user"         { type = string, default = "vcenter-conn-user" }

################################
# Lookups
################################
# NSX-T Transport Zone (by display name)
data "nsxt_transport_zone" "nsx_tr_zone" {
  display_name = var.transport_zone_name
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
# Avi NSX-T Cloud
################################
resource "avi_cloud" "nsx_t_cloud" {
  depends_on   = [avi_cloudconnectoruser.nsx_t_user]
  name         = var.nsxt_cloudname
  tenant_ref   = var.avi_tenant
  vtype        = "CLOUD_NSXT"
  obj_name_prefix = var.nsxt_cloud_prefix

  nsxt_configuration {
    nsxt_url            = var.nsxt_host
    transport_zone      = data.nsxt_transport_zone.nsx_tr_zone.id

    # Management network for Controllers/SEs (overlay segment under mgmt T1)
    management_segment {
      tier1_lr_id = var.mgmt_lr_id
      segment_id  = var.mgmt_segment_id
    }

    # Data/VIP segment(s) attached under a T1 (manual mode)
    tier1_segment_config {
      segment_config_mode = "TIER1_SEGMENT_MANUAL"
      manual {
        tier1_lrs {
          tier1_lr_id = var.data_lr_id
          segment_id  = var.data_segment_id
        }
      }
    }

    automate_dfw_rules   = "false"
    nsxt_credentials_ref = avi_cloudconnectoruser.nsx_t_user.uuid
  }
}

################################
# Register vCenter into the Cloud + Content Library
################################
resource "avi_vcenterserver" "vc_01" {
  depends_on               = [
    avi_cloudconnectoruser.vcenter_user,
    avi_cloud.nsx_t_cloud
  ]

  name                     = var.vcenter_id
  tenant_ref               = var.avi_tenant

  # Attach this vCenter to the NSX-T Cloud we just created
  cloud_ref                = avi_cloud.nsx_t_cloud.uuid

  vcenter_url              = var.vsphere_server
  vcenter_credentials_ref  = avi_cloudconnectoruser.vcenter_user.uuid

  # Select the existing vCenter Content Library (for SE image storage)
  content_lib {
    id = data.vsphere_content_library.library.id
  }
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

