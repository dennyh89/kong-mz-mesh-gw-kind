# Create a new Control Plane
resource "konnect_gateway_control_plane" "mesh-ingress" {
  name         = "mesh-ingress"
  description  = "This gateway is used to ingress traffic into the mesh. It is a delegated gateway."
  cluster_type = "CLUSTER_TYPE_HYBRID"
  auth_type    = "pinned_client_certs"

#   proxy_urls = [
#     {
#       host     = "example.com",
#       port     = 443,
#       protocol = "https"
#     }
#   ]
}


# Create Dataplane with local certs

resource "konnect_gateway_data_plane_client_certificate" "local_gw" {
  cert             = tls_locally_signed_cert.local_gw.cert_pem
  control_plane_id = konnect_gateway_control_plane.mesh-ingress.id
}

# Creating local certs

resource "tls_private_key" "local_ca" {
  algorithm = "RSA"
}
#
resource "local_file" "local_ca_key" {
  content  = tls_private_key.local_ca.private_key_pem
  filename = "${path.module}/certs/localCA.key"
}


resource "tls_self_signed_cert" "local_ca" {
  private_key_pem = tls_private_key.local_ca.private_key_pem

  is_ca_certificate = true

  subject {
    country             = "DE"
    common_name         = "Local Root CA"
  }

  validity_period_hours = 43800 //  1825 days or 5 years

  allowed_uses = [
    "digital_signature",
    "cert_signing",
    "crl_signing",
  ]
}

resource "local_file" "local_ca_cert" {
  content  = tls_self_signed_cert.local_ca.cert_pem
  filename = "${path.module}/certs/localCA.crt"
}

# Create private key for server certificate 
resource "tls_private_key" "local_gw" {
  algorithm = "RSA"
}

resource "local_file" "local_gw" {
  content  = tls_private_key.local_gw.private_key_pem
  filename = "${path.module}/certs/local_gw.key"
}

# Create CSR for for server certificate 
resource "tls_cert_request" "local_gw" {

  private_key_pem = tls_private_key.local_gw.private_key_pem

  dns_names = ["local-gw"]

  subject {
    country = "DE"
    common_name         = "local_gw"
  }
}

# Sign Server Certificate by Private CA 
resource "tls_locally_signed_cert" "local_gw" {
  // CSR by the development servers
  cert_request_pem = tls_cert_request.local_gw.cert_request_pem
  // CA Private key 
  ca_private_key_pem = tls_private_key.local_ca.private_key_pem
  // CA certificate
  ca_cert_pem = tls_self_signed_cert.local_ca.cert_pem

  validity_period_hours = 43800

  allowed_uses = [
    "digital_signature",
    "key_encipherment",
    "server_auth",
    "client_auth",
  ]
}

resource "local_file" "local_gw_cert" {
  content  = tls_locally_signed_cert.local_gw.cert_pem
  filename = "${path.module}/certs/local_gw.crt"
}