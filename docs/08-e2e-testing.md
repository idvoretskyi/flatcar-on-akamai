# 8. Live end-to-end testing

`scripts/e2e-linode.sh` runs a full deploy-assert-destroy cycle against a real
Akamai/Linode instance. This is the only test in the repo that exercises the
complete path: Ignition render → image upload → `tofu apply` → Afterburn →
first-boot Ignition application → SSH assertion → (optionally) k3s `Ready`.

> **This test costs real money.** A complete run takes roughly 10–20 minutes
> and uses approximately **$0.01–$0.02** in compute (hourly billing) plus a
> small transient image-storage charge. Both the instance and the custom image
> are deleted at the end of every run.

## What it tests

| Step | What is verified |
|------|-----------------|
| Image upload | `linode-cli image-upload --cloud-init` succeeds; `private/<id>` parsed |
| Ignition render | Both backends (`knuckle`, `butane`) produce valid Ignition JSON |
| `tofu apply` | Instance, disk, and config resources created; instance boots |
| Afterburn | Ignition is consumed from Metadata service on first boot |
| SSH as `core` | Key injected via Ignition works; `core` can log in |
| Hostname | `/etc/hostname` matches the value set in Ignition |
| SSH hardening | `/etc/ssh/sshd_config.d/99-hardening.conf` present |
| Auto-updates | `REBOOT_STRATEGY=off` in `/etc/flatcar/update.conf` |
| `core` sudo | `core` user is in the `sudo` group |
| k3s Ready | (`--cluster k3s`) `kubectl get nodes` shows `Ready` |
| k3s sysext | `k3s-sysext-install.service` is `active` |
| Teardown | Instance destroyed, image deleted, no stray resources |

**What is NOT tested:** the Linode Metadata service / Afterburn path is
exercised end-to-end (it is the live deploy path), but the OpenTofu HCL is not
independently unit-tested beyond `tofu validate`. See the offline `make validate`
for that.

## Prerequisites

1. **Linode API token** — export before running:
   ```bash
   export LINODE_TOKEN=<your-token>
   ```
   Required token scopes: **Linodes Read/Write** + **Images Read/Write**.
   The token is read by both `linode-cli` and OpenTofu (`LINODE_TOKEN` env var).

2. **`linode-cli` configured** — must be authenticated:
   ```bash
   linode-cli configure    # one-time setup
   linode-cli regions list # smoke-test auth
   ```

3. **SSH key** — `~/.ssh/id_ed25519` (private) and `~/.ssh/id_ed25519.pub`
   (public). The public key is injected into Ignition; the private key is used
   to SSH into the booted instance. Override with `E2E_SSH_PRIVKEY`:
   ```bash
   export E2E_SSH_PRIVKEY=~/.ssh/my_other_key
   ```

4. **Tools on PATH:** `tofu`, `linode-cli`, `jq`, `git`, `go`, `openssl`,
   `ssh`, `wget`. The knuckle backend also needs `go`.

5. **Region:** the e2e defaults to **`gb-lon`** (image upload and instance must
   be in the same region). Override with `E2E_REGION`:
   ```bash
   export E2E_REGION=us-ord
   ```

## Running

```bash
# Bare Flatcar node (g6-nanode-1, ~$0.0075/hr)
export LINODE_TOKEN=...
make e2e

# k3s overlay (g6-standard-1, ~$0.018/hr)
make e2e-k3s

# Override backend or region
make e2e BACKEND=butane E2E_REGION=us-ord
```

Or call the script directly for more control:

```bash
scripts/e2e-linode.sh --cluster k3s
scripts/e2e-linode.sh --cluster none --keep   # leaves instance up for inspection
```

## Guaranteed teardown

The script registers a `trap cleanup EXIT` that fires on **any** exit — normal
completion, assertion failure, or `Ctrl-C`. The cleanup:

1. Runs `tofu destroy -auto-approve` (targets only the unique `flatcar-e2e-<ts>`
   label/state directory — never touches other instances on the account).
2. Deletes the ephemeral Flatcar image via `linode-cli images delete`.
3. Verifies removal: lists instances and images for the run label; warns loudly
   if anything remains.

The instance label includes a timestamp (`flatcar-e2e-YYYYMMDD-HHMMSS`) so
parallel runs and manual inspections are unambiguous.

## If a run is interrupted mid-way

If the process is killed hard (e.g. `kill -9`) before teardown completes, the
trap may not run. Recovery:

```bash
# List any stray e2e instances
linode-cli linodes list --text --format=id,label,status | grep flatcar-e2e

# List any stray e2e images
linode-cli images list --is_public false --text --format=id,label | grep flatcar-e2e

# Force-destroy a stray instance by label
make e2e-destroy E2E_LABEL=flatcar-e2e-YYYYMMDD-HHMMSS

# Or delete directly
linode-cli linodes delete <id>
linode-cli images delete private/<id>
```

## Keeping the instance for debugging

Pass `--keep` (or `make e2e ARGS=--keep`) to skip teardown:

```bash
scripts/e2e-linode.sh --cluster none --keep
# ... assertions run, then script prints the SSH command and exits without destroying
ssh -i ~/.ssh/id_ed25519 core@<ip>

# When done, destroy manually:
make e2e-destroy E2E_LABEL=flatcar-e2e-<ts>
```

> **Warning:** `--keep` leaves a billing instance running. Always clean up when
> done.

## Environment variable reference

| Variable | Default | Description |
|----------|---------|-------------|
| `LINODE_TOKEN` | — | **Required.** Linode API token (Linodes RW + Images RW). |
| `E2E_REGION` | `gb-lon` | Linode region for image upload and instance. |
| `E2E_TYPE` | `g6-nanode-1` / `g6-standard-1` | Instance type (auto-selected by `--cluster`). |
| `E2E_SSH_PRIVKEY` | `~/.ssh/id_ed25519` | Path to SSH private key. |
| `BACKEND` | `knuckle` | Ignition render backend (`knuckle` or `butane`). |
| `CHANNEL` | `stable` | Flatcar release channel for image download. |

## Cost summary

| Run type | Instance | Hourly rate | Typical run |
|----------|----------|-------------|-------------|
| Bare Flatcar | `g6-nanode-1` | ~$0.0075 | ~10–15 min → **<$0.01** |
| k3s | `g6-standard-1` | ~$0.018 | ~15–25 min → **~$0.01** |

Image storage costs accrue only for the duration of the run (upload → delete).
