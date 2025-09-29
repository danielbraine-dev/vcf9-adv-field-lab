###############################################################################
# 1) Generate self-signed cert for the Avi Controller FQDN
###############################################################################
variable "avi_fqdn"     { type = string, default = "avi.lab.local" }
variable "avi_cert_name" { type = string, default = "avi-portal-cert" }

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

# Assign to System Configuration → Portal certificate
resource "avi_systemconfiguration" "this" {
  portal_configuration {
    ssl_key_and_certificate_ref = avi_sslkeyandcertificate.portal.url
  }
  # (Optionally set ntp/dns/etc if you manage them here)
  depends_on = [avi_sslkeyandcertificate.portal]
}

###############################################################################
# 3) Import the same PEM into NSX trust so NSX trusts the Avi portal
###############################################################################
resource "nsxt_policy_certificate" "avi_portal" {
  display_name = var.avi_cert_name
  pem_encoded  = tls_self_signed_cert.avi.cert_pem
}
