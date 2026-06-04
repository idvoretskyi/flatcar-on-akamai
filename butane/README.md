# butane fallback

This is the **no-Go fallback** for generating Ignition. It compiles
[`flatcar.bu`](flatcar.bu) with the standalone
[`butane`](https://coreos.github.io/butane/) binary instead of building the
knuckle fork.

Use it when:

- Go is not available on the host, or
- you want a minimal, dependency-light render.

```bash
make ignition BACKEND=butane
# or
scripts/render-ignition.sh --backend butane
```

The render script downloads a pinned `butane` release (`BUTANE_VERSION` in
`.env`), substitutes `${HOSTNAME}` and `${SSH_AUTHORIZED_KEY}` from your `.env`,
and compiles with `--strict`.

## Keeping it in sync

`flatcar.bu` is a hand-maintained mirror of what knuckle produces from
[`../knuckle/config.json`](../knuckle/config.json). knuckle is the source of
truth; if you change the knuckle config (extra users, sysexts, swap, …) update
`flatcar.bu` to match, or just use the `knuckle` backend.

The two backends are validated to both produce valid Ignition in CI.
