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
  default = "31.1.2" 
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

############################
# NSX object paths and Tags
############################
variable "nsx_tag_scope" { default = "creation" }
variable "nsx_tag"       { default = "terraform-jumpstart" }

variable "t0_path" {
  description = "Policy path to the Tier-0 gateway to attach the T1 to"
  type        = string
  default     = "/infra/tier-0s/f2d56669-12c2-42b3-aa7a-8f57340665e5"
}

variable "wld1_t1_path" {
  description ="Policy path to the WLD1 Tier-1 gateway"
  type        = string
  default     = "/infra/tier-1s/349361ff-2844-4ad3-9f03-6ab52b47f5af"
}

variable "wld1_t1_name"{
  type    = string
  default = "t1-wld-a"
}

variable "edge_cluster_path" {
  description = "Policy path to the Edge Cluster used by the T1"
  type        = string
  default     = "/infra/sites/default/enforcement-points/default/edge-clusters/55fd1616-197f-42ea-bcad-31402378a01c"
}

variable "overlay_tz_path" {
  description = "Policy path to the Overlay Transport Zone"
  type        = string
  default     = "/infra/sites/default/enforcement-points/default/transport-zones/1b3a2f36-bfd1-443e-a0f6-4de01abc963e"
}

variable "transport_zone_name" {
  description = "Name of WLD1 TZ"
  type        = string
  default     = "overlay-tz-nsx-wld01-a"
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
  default     = "wld-01a-DC"
}

variable "content_library_datastore" {
  description = "Datastore name to back the local content library"
  type        = string
  default     = "cluster-wld01-01a-vsan01"
}

############################
# VCFA cleanup controls & names
############################
variable "enable_vcfa_cleanup" {
  description = "Gate to actually manage (delete) imported VCFA resources"
  type        = bool
  default     = true
}


