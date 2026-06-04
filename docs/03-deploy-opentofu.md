# 3. Deploy with OpenTofu

## Prerequisites

- `make image` done; `image_id` known.
- `make ignition` done; `build/ignition.json` exists
  (see [4. Ignition](04-ignition-knuckle.md)).
- `export LINODE_TOKEN=...` with **Linodes: Read/Write** and **Images: Read/Write**.
- `tofu/terraform.tfvars` with at least `image_id` and `region`.

## Apply

```bash
make init      # tofu init
make plan      # review
make apply     # creates the instance — this is when billing starts
make ssh       # ssh core@<ip>
```

## What gets created

| Resource | Purpose |
| -------- | ------- |
| `random_password.root` | Throwaway disk `root_pass` (required by the API, no-op for Flatcar). |
| `linode_instance.this` | The Linode. No `image`; carries `metadata.user_data` = base64 Ignition. |
| `linode_instance_disk.boot` | Disk written from the `private/<id>` image, `filesystem = raw`. |
| `linode_instance_config.this` | `kernel = linode/direct-disk`, helpers off, `booted = true`. |

## Key configuration details

- **`metadata.user_data`** is `base64encode(file(var.ignition_path))`. Afterburn
  reads it on first boot.
- **No `image` on the instance.** Setting it would make the provider create its
  own distro disk. We manage the disk/config explicitly instead.
- **`filesystem = "raw"`** on the boot disk: the Flatcar image is a whole-disk
  (GPT) image; raw prevents Linode from trying to resize a filesystem it does
  not understand.
- **Helpers all off** (`distro`, `network`, `modules_dep`, `devtmpfs_automount`)
  except `updatedb_disabled = true`. Flatcar manages its own boot and network.

## Variables

See [`tofu/variables.tf`](../tofu/variables.tf). Common overrides in
`terraform.tfvars`: `instance_type`, `region`, `label`, `tags`, `private_ip`.

## Tear down

```bash
make destroy
```

Next: [4. Ignition generation](04-ignition-knuckle.md).
