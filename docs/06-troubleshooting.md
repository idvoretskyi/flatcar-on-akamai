# 6. Troubleshooting

## Can't SSH in after `apply`

1. **Key not in Ignition.** The most common cause. Afterburn on Akamai does
   **not** use Linode's managed `ssh_keys` or the disk `authorized_keys`. Verify
   your key is in the rendered config:

   ```bash
   jq '[.passwd.users[].sshAuthorizedKeys]' build/ignition.json
   ```

   If empty, set `SSH_AUTHORIZED_KEY` in `.env` and re-run `make ignition`, then
   `make apply` (Ignition only applies on **first** boot — see below).

2. **Wrong user.** Log in as `core`, not `root`: `ssh core@<ip>`.

3. **Ignition only runs once.** Ignition applies on the *first* boot of a fresh
   disk. Editing `build/ignition.json` and rebooting an existing instance does
   nothing. Re-provision: `make destroy && make apply` (or recreate the disk).

## Watching first boot

Use the Linode serial console (Lish) from the Cloud Manager or:

```bash
ssh -t <user>@lish-<region>.linode.com <linode-label>
```

- Flatcar's console defaults to **115200 8n1**. Some older Linode custom-distro
  guides use `console=ttyS0,19200`; if Lish output is garbled, that baud
  mismatch is the likely cause — confirm/adjust on first real deploy.
- Look for `coreos-metadata` / `afterburn` and `ignition` units succeeding.

## `tofu apply` errors

- **"image_id must look like private/<number>"** — run `make image` and set the
  printed id in `tofu/terraform.tfvars`.
- **Region mismatch** — the instance region must equal the image's region.
- **Auth** — `export LINODE_TOKEN=...` with Linodes RW + Images RW.

## Private networking

Enabling `private_ip = true` allocates a private IP but does **not** configure
it inside Flatcar automatically. Add an Ignition unit that reads Afterburn's
`COREOS_AKAMAI_PRIVATE_IPV4_0` and writes a systemd-networkd drop-in. With the
knuckle backend, prefer `network: static` in the headless config, or extend
`butane/flatcar.bu` with a `systemd-networkd` file referencing the private
address. (Public DHCP works with no configuration.)

## Boot loops / no boot

- Confirm the config uses `kernel = "linode/direct-disk"` and `root_device =
  "/dev/sda"`, with helpers disabled. Linode's distro/network helpers can break
  Flatcar's GRUB and networking.
- Confirm the disk `filesystem = "raw"`; a non-raw filesystem on a whole-disk
  image can corrupt the GPT layout.

## Re-rendering after config changes

```bash
make ignition          # regenerate build/ignition.json
make destroy && make apply   # first-boot only — must re-provision
```

## Offline validation (no spend)

```bash
make validate          # tofu fmt/validate + shellcheck + jq, no API calls
```
