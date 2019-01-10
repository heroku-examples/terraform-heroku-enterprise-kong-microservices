variable "name" {
  type = "string"
}

variable "dns_zone" {
  type        = "string"
  description = "DNS zone for new records (must already be setup in the DNSimple account)"
}

variable "heroku_enterprise_team" {
  type = "string"
}

variable "heroku_private_region" {
  type    = "string"
  default = "oregon"
}

locals {
  kong_app_name           = "${var.name}-proxy"
  kong_base_url           = "https://${local.kong_app_name}.${var.dns_zone}"
  kong_insecure_base_url  = "http://${local.kong_app_name}.herokuapp.com"
  kong_admin_uri          = "${local.kong_base_url}/kong-admin"
  kong_insecure_admin_uri = "${local.kong_insecure_base_url}/kong-admin"
}

provider "dnsimple" {
  version = "~> 0.1"
}

provider "heroku" {
  version = "~> 1.7"
}

provider "kong" {
  version = "~> 1.9"

  # Optional: use insecure until DNS is ready at dnsimple
  # kong_admin_uri = "${local.kong_insecure_admin_uri}"
  kong_admin_uri = "${local.kong_admin_uri}"
  kong_api_key   = "${random_id.kong_admin_api_key.b64_url}"
}

provider "random" {
  version = "~> 2.0"
}

resource "random_id" "kong_admin_api_key" {
  byte_length = 32
}

# Private Space

resource "heroku_space" "default" {
  name         = "${var.name}"
  organization = "${var.heroku_enterprise_team}"
  region       = "${var.heroku_private_region}"
}

# Proxy app

resource "heroku_app" "kong" {
  name  = "${local.kong_app_name}"
  space = "${heroku_space.default.name}"
  acm   = true

  config_vars {
    KONG_HEROKU_ADMIN_KEY = "${random_id.kong_admin_api_key.b64_url}"
  }

  organization = {
    name = "${var.heroku_enterprise_team}"
  }

  region = "${var.heroku_private_region}"
}

resource "heroku_domain" "kong" {
  app        = "${heroku_app.kong.name}"
  hostname   = "${heroku_app.kong.name}.${var.dns_zone}"
  depends_on = ["heroku_build.kong"]
}

resource "dnsimple_record" "kong" {
  domain = "${var.dns_zone}"
  name   = "${heroku_app.kong.name}"
  value  = "${heroku_domain.kong.cname}"
  type   = "CNAME"
  ttl    = 30
}

resource "heroku_addon" "kong_pg" {
  app  = "${heroku_app.kong.name}"
  plan = "heroku-postgresql:private-0"
}

# The Kong Provider is not yet compatible with Kong 1.0 (buildpack & app v7.0),
# so instead use 0.14 (buildpack & app v6.0).
resource "heroku_build" "kong" {
  app        = "${heroku_app.kong.name}"
  buildpacks = ["https://github.com/heroku/heroku-buildpack-kong#v6.0.0"]
  depends_on = ["heroku_addon.kong_pg"]

  source = {
    # This app uses a community buildpack, set it in `buildpacks` above.
    url     = "https://github.com/heroku/heroku-kong/archive/v6.0.1.tar.gz"
    version = "v6.0.1"
  }
}

resource "heroku_formation" "kong" {
  app        = "${heroku_app.kong.name}"
  type       = "web"
  quantity   = 1
  size       = "Private-S"
  depends_on = ["heroku_build.kong", "dnsimple_record.kong"]

  provisioner "local-exec" {
    # Optional: use insecure until DNS is ready at dnsimple
    # command = "./bin/kong-health-check ${local.kong_insecure_base_url}/kong-admin"
    command = "./bin/kong-health-check ${local.kong_base_url}/kong-admin"
  }
}

# Internal app w/ proxy config

resource "heroku_app" "wasabi" {
  name             = "${var.name}-wasabi"
  space            = "${heroku_space.default.name}"
  internal_routing = true

  organization = {
    name = "${var.heroku_enterprise_team}"
  }

  region = "${var.heroku_private_region}"
}

resource "heroku_build" "wasabi" {
  app        = "${heroku_app.wasabi.name}"
  buildpacks = ["https://github.com/heroku/heroku-buildpack-nodejs"]

  source = {
    # This app uses a community buildpack, set it in `buildpacks` above.
    url     = "https://github.com/mars/wasabi-internal/archive/v1.0.0.tar.gz"
    version = "v1.0.0"
  }
}

resource "heroku_formation" "wasabi" {
  app        = "${heroku_app.wasabi.name}"
  type       = "web"
  quantity   = 1
  size       = "Private-S"
  depends_on = ["heroku_build.wasabi"]
}

resource "kong_service" "wasabi" {
  name       = "wasabi"
  protocol   = "http"
  host       = "${heroku_app.wasabi.name}.herokuapp.com"
  port       = 80
  depends_on = ["heroku_formation.kong"]
}

resource "kong_route" "wasabi_hostname" {
  protocols  = ["https"]
  hosts      = [ "${heroku_app.wasabi.name}.${var.dns_zone}" ]
  strip_path = true
  service_id = "${kong_service.wasabi.id}"
}

resource "heroku_domain" "wasabi" {
  # The internal app's public DNS name is created on the Kong proxy.
  app        = "${heroku_app.kong.name}"
  hostname   = "${heroku_app.wasabi.name}.${var.dns_zone}"
  depends_on = ["heroku_build.kong"]
}

resource "dnsimple_record" "wasabi" {
  domain = "${var.dns_zone}"
  name   = "${heroku_app.wasabi.name}"
  value  = "${heroku_domain.wasabi.cname}"
  type   = "CNAME"
  ttl    = 30
}

output "wasabi_backend_url" {
  value = "https://${heroku_app.wasabi.name}.herokuapp.com"
}

output "wasabi_public_url" {
  # Optional: use insecure until DNS is ready at dnsimple
  # value = "${local.kong_insecure_base_url}/wasabi"
  value = "https://${heroku_app.wasabi.name}.${var.dns_zone}"
}
