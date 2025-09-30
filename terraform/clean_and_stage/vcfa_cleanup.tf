############################################################
# VCFA cleanup (provider-level + org-level) + k8s namespace
# Pattern: import existing → set enable_vcfa_cleanup=true → apply to delete
############################################################

# Required IDs (no data sources in this provider)
variable "vcfa_org_id"      { 
  type = string 
  default = ""
}     
variable "vcfa_region_id"   { 
  type = string
  default=""
}  

############################################################
# 1) Supervisor Namespace (Org + Region + Name)
############################################################
resource "vcfa_supervisor_namespace" "project_ns" {
  count     = var.enable_vcfa_cleanup ? 0 : 1
  org_id    = var.vcfa_org_id
  region_id = var.vcfa_region_id
  name      = var.vcfa_ns_name

  lifecycle { prevent_destroy = false }
}

############################################################
# 2) Org-scoped Content Library (requires org_id + storage_class_ids)
############################################################
resource "vcfa_content_library" "org_cl" {
  count             = var.enable_vcfa_cleanup ? 0 : 1
  org_id            = var.vcfa_org_id
  name              = var.vcfa_org_cl_name
  storage_class_ids = var.vcfa_org_cl_storage_class_ids

  lifecycle { prevent_destroy = false }
}

############################
# 3) Provider-scoped Content Library "provider-content-library"
############################
resource "vcfa_content_library" "provider_cl" {
  count = var.enable_vcfa_cleanup ? 0 : 1
  name  = var.provider_cl_name
  scope = "PROVIDER"

  lifecycle { prevent_destroy = false }
}

############################################################
# 4) Org Region Quota (correct type name is vcfa_org_region_quota)
############################################################
resource "vcfa_org_region_quota" "showcase_us_west" {
  count     = var.enable_vcfa_cleanup ? 0 : 1
  org_id    = var.vcfa_org_id
  region_id = var.vcfa_region_id

  lifecycle { prevent_destroy = false }
}

############################################################
# 5) Org Regional Networking (requires provider_gateway_id)
############################################################
resource "vcfa_org_regional_networking" "showcase_us_west" {
  count               = var.enable_vcfa_cleanup ? 0 : 1
  org_id              = var.vcfa_org_id
  region_id           = var.vcfa_region_id
  name                = var.vcfa_org_reg_net_name
  provider_gateway_id = var.vcfa_provider_gateway_id

  lifecycle { prevent_destroy = false }
}


############################
# 6) Provider Gateway "provider-gateway-us-west"
# Import:
#   terraform import vcfa_provider_gateway.us_west[0] \
#     ${data.vcfa_region.us_west.id}/${var.provider_gw_name}
############################
resource "vcfa_provider_gateway" "us_west" {
  count     = var.enable_vcfa_cleanup ? 0 : 1
  region_id = data.vcfa_region.us_west.id
  name      = var.provider_gw_name

  lifecycle { prevent_destroy = false }
}

############################
# 7) Provider IP Space "ip-space-us-west"
# Import:
#   terraform import vcfa_ip_space.us_west[0] ${var.provider_ip_space}
############################
resource "vcfa_ip_space" "us_west" {
  count = var.enable_vcfa_cleanup ? 0 : 1
  name  = var.provider_ip_space

  lifecycle { prevent_destroy = false }
}

############################
# 8) Region "us-west-region"
# Import:
#   terraform import vcfa_region.us_west[0] ${var.vcfa_region_name}
############################
resource "vcfa_region" "us_west" {
  count = var.enable_vcfa_cleanup ? 0 : 1
  name  = var.vcfa_region_name

  lifecycle { prevent_destroy = false }
}

############################
# 9) Refresh vCenter connection "vc-wld01-a.site-a.vcf.lab"
############################
data "vcfa_vcenter" "target" {
  fqdn = var.vcenter_fqdn_to_refresh
}

# One-shot action: refresh/test the VC connection after deletions
resource "vcfa_vcenter_refresh" "refresh" {
  vcenter_id = data.vcfa_vcenter.target.id
  depends_on = [
    kubernetes_namespace.demo,
    vcfa_content_library.org_cl,
    vcfa_content_library.provider_cl,
    vcfa_region_quota.showcase_us_west,
    vcfa_org_regional_networking.showcase_us_west,
    vcfa_provider_gateway.us_west,
    vcfa_ip_space.us_west,
    vcfa_region.us_west
  ]
}
