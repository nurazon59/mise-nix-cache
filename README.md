# mise-nix-cache

An unofficial, opt-in Nix binary cache for the upstream [`jdx/mise`](https://github.com/jdx/mise) flake. This project builds the upstream `#mise` package and serves signed Nix store paths from Cloudflare R2. It does not modify or fork mise.

The initial target is `aarch64-darwin`. A cache hit requires the exact upstream commit, flake inputs, and resulting store path to match. Other commits and systems continue through Nix's ordinary build/substitution behavior.

## Status

The read-only Cloudflare Worker is deployed at [`https://mise-nix-cache.i2kiii-fib.workers.dev`](https://mise-nix-cache.i2kiii-fib.workers.dev), backed by the private `mise-nix-cache` R2 bucket. The endpoint currently has no cache objects. Publishing and clean-client restoration have not yet been verified; see [RUNBOOK.md](docs/RUNBOOK.md).

## Add the cache

Wait for the public cache URL and signing public key to be published here before configuring clients. Do not copy placeholder values into Nix settings.

On macOS, add the values to the existing Nix daemon configuration, commonly `/etc/nix/nix.conf` for the Determinate Nix installer or Nix daemon. Preserve existing substituters and trusted keys:

```ini
extra-substituters = https://<CACHE_HOST>
extra-trusted-public-keys = <CACHE_KEY_NAME>:<PUBLIC_KEY_BASE64>
```

On NixOS:

```nix
{
  nix.settings.extra-substituters = [ "https://<CACHE_HOST>" ];
  nix.settings.extra-trusted-public-keys = [ "<CACHE_KEY_NAME>:<PUBLIC_KEY_BASE64>" ];
}
```

After changing daemon configuration, restart the Nix daemon as appropriate for the installation and evaluate the upstream flake:

```sh
nix build --no-link 'github:jdx/mise#mise'
```

Non-trusted users may not be allowed to add a substituter or trusted key through command-line options; configure the daemon or system settings instead. Keep `cache.nixos.org` and signature verification enabled. Do not set `require-sigs = false` or mark this cache as trusted.

## Trust and limits

This is a community cache, not an official mise or nixpkgs service. Nix signatures establish that the object was published by this cache and was not changed in transit; they do not prove that upstream source code is safe. Build jobs execute upstream source and receive no signing key or R2 credentials. Separate publish jobs validate and sign data-only Nix cache artifacts; the public Worker accepts only GET and HEAD requests.

Availability is best-effort and limited to the latest published stable `jdx/mise` GitHub release tag for `aarch64-darwin`. The workflow polls for releases every hour and builds only when the selected release's signed store path is absent from the cache; unpublished `main` commits do not trigger builds. A cache miss falls back to normal Nix behavior. Intermediate releases, historical revisions, and alternate lock/input combinations are not guaranteed to hit.

The cache retains published NARs; automatic garbage collection is not configured. Cloudflare's 10 GB-month R2 Free allocation is a monthly billing allowance, not a hard storage cap. Standard storage above the allowance is billed at the current rate, and stored revisions accumulate. Check the [current R2 pricing](https://developers.cloudflare.com/r2/pricing/) and usage before enabling automatic publishing.

Binary redistribution licensing must be reviewed before public cache publication. The project does not cache arbitrary user-selected refs, forks, or pull requests.

## Local Worker development

Install the [Wrangler CLI](https://developers.cloudflare.com/workers/wrangler/install-and-update/) before running the local server.

```sh
wrangler dev --local
```

The local Worker exposes the configured R2 bucket binding using Wrangler's local storage. The published endpoint is read-only; upload Nix cache objects through the separate publisher.
