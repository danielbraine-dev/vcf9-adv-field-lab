############################################################
# VCFA cleanup (provider-level + org-level) + k8s namespace
# Pattern: import existing → set enable_vcfa_cleanup=true → apply to delete
############################################################

# Required IDs (no data sources in this provider)
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
variable "vcfa_ip_space_name"             {
  type = string
  default = "ip-space-us-west"
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
  name      = "cluster-wld01-01a vSAN Storage Policy"
}
data "vcfa_region_storage_policy" "sp" {
  name = "cluster-wld01-01a vSAN Storage Policy"
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
data "vcfa_ip_space" "us_west" {
  name = "ip-space-us-west"
  region_id = data.vcfa_region.region.id
}
data "vcfa_tier0_gateway" "main" {
  name    = "t0-wld-a"
  region_id = data.vcfa_region.region.id

############################################################
# 1) Supervisor Namespace (Org + Region + Name)
############################################################
resource "vcfa_supervisor_namespace" "project_ns" {
  count     = var.enable_vcfa_cleanup ? 0 : 1
  name_prefix = "wld1-sup"
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
  count             = var.enable_vcfa_cleanup ? 0 : 1
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
  count                   = var.enable_vcfa_cleanup ? 0 : 1
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
  count     = var.enable_vcfa_cleanup ? 0 : 1
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
  region_storage_policy {
    region_storage_policy_id = data.vcfa_region_storage_policy.sp.id
    storage_limit_mib        = 8096
  }
  
  lifecycle { prevent_destroy = false }
}

############################################################
# 5) Org Regional Networking 
############################################################
resource "vcfa_org_regional_networking" "showcase_us_west" {
  count               = var.enable_vcfa_cleanup ? 0 : 1
  org_id              = data.vcfa_org.showcase.id
  region_id           = data.vcfa_region.region.id
  name                = var.vcfa_org_reg_net_name
  provider_gateway_id = data.vcfa_provider_gateway.provider_gw.id
  edge_cluster_id     = data.vcfa_edge_cluster.default.id
  lifecycle { prevent_destroy = false }
}


############################
# 6) Provider Gateway "provider-gateway-us-west"
############################
resource "vcfa_provider_gateway" "us_west" {
  count              = var.enable_vcfa_cleanup ? 0 : 1
  description        = ""
  region_id          = data.vcfa_region.region.id
  tier0_gateway_id   = data.vcfa_tier0_gateway.main.id
  ip_space_ids       = [data.vcfa_ip_space.us_west.id]
  name               = var.provider_gw_name
  lifecycle { prevent_destroy = false }
}

############################
# 7) Provider IP Space "ip-space-us-west"
############################
resource "vcfa_ip_space" "us_west" {
  count                           = var.enable_vcfa_cleanup ? 0 : 1
  name                            = var.provider_ip_space
  description                     = ""
  region_id                       = data.vcfa_region.region.id
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
  count = var.enable_vcfa_cleanup ? 0 : 1
  name  = var.vcfa_region_name
  nsx_manager_id        = data.vcfa_nsx_manager.nsx_manager.id
  storage_policy_names  = ["vSAN Default Storage Policy"]
  supervisor_ids        = [data.vcfa_supervisor.wld1.id]
  lifecycle { prevent_destroy = false }
}
