############################################################
# VCFA cleanup (provider-level + org-level) + k8s namespace
# Pattern: import existing → set enable_vcfa_cleanup=true → apply to delete
############################################################

# Required IDs (no data sources in this provider)
variable "vcfa_org_id"      { 
  type = string 
  default = "f045fef1-4904-471e-bb5f-8157acafb18b"
}     
variable "vcfa_region_id"   { 
  type = string
  default="a289cc88-4da2-4c73-bc49-59846616c946"
}  
variable "vcfa_org_name"           { 
  type = string
  default = "showcase-all-apps" 
}
variable "vcfa_region_name"        { 
  type = string
  default = "us-west-region" 
}
variable "org_project_name"        { 
  type = string
  default = "default-project" 
}
variable "vcfa_ns_name"                 { 
  type = string
  default = "demo-namespace-vkrcg" 
}
variable "vcfa_vpc_name"       {
  type=string
  default="us-west-region-Default-VPC"
}
variable "vcfa_org_cl_name"             { 
  type = string
  default = "showcase-content-library" 
} 
variable "provider_cl_name"        { 
  type = string
  default = "provider-content-library" 
}
variable "vcfa_org_reg_net_name"        { 
  type = string  
  default = "showcase-all-appsus-west-region" 
}
variable "provider_gw_name"        { 
  type = string
  default = "provider-gateway-us-west" 
}
variable "provider_ip_space"       { 
  type = string
  default = "ip-space-us-west" 
}
variable "vcenter_fqdn_to_refresh" { 
  type = string
  default = "vc-wld01-a.site-a.vcf.lab" 
}
variable "vcfa_vcenter_id"    {
  type = string
  default="a6ee5489-8ef0-4776-afca-fa93de4c6dc7"
}
variable "vcfa_provider_gateway_id" { 
  type = string 
  default = "7727f60a-f8bb-4e76-81ba-9933dd528c6a"
}
variable "vcfa_tier0_gateway_id"  { 
  type = string 
  default=""
}
variable "vcfa_ip_space_ids"      { 
type = list(string)
default = ["6e7a4ea5-43a8-4c93-b1d3-cde61b69969e"]
}
variable "vcfa_ip_space_name"             {
  type = string
  default = "ip-space-us-west"
}
variable "vcfa_default_quota_max_ip_count"      { 
  type = number 
  default = null
}
variable "vcfa_default_quota_max_subnet_size"   { 
  type = number
  default = null 
}
variable "vcfa_default_quota_max_cidr_count"    {
  type = number
  default = null
}


############################################################
# 1) Supervisor Namespace (Org + Region + Name)
############################################################
resource "vcfa_supervisor_namespace" "project_ns" {
  count     = var.enable_vcfa_cleanup ? 0 : 1
  name      = var.vcfa_ns_name
  project_name = var.org_project_name
  region_name = var.vcfa_region_name
  vpc_name = var.vcfa_vpc_name
  zones_initial_class_config_overrides = []
  storage_classes_initial_class_config_overrieds = []
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
  storage_class_ids = var.vcfa_provider_cl_storage_class_ids
  lifecycle { prevent_destroy = false }
}

############################################################
# 4) Org Region Quota (correct type name is vcfa_org_region_quota)
############################################################
resource "vcfa_org_region_quota" "showcase_us_west" {
  count     = var.enable_vcfa_cleanup ? 0 : 1
  org_id    = var.vcfa_org_id
  region_id = var.vcfa_region_id
  supervisor_ids =
  region_vm_class_ids = 
  region_storage_policy = 
  zone_resource_allocations = 
  lifecycle { prevent_destroy = false }
}

############################################################
# 5) Org Regional Networking 
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
############################
resource "vcfa_provider_gateway" "us_west" {
  count              = var.enable_vcfa_cleanup ? 0 : 1
  region_id          = var.vcfa_region.id
  tier0_gateway_id   = var.vcfa_tier0_gateway_id
  id_space_ids       = var.vcfa_ip_space_ids
  name               = var.provider_gw_name
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
  region_id                       = var.vcfa_region_id
  default_quota_max_ip_count      = var.vcfa_default_quota_max_ip_count
  default_quota_max_subnet_size   = var.vcfa_default_quota_max_subnet_size
  default_quota_max_cidr_count    = var.vcfa_default_quota_max_cidr_count
  internal_scope {
    scope = "PROVIDER"   # <-- this is an example; copy real attrs from state
  }
  lifecycle { prevent_destroy = false }
}

############################
# 8) Region "us-west-region"
############################
resource "vcfa_region" "us_west" {
  count = var.enable_vcfa_cleanup ? 0 : 1
  name  = var.vcfa_region_name
  nsx_manager_id        = var.vcfa_nsx_manager_id
  storage_policy_names  = var.vcfa_storage_policy_names
  supervisor_ids        = var.vcfa_supervisor_ids
  lifecycle { prevent_destroy = false }
}

############################
# 9) Refresh vCenter connection "vc-wld01-a.site-a.vcf.lab"
############################

# One-shot action: refresh/test the VC connection after deletions
resource "vcfa_vcenter_refresh" "refresh" {
  vcenter_id = var.vcfa_vcenter_id
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
