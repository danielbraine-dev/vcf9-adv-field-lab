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
variable "vcfa_org_cl_storage_class_ids" {
  type=string
  default=""
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
variable "vcfa_nsx_manager_id"  {
  type = string
  default ="bf0495ef-e1fc-4da8-a7ff-4e7320903c5d"
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
variable "vcfa_storage_policy_names" {
  type = string
  default = ""
}
variable "vcfa_supervisor_ids" {
  type = string
  default = ""
}
##########################
# LOOKUPS
##########################
data "vcfa_vcenter" "vc" {
  name = "vc-wld01-a.site-a.vcf.lab"
}
data "vcfa_nsx_manager" "nsx_manager" {
  name = "nsx-wld01-a.site-a.vcf.lab"
}
data "vcfa_org" "system" {
  name="System"
}
data "vcfa_org" "showcase" {
  name="showcase-all-apps"
}
data "vcfa_region" "region" {
  name = var.vcfa_region_name
}
data "vcfa_region_zone" "default" {
  region_id = data.vcfa_region.region.id
  name = "z-wld-a"
}
data "vcfa_supervisor" "wld1" {
  name = "supervisor"
  vcenter_id = data.vcfa_vcenter.vc.id
  depends_on = [data.vcfa_vcenter.vc]
}
data "vcfa_storage_class" "sc" {
  region_id = data.vcfa_region.region.id
  name      = "vSAN Default Stroage Policy"
}
data "vcfa_region_storage_policy" "sp" {
  name = "default_storage_policy"
  region_id = data.vcfa_region.region.id
}
data "vcfa_region_vm_class" "region_vm_class0" {
  region_id = data.vcfa_region.region.id
  name      = "best-effort-2xlarge"
}
data "vcfa_provider_gateway" "provider_gw" {
  name = "provider-gateway-us-west"
  region_id = data.vcfa_region.region.id
}
data "vcfa_edge_cluster" "default" {
  name ="edgecl-wld-a"
  region_id = data.vcfa_region.region.id
}


############################################################
# 1) Supervisor Namespace (Org + Region + Name)
############################################################
resource "vcfa_supervisor_namespace" "project_ns" {
  count     = var.enable_vcfa_cleanup ? 1 : 0
  name      = var.vcfa_ns_name
  class_name = "small"
  project_name = var.org_project_name
  region_name = var.vcfa_region_name
  vpc_name = var.vcfa_vpc_name
  storage_classes_initial_class_config_overrides {
    limit = ""
    name = "vSAN Default Storage Policy"
  }
  zones_initial_class_config_overrides {
    cpu_limit = ""
    cpu_reservation = "0M"
    memory_limit = ""
    memory_reservation = "0Mi"
    name = "z-wld-a"
  }
  lifecycle { prevent_destroy = false }
}

############################################################
# 2) Org-scoped Content Library (requires org_id + storage_class_ids)
############################################################
resource "vcfa_content_library" "org_cl" {
  count             = var.enable_vcfa_cleanup ? 1 : 0
  org_id            = data.vcfa_org.showcase.id
  name              = var.vcfa_org_cl_name
  storage_class_ids = [
  data.vcfa_storage_class.sc.id
]
  lifecycle { prevent_destroy = false }
}

############################
# 3) Provider-scoped Content Library "provider-content-library"
############################
resource "vcfa_content_library" "provider_cl" {
  org_id                  = data.vcfa_org.system.id
  count                   = var.enable_vcfa_cleanup ? 1 : 0
  name                    = var.provider_cl_name
  storage_class_ids       = [
    data.vcfa_storage_class.sc.id
  ]
  lifecycle { prevent_destroy = false }
}

############################################################
# 4) Org Region Quota (correct type name is vcfa_org_region_quota)
############################################################
resource "vcfa_org_region_quota" "showcase_us_west" {
  count     = var.enable_vcfa_cleanup ? 1 : 0
  org_id    = data.vcfa_org.showcase.id
  region_id = data.vcfa_region.region.id
  supervisor_ids = [data.vcfa_supervisor.wld1.id]
  zone_resource_allocations {
    region_zone_id          = data.vcfa_region_zone.default.id
    cpu_limit_mhz           = 350
    cpu_reservation_mhz     = 0
    memory_limit_mib        =1200
    memory_reservation_mib  = 0
  }
  region_vm_class_ids = [
    data.vcfa_region_vm_class.region_vm_class0.id,
  ]
  region_storage_policy = {
    region_storage_policy_id = data.vcfa_region_storage_policy.sp.id
    storage_limit_mib        = 8096
  }
  
  lifecycle { prevent_destroy = false }
}

############################################################
# 5) Org Regional Networking 
############################################################
resource "vcfa_org_regional_networking" "showcase_us_west" {
  count               = var.enable_vcfa_cleanup ? 1 : 0
  org_id              = var.vcfa_org_id
  region_id           = var.vcfa_region_id
  name                = var.vcfa_org_reg_net_name
  provider_gateway_id = var.vcfa_provider_gateway_id
  edge_cluster_id     = data.vcfa.edge_cluster.default.id
  lifecycle { prevent_destroy = false }
}


############################
# 6) Provider Gateway "provider-gateway-us-west"
############################
resource "vcfa_provider_gateway" "us_west" {
  count              = var.enable_vcfa_cleanup ? 1 : 0
  description        = ""
  region_id          = var.vcfa_region_id
  tier0_gateway_id   = var.vcfa_tier0_gateway_id
  id_space_ids       = var.vcfa_ip_space_ids
  name               = var.provider_gw_name
  lifecycle { prevent_destroy = false }
}

############################
# 7) Provider IP Space "ip-space-us-west"
############################
resource "vcfa_ip_space" "us_west" {
  count                           = var.enable_vcfa_cleanup ? 1 : 0
  name                            = var.provider_ip_space
  description                     = ""
  region_id                       = var.vcfa_region_id
  external_scope                  = "0.0.0.0/0"
  default_quota_max_ip_count      = 256
  default_quota_max_subnet_size   = 24
  default_quota_max_cidr_count    = 1
  internal_scope {
    name = "scope1"
    cidr = "10.1.11.0/24"
  }
  lifecycle { prevent_destroy = false }
}

############################
# 8) Region "us-west-region"
############################
resource "vcfa_region" "us_west" {
  count = var.enable_vcfa_cleanup ? 1 : 0
  name  = var.vcfa_region_name
  nsx_manager_id        = var.vcfa_nsx_manager_id
  storage_policy_names  = ["vSAN Default Storage Policy"]
  supervisor_ids        = [data.vcfa_supervisor.wld1.id]
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
