############################
# Provider auth
############################
variable "nsx_host" {
  description = "NSX Manager hostname or IP (no scheme)"
  type        = string
}
variable "nsx_username" { type = string }
variable "nsx_password" { type = string, sensitive = true }
variable "nsx_allow_unverified_ssl" {
  description = "Set true for lab/self-signed certs"
  type        = bool
  default     = true
}

variable "vsphere_server"  { type = string, default = "vc.lab.local" }
variable "vsphere_user"    { type = string, default = "administrator@vsphere.local" }
variable "vsphere_password"{ type = string, sensitive = true, default = "" }

variable "kubeconfig_path" { type = string, default = "" }
variable "kube_context"    { type = string, default = "" }

variable "vcfa_endpoint"   { type = string, default = "" }
variable "vcfa_token"      { type = string, sensitive = true, default = "" }

############################
# NSX object paths and Tags
############################
variable "nsx_tag_scope" {
  default = "creation"
}

variable "nsx_tag" {
  default = "terraform-jumpstart"
}

variable "t0_path" {
  description = "Policy path to the Tier-0 gateway to attach the T1 to"
  type        = string
  default     = "/infra/tier-0s/f2d56669-12c2-42b3-aa7a-8f57340665e5"
}

variable "edge_cluster_path" {
  description = "Policy path to the Edge Cluster used by the T1"
  type        = string
  # Confirm/adjust if your site/enforcement point is non-default
  default     = "/infra/sites/default/enforcement-points/default/edge-clusters/55fd1616-197f-42ea-bcad-31402378a01c"
}

variable "overlay_tz_path" {
  description = "Policy path to the Overlay Transport Zone"
  type        = string
  default     = "/infra/sites/default/enforcement-points/default/transport-zones/1b3a2f36-bfd1-443e-a0f6-4de01abc963e"
}

# Optional: if your provider version supports associating a DHCP Profile
# (created under Networking Profiles > DHCP) to the segment.
variable "dhcp_profile_path" {
  description = "Policy path to the DHCP Profile used for Segment Local DHCP (leave blank if not used)"
  type        = string
  default     = ""
}
