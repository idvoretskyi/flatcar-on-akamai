# Kubernetes on Flatcar (k3s)

This document describes the optional `CLUSTER=k3s` overlay that layers a
single-node [k3s](https://k3s.io/) Kubernetes cluster on top of the bare
Flatcar node described in the rest of this repo.

## How it works

The base OS (Ignition produced by the knuckle or butane backend) stays
byte-for-byte unchanged. A separate **Butane overlay** (`butane/k8s/k3s-server.bu`)
is compiled to an Ignition fragment and **deep-merged** with the base at render
time by `scripts/render-ignition.sh`. The single merged `build/ignition.json`
is delivered to the instance via the Akamai Metadata service as usual.

```
CLUSTER=k3s make ignition
```

```
butane/flatcar.bu   ─── envsubst ──▶ base Ignition
                                           │
butane/k8s/k3s-server.bu                  │  jq deep-merge
  ─── envsubst ──▶ overlay Ignition ───────┘
                                           ▼
                                 build/ignition.json
                                  (delivered via user_data)
```

The overlay owns everything Kubernetes:

| What | How |
|---|---|
| k3s binaries | `k3s-sysext-install.service` fetches the k3s sysext from the Flatcar Bakery via `systemd-sysupdate` on first boot |
| k3s config | `/etc/rancher/k3s/config.yaml` (token, write-kubeconfig-mode, node-name) |
| Cluster token | `/etc/rancher/k3s/k3s-token` (auto-generated, gitignored via `.env`) |
| Service | `k3s.service` enabled; dropin ensures it starts after the sysext install |

## Quick start

```bash
# 1. Enable the k3s overlay (add to .env or export)
echo 'CLUSTER="k3s"' >> .env

# 2. Render (token is auto-generated and appended to .env if unset)
make ignition CLUSTER=k3s

# 3. Deploy (costs money — ~$12/mo for g6-standard-1)
make apply

# 4. Wait ~2 minutes for k3s to bootstrap, then fetch the kubeconfig
make kubeconfig
export KUBECONFIG=$(pwd)/kubeconfig
kubectl get nodes
```

Expected output:
```
NAME             STATUS   ROLES                  AGE   VERSION
flatcar-akamai   Ready    control-plane,master   2m    v1.x.y+k3s1
```

## Instance sizing

The default instance type is `g6-standard-1` (2 GB RAM, 1 vCPU, ~$12/mo).
This is the minimum comfortable size for k3s. Override in `tofu/terraform.tfvars`:

```hcl
instance_type = "g6-standard-2"   # 4 GB, ~$24/mo — comfortable for real workloads
```

To run bare Flatcar without k3s and keep costs down, use:

```hcl
instance_type = "g6-nanode-1"   # 1 GB, ~$5/mo
```

## Variables

| Variable | Default | Description |
|---|---|---|
| `CLUSTER` | `none` | Set to `k3s` to enable the overlay |
| `K3S_TOKEN` | _(auto)_ | Shared cluster secret. Auto-generated via `openssl rand -hex 32` and saved to `.env` if unset |
| `BACKEND` | `knuckle` | Base OS Ignition backend (`knuckle` or `butane`) — unchanged by the overlay |

## kubeconfig security note

`make kubeconfig` rewrites the server address to the public IP and sets
`insecure-skip-tls-verify: true`. This is acceptable for a playground; the
k3s TLS certificate does not include the public IP in its SAN by default.

For production use, add the public IP to the cert SAN via k3s config:

```yaml
# /etc/rancher/k3s/config.yaml
tls-san:
  - <your-public-ip>
```

Then remove the `insecure-skip-tls-verify` line and distribute the CA
(`/var/lib/rancher/k3s/server/tls/server-ca.crt`).

## Port exposure

k3s binds the Kubernetes API server on **port 6443** on all interfaces,
including the public IP. This is intentional for a playground (`make kubeconfig`
needs it), but you should restrict access if running anything sensitive.

Consider adding a [Linode Cloud Firewall](https://www.linode.com/docs/products/networking/cloud-firewall/)
via a `linode_firewall` resource in `tofu/` to allow 6443 only from your
own CIDR.

## Path to multi-node

The current design is deliberately single-node (control-plane taint removed,
workloads schedule on the same node). A multi-node setup would need:

1. A second Butane overlay for agent nodes (`k3s agent` role, same token).
2. `private_ip = true` in `tofu/variables.tf` + the private networkd unit
   (see [docs/06-troubleshooting.md](06-troubleshooting.md)) so agents can
   reach the server on its private IP without exposing 6443 publicly.
3. Separate `linode_instance` resources for each agent (or a `count`/`for_each`).
4. Per-role Ignition render in `render-ignition.sh` (server vs agent overlay).

See [issue tracker](https://github.com/idvoretskyi/flatcar-on-akamai/issues) for
a multi-node tracking issue.

## Sysext version pinning

The `k3s-sysext-install.service` unit fetches `latest` from the Flatcar Bakery.
Within a given k3s minor version, `systemd-sysupdate` handles patch upgrades
automatically. Pinning to a specific minor version requires editing the
`MatchPattern` in `/etc/sysupdate.k3s.d/k3s.conf`.
