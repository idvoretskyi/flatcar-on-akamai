# 4. Ignition generation (knuckle & butane)

OpenTofu delivers an Ignition JSON, but it does not generate it. That is done by
`scripts/render-ignition.sh`, which writes `build/ignition.json`.

```bash
make ignition                 # uses BACKEND from .env (default: knuckle)
make ignition BACKEND=butane  # override
```

Both backends inject `NODE_HOSTNAME` and `SSH_AUTHORIZED_KEY` from `.env`.

## Backend A: knuckle (default, primary)

```bash
make ignition BACKEND=knuckle
```

1. Clones the fork `idvoretskyi/knuckle@emit-ignition`.
2. `go build ./cmd/knuckle`.
3. Injects your hostname/channel/SSH key into a copy of
   [`knuckle/config.json`](../knuckle/config.json) with `jq`.
4. Runs `knuckle --emit-ignition --config <copy>` → `build/ignition.json`.

Requires **Go** (`sudo snap install go --classic`), `git`, `jq`.

This is the recommended path: knuckle's headless schema is the single source of
truth, validated the same way as a real install. See
[knuckle/README.md](../knuckle/README.md).

## Backend B: butane (fallback, no Go)

```bash
make ignition BACKEND=butane
```

1. Downloads a pinned `butane` release (`BUTANE_VERSION`, default in `scripts/lib/versions.sh`).
2. `envsubst`s `${HOSTNAME}` / `${SSH_AUTHORIZED_KEY}` into
   [`butane/flatcar.bu`](../butane/flatcar.bu).
3. Compiles with `butane --strict` → `build/ignition.json`.

Requires `curl`, `envsubst` (gettext), `jq`. `flatcar.bu` is a hand-maintained
mirror of the knuckle config; keep them in sync or prefer the knuckle backend.

## Verifying the output

```bash
jq '.ignition.version' build/ignition.json          # expect "3.4.0"
jq '[.passwd.users[].name]' build/ignition.json      # expect ["core"]
jq '[.storage.files[].path]' build/ignition.json
```

The render script already fails if the output is not valid Ignition JSON.

## Why SSH keys go here

Afterburn on Akamai does not read Linode's managed `ssh_keys`, and the disk
`authorized_keys` field is not honored for Flatcar. The **only** reliable path
is the Ignition config — which is exactly what both backends produce.

Next: [5. Alternative: knuckle native install](05-knuckle-rescue-mode.md).
