# knuckle integration

This repo uses [knuckle](https://github.com/projectbluefin/knuckle) as the
**primary Ignition generator**. knuckle's headless config schema is the single
source of truth for what goes into the node; OpenTofu only delivers the result.

## The `--emit-ignition` fork

Upstream knuckle is a bare-metal installer: it assembles Ignition internally and
hands it straight to `flatcar-install`, writing the JSON only to a temporary
file that is deleted immediately. There is no supported way to obtain the
Ignition document for use elsewhere.

The fork [`idvoretskyi/knuckle@emit-ignition`](https://github.com/idvoretskyi/knuckle/tree/emit-ignition)
adds a single, isolated capability:

- `headless.EmitIgnition(ctx, *Config) (string, error)` — mirrors the front half
  of `headless.Run` (validate → resolve GitHub SSH keys → resolve sysext catalog
  entries → `ToInstallConfig` → consistency check), then assembles Butane
  (Flatcar/FCOS dispatch identical to `install.Install`) and compiles it to
  Ignition JSON via the bundled `coreos/butane` library.
- `knuckle --emit-ignition --config <file>` — prints that JSON to stdout and
  exits. No hardware probe, no disk writes, no `flatcar-install`. The function is
  silent on stdout so the emitted JSON is the only thing written there.

It reuses existing exported logic; existing install/TUI paths are unchanged.

## Config schema

[`config.json`](config.json) is the knuckle headless schema. The render script
injects `hostname`, `channel`, and the SSH key from your `.env` into a copy
before calling knuckle, so `.env` stays the single place you edit per deploy.

Key fields for this use case:

| Field | Notes |
| ----- | ----- |
| `users[].ssh_keys` / `github_user` | Identity. Must be present — Afterburn can't use Linode keys. |
| `disk` | Required by knuckle validation. Unused by `--emit-ignition` (no install happens); `/dev/sda` is a fine placeholder. |
| `update_strategy` | `off`, `reboot`, or `etcd-lock`. |
| `network` | `dhcp` works out of the box on Akamai. |
| `sysexts` | Optional Flatcar Bakery system extensions (needs network at render time). |

Full reference: knuckle's `docs/HEADLESS-CONFIG.md`.

## Building it yourself

`scripts/render-ignition.sh` (the `knuckle` backend) clones the fork, runs
`go build ./cmd/knuckle`, and invokes `--emit-ignition`. To do it by hand:

```bash
git clone --branch emit-ignition https://github.com/idvoretskyi/knuckle.git
cd knuckle && CGO_ENABLED=0 go build -o knuckle ./cmd/knuckle
./knuckle --emit-ignition --config /path/to/config.json > ignition.json
```

## Upstreaming

The patch is intentionally small and contribution-shaped, but it is **not**
proposed upstream yet. Track it on the fork branch.
