# ----------------------------------------------------------------------------
# Zero-touch Flatcar on Akamai/Linode.
#
# Flow:
#   1. linode_instance      — created WITHOUT an image so the provider does not
#                             auto-provision a distro disk. Ignition is handed in
#                             through the Metadata service (metadata.user_data).
#   2. linode_instance_disk — written from the uploaded Flatcar private image.
#   3. linode_instance_config — boots the disk directly (linode/direct-disk),
#                             with distro/network helpers OFF so Linode does not
#                             mangle Flatcar's GRUB / networking. booted = true.
#
# Afterburn (coreos-metadata) inside the Flatcar image fetches the Ignition from
# the Metadata service on first boot and applies it. SSH keys live in Ignition.
# ----------------------------------------------------------------------------

# The disk's root_pass is required by the API when deploying from an image but
# is a no-op for Flatcar (no mutable password auth). Generate a throwaway value
# so nothing predictable is ever set.
resource "random_password" "root" {
  length  = 32
  special = true
}

resource "linode_instance" "this" {
  label      = var.label
  region     = var.region
  type       = var.instance_type
  tags       = var.tags
  private_ip = var.private_ip

  # Deliver the Ignition config out-of-band via the Metadata service. Afterburn
  # in the Flatcar image consumes this as user_data on first boot.
  metadata {
    user_data = base64encode(file(var.ignition_path))
  }

  # No `image` here on purpose: disks/configs are managed explicitly below.
}

resource "linode_instance_disk" "boot" {
  label     = "${var.label}-boot"
  linode_id = linode_instance.this.id
  size      = linode_instance.this.specs.0.disk

  image = var.image_id

  # Required-but-unused for Flatcar; kept random rather than predictable.
  root_pass = random_password.root.result

  # Whole-disk Flatcar image: keep it raw so Linode does not try to resize a
  # filesystem it does not understand.
  filesystem = "raw"
}

resource "linode_instance_config" "this" {
  label     = "${var.label}-config"
  linode_id = linode_instance.this.id

  device {
    device_name = "sda"
    disk_id     = linode_instance_disk.boot.id
  }

  # Boot the disk's own bootloader (GRUB) instead of a Linode kernel.
  kernel      = "linode/direct-disk"
  root_device = "/dev/sda"

  # Let Flatcar own the system entirely — disable every Linode helper.
  helpers {
    distro             = false
    network            = false
    modules_dep        = false
    devtmpfs_automount = false
    updatedb_disabled  = true
  }

  booted = true
}
