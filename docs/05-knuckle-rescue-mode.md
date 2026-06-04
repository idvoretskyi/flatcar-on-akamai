# 5. Alternative: knuckle native install (Rescue Mode)

The default path in this repo never runs an installer — it deploys the official
Flatcar image and hands Ignition in via metadata. This document describes the
**alternative**: using knuckle the way it was designed, as a bare-metal
installer, from a Linode Rescue/recovery environment.

This is **not** zero-touch and is documented for completeness. Prefer the
[default OpenTofu flow](03-deploy-opentofu.md) unless you specifically need
knuckle to partition and install onto the disk.

## When you might want this

- You want knuckle's full install path (partitioning, `flatcar-install`) rather
  than a pre-baked whole-disk image.
- You are debugging the installer itself.

## Caveats up front

- **knuckle's ISO is UEFI-only (systemd-boot).** Linode Direct Disk boots BIOS,
  so booting knuckle's ISO directly on a Linode is unreliable. The realistic
  approach is to run knuckle's **headless** install from a Linux environment
  that already boots on Linode (e.g. a rescue/recovery boot), targeting the
  instance's disk.
- This requires console/Glish interaction — inherently manual.

## Sketch of the flow

1. Create a Linode (any bootable Linux disk) and boot into a rescue/recovery
   Linux that can see the target block device.
2. Fetch a knuckle binary for the target arch.
3. Write a headless config (same schema as
   [`knuckle/config.json`](../knuckle/config.json)) but with a **real** `disk`
   path (e.g. `/dev/sda`) and `reboot: true`.
4. Run the install:

   ```bash
   sudo ./knuckle --headless --config config.json
   ```

   knuckle assembles Ignition, runs `flatcar-install -d <disk> -i <ignition>`,
   and (optionally) reboots into the freshly installed Flatcar.
5. Reconfigure the Linode's boot config to direct-disk if needed and boot.

## Why the default flow is better here

On Akamai specifically, the official image + Metadata service removes every
manual step above: no rescue boot, no console, no installer. knuckle still adds
value as the **Ignition generator** (path A) without acting as the installer.

See [knuckle's docs](https://github.com/projectbluefin/knuckle) (`HEADLESS-CONFIG.md`,
`TROUBLESHOOTING.md`) for the authoritative installer reference.

Next: [6. Troubleshooting](06-troubleshooting.md).
