###############################################################################
# 1) Generate self-signed cert for the Avi Controller FQDN
###############################################################################
variable "avi_fqdn"     { 
  type = string
  default = "avi-controller01-a.site-a.vcf.lab" 
}
variable "avi_cert_name" { 
  type = string
  default = "avi-portal-cert" 
}

resource "tls_private_key" "avi" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "avi" {
  private_key_pem = tls_private_key.avi.private_key_pem
  subject { common_name = var.avi_fqdn }
  dns_names              = [var.avi_fqdn]
  validity_period_hours  = 825 * 24
  allowed_uses           = ["key_encipherment", "digital_signature", "server_auth"]
}

###############################################################################
# 2) Create Avi SSL Key+Cert object, then set as the Portal certificate
###############################################################################
resource "avi_sslkeyandcertificate" "portal" {
  name = var.avi_cert_name
  key  = tls_private_key.avi.private_key_pem
  certificate {
    certificate = tls_self_signed_cert.avi.cert_pem
  }
}

# Set Portal certificate (Avi system configuration)
resource "avi_systemconfiguration" "this" {
  portal_configuration {
    # Schema expects a LIST of refs
    sslkeyandcertificate_refs = [avi_sslkeyandcertificate.portal.url]
  }

  depends_on = [avi_sslkeyandcertificate.portal]
}
