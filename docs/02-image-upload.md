# 2. Image upload (one-time)

The official Flatcar Akamai image must be uploaded to your account once as a
private, metadata-aware image. OpenTofu then references it by id.

## Prerequisites

- `linode-cli` configured (`linode-cli configure`) or `LINODE_TOKEN` exported
  with **Images: Read/Write**.
- `wget`, `gzip`, `du`.
- `.env` with `CHANNEL`, `REGION`, `LABEL` set.

## Run it

```bash
make image
# == scripts/upload-image.sh
```

What it does:

1. Downloads `flatcar_production_akamai_image.bin.gz` for your `CHANNEL` from
   `https://<channel>.release.flatcar-linux.net/amd64-usr/current/`.
2. Checks it is within Linode's **6 GiB** upload limit.
3. Uploads with `linode-cli image-upload --cloud-init` to your `REGION`.
4. Prints the resulting `private/<id>`.

## Why `--cloud-init` matters

The `--cloud-init` flag marks the image as **metadata-aware**. Without it,
instances built from the image cannot read `user_data` from the Metadata
service, and Ignition would never be delivered.

> The OpenTofu `linode_image` resource cannot set this flag today, which is why
> the upload is done with `linode-cli` here rather than in Terraform.

## After upload

Set the id in **both** places:

```bash
# .env
IMAGE_ID="private/1234567"

# tofu/terraform.tfvars
image_id = "private/1234567"
```

Region note: an image is regional. The instance **must** be created in the same
region you uploaded to (or copy the image to other regions first).

## Cost

The instance is not created here, but stored custom images incur a small monthly
storage charge until deleted (`linode-cli images delete private/<id>`).

Next: [3. Deploy with OpenTofu](03-deploy-opentofu.md).
