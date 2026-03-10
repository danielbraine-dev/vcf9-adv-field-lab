############################
# Provider auth
############################
# NSX
variable "nsx_host" {
  description = "NSX Manager hostname or IP (no scheme)"
  type        = string
  default     = "nsx-wld01-a.site-a.vcf.lab"
}
variable "nsx_username" { 
  type = string
  default = "admin" 
}
variable "nsx_password" { 
  type = string
  sensitive = true
  default = "VMware123!VMware123!" 
}
variable "nsx_allow_unverified_ssl" {
  description = "Set true for lab/self-signed certs"
  type        = bool
  default     = true
}

# Avi
variable "avi_username"   { 
  type = string
  default = "admin" 
}
variable "avi_password"   { 
  type = string
  sensitive = true  
  default = "VMware123!VMware123!" 
}
variable "avi_tenant"     {
  type = string
  default = "admin" 
}
variable "avi_controller" { 
  type = string
  default = "10.1.1.200" 
}
variable "avi_version"    { 
  type = string
  default = "31.2.2" 
}
variable "ipam_provider_url" { 
  type = string
  default = null 
}
variable "dns_provider_url"  { 
  type = string
  default = null 
}



# vSphere
variable "vsphere_server"   {
  type = string
  default = "vc-wld01-a.site-a.vcf.lab" 
}
variable "vsphere_user"     { 
  type = string
  default = "administrator@wld.sso" 
}
variable "vsphere_password" { 
  type = string
  sensitive = true
  default = "VMware123!VMware123!" 
}

# Kubernetes (optional)
variable "kubeconfig_path" { 
  type = string
  default = "" 
}
variable "kube_context"    { 
  type = string
  default = "" 
}

# VCFA
variable "vcfa_endpoint" { 
  type = string
  default = "" 
}  
variable "vcfa_token"    { 
  type = string
  sensitive = true
  default = "" 
}
variable "vcfa_org_name" {
  type = string
  default= ""
}

############################
# NSX object paths and Tags
############################
variable "nsx_tag_scope" { default = "creation" }
variable "nsx_tag"       { default = "terraform-jumpstart" }

variable "t0_path" {
  description = "Policy path to the Tier-0 gateway to attach the T1 to"
  type        = string
  default     = "/infra/tier-0s/6a71e1f3-0906-4f08-a058-5f3b570a2193"
}

variable "wld1_t1_path" {
  description ="Policy path to the WLD1 Tier-1 gateway"
  type        = string
  default     = "/infra/tier-1s/67fe9bc6-0265-4fa7-97ad-fbc6014da574"
}

variable "wld1_t1_name"{
  type    = string
  default = "t1-wld-a"
}

variable "edge_cluster_path" {
  description = "Policy path to the Edge Cluster used by the T1"
  type        = string
  default     = "/infra/sites/default/enforcement-points/default/edge-clusters/853893e2-00e6-45a1-8774-6f8e136ca24b"
}

variable "overlay_tz_path" {
  description = "Policy path to the Overlay Transport Zone"
  type        = string
  default     = "/infra/sites/default/enforcement-points/default/transport-zones/25b6ebaf-41ba-4f72-b018-cff34a7a0e03"
}

variable "transport_zone_name" {
  description = "Name of WLD1 TZ"
  type        = string
  default     = "overlay-vds01-wld01-01a"
}

# Optional: if your provider version supports associating a DHCP Profile to the segment.
variable "dhcp_profile_path" {
  description = "Policy path to the DHCP Profile used for Segment Local DHCP (leave blank if not used)"
  type        = string
  default     = ""
}

############################
# vSphere objects
############################
variable "vsphere_datacenter" {
  description = "Datacenter name that contains the backing datastore"
  type        = string
  default     = "dc-a"
}

variable "content_library_datastore" {
  description = "Datastore name to back the local content library"
  type        = string
  default     = "vsan-wld01-01a"
}

variable "vsphere_cluster" {
  type = string
  default = "cluster-wld01-01a"
}

variable "vsphere_datastore" {
  type = string
  default = "vsan-wld01-01a"
}

############################
# AVI objects
############################

variable "avi_mgmt_pg" {
  type = string
  default = "mgmt-vds01-wld01-01a"
}

variable "avi_mgmt_ip" {
  type = string
  default = "10.1.1.200"
}

variable "avi_mgmt_gateway" {
  type = string
  default = "10.1.1.1"
}

variable "avi_mgmt_netmask" {
  type = string
  default = "255.255.255.0"
}

variable "avi_vm_name" {
  type = string
  default = "avi-controller01"
}

variable "avi_dns_servers" {
  type = string
  default = "10.1.1.1"
}

variable "avi_ntp_servers" {
  type = string
  default = "10.1.1.1"
}

variable "avi_domain_search" {
  type = string
  default ="site-a.vcf.lab"
}

variable "avi_admin_password" {
  type = string
  default="VMware123!VMware123!"
}
