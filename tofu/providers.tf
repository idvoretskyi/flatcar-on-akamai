# The Linode provider reads its token from the LINODE_TOKEN environment
# variable, so no secret is ever written to a .tf file. Export it before
# running OpenTofu:  export LINODE_TOKEN=...
provider "linode" {
  # token = via LINODE_TOKEN env var

  # Avoid surprise reboots when adjusting a booted config; this stack manages
  # boot explicitly through linode_instance_config.booted.
  skip_implicit_reboots = true
}

provider "random" {}
