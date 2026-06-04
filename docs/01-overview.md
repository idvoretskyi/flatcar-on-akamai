# 1. Overview & architecture

## Goal

Deploy Flatcar Container Linux on Akamai/Linode with the least friction
possible: declarative, repeatable, and zero-touch after a one-time image upload.

## Why not the "custom distribution" rescue-mode flow?

Linode's classic [custom distribution guide](https://www.linode.com/docs/guides/install-a-custom-distribution/)
boots into Rescue Mode, dd's an image over Glish, and hand-edits a config. It
works, but it is manual and hard to automate.

Flatcar publishes an **official Akamai image** that includes
[Afterburn](https://coreos.github.io/afterburn/) with Akamai/Linode support
(`coreos-metadata.service`, `COREOS_AKAMAI_*` variables). That means the node can
read its Ignition config from the **Linode Metadata service** at first boot —
exactly the cloud-init-style flow we want, and fully expressible in OpenTofu.

## The pieces

| Component | Role |
| --------- | ---- |
| Official Flatcar Akamai image | Bootable whole-disk image with Afterburn + Ignition support. Uploaded once as a private image. |
| Linode Metadata service | Delivers `user_data` (our Ignition) to the booting instance. |
| Ignition (from knuckle) | Declarative first-boot config: users, SSH keys, hostname, units. |
| OpenTofu | Creates the instance, disk (from the image), and a direct-disk boot config; passes Ignition via `metadata.user_data`. |

## Boot sequence

1. OpenTofu creates a `linode_instance` **without an image** (so no distro disk
   is auto-provisioned) but **with** `metadata.user_data = base64(ignition)`.
2. A `linode_instance_disk` is written from the uploaded `private/<id>` image.
3. A `linode_instance_config` boots that disk with `kernel = linode/direct-disk`
   and all Linode helpers disabled, so Flatcar's own GRUB and networking run.
4. On first boot Afterburn fetches `user_data` from the Metadata service and
   Ignition applies it (users, SSH keys, hostname).
5. `ssh core@<ip>`.

## Design decisions

- **knuckle as the Ignition generator** (`--emit-ignition`) keeps a single,
  validated config schema shared with the bare-metal install path. A standalone
  `butane` fallback exists for Go-less hosts.
- **SSH keys travel in Ignition.** Afterburn on Akamai does not read Linode's
  managed keys, so this is the only reliable delivery channel.
- **direct-disk + helpers off.** Flatcar is an immutable, self-contained OS; we
  do not let Linode inject a kernel or rewrite networking.

Next: [2. Image upload](02-image-upload.md).
