# mise-nix-cache

An unofficial, opt-in Nix binary cache for the upstream [`jdx/mise`](https://github.com/jdx/mise) flake. This project builds the upstream `#mise` package and serves signed Nix store paths from Cloudflare R2. It does not modify or fork mise.

The initial target is `aarch64-darwin`. A cache hit requires the exact upstream commit, flake inputs, and resulting store path to match. Other commits and systems continue through Nix's ordinary build/substitution behavior.

## Status

The read-only Cloudflare Worker is deployed at [`https://mise-nix-cache.itk-koshiishi.net`](https://mise-nix-cache.itk-koshiishi.net), backed by the private `mise-nix-cache` R2 bucket. Signed cache retrieval and restoration have been verified for mise `v2026.10.24` on `aarch64-darwin`. See [RUNBOOK.md](docs/RUNBOOK.md).

## Add the cache

On macOS, add the values to the existing Nix daemon configuration, commonly `/etc/nix/nix.conf` for the Determinate Nix installer or Nix daemon. Preserve existing substituters and trusted keys:

```ini
extra-substituters = https://mise-nix-cache.itk-koshiishi.net
extra-trusted-public-keys = mise-cache-1:oo46HcMAlPLK9Ew0aOzcpeuLOJot4K+Ko7wr13KqiFs=
```

On NixOS:

```nix
{
  nix.settings.extra-substituters = [ "https://mise-nix-cache.itk-koshiishi.net" ];
  nix.settings.extra-trusted-public-keys = [ "mise-cache-1:oo46HcMAlPLK9Ew0aOzcpeuLOJot4K+Ko7wr13KqiFs=" ];
}
```

After changing daemon configuration, restart the Nix daemon as appropriate for the installation and evaluate the upstream flake:

```sh
nix build --no-link 'github:jdx/mise#mise'
```

Non-trusted users may not be allowed to add a substituter or trusted key through command-line options; configure the daemon or system settings instead. Keep `cache.nixos.org` and signature verification enabled. Do not set `require-sigs = false` or mark this cache as trusted.

## Trust and limits

This is a community cache, not an official mise or nixpkgs service. Nix signatures establish that the object was published by this cache and was not changed in transit; they do not prove that upstream source code is safe. Build jobs execute upstream source and receive no signing key or R2 credentials. Separate publish jobs validate and sign data-only Nix cache artifacts; the public Worker accepts only GET and HEAD requests.

Availability is best-effort and limited to published stable `jdx/mise` GitHub release tags for `aarch64-darwin`. Scheduled publication is currently disabled. When enabled, the workflow polls for releases every hour and builds only when the selected release's signed store path is absent from the cache; unpublished `main` commits do not trigger builds. A cache miss falls back to normal Nix behavior. Intermediate releases, historical revisions, and alternate lock/input combinations are not guaranteed to hit.

The cache retains published NARs; automatic garbage collection is not configured. Cloudflare's 10 GB-month R2 Free allocation is a monthly billing allowance, not a hard storage cap. Standard storage above the allowance is billed at the current rate, and stored revisions accumulate. Check the [current R2 pricing](https://developers.cloudflare.com/r2/pricing/) and usage before enabling automatic publishing.

The licensing review for binary redistribution remains outstanding. The project does not cache arbitrary user-selected refs, forks, or pull requests.

## Local Worker development

Install the [Wrangler CLI](https://developers.cloudflare.com/workers/wrangler/install-and-update/) before running the local server.

```sh
wrangler dev --local
```

The local Worker exposes the configured R2 bucket binding using Wrangler's local storage. The published endpoint is read-only; upload Nix cache objects through the separate publisher.
