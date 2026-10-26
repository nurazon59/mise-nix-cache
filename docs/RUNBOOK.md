# Runbook

## Current state

- R2 bucket: `mise-nix-cache` (Standard, private by default).
- Worker: deployed at `https://mise-nix-cache.i2kiii-fib.workers.dev`; read-only routes are verified. The bucket is empty until a signed publication succeeds.
- Upstream target: `jdx/mise` `main`, `aarch64-darwin`, `#mise`.
- GitHub Actions publication is disabled until these P0 gates pass: hosted-runner build capacity, exported closure transfer capacity, Nix signature verification, public cache retrieval, and clean-client substitution.
- `CACHE_URL`, `CACHE_PUBLIC_KEY`, and `R2_ACCOUNT_ID` are GitHub repository Variables. `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, and `NIX_CACHE_SECRET_KEY` belong only to the protected `cache-publish` Environment.

## Initial setup

1. Confirm the `mise-nix-cache` R2 bucket is the intended project bucket. Keep the bucket private; the Worker provides anonymous read-only access.
2. Deploy the Worker with `wrangler deploy`. Record the `workers.dev` URL as `CACHE_URL`. For a stable production endpoint, connect a domain managed in the same Cloudflare account to this bucket or Worker and configure it as the cache URL.
3. Generate the Nix signing key once on a trusted operator machine:

   ```sh
   nix-store --generate-binary-cache-key mise-cache-1 cache-secret.key cache-public.key
   ```

   Add `mise-cache-1:<public-key>` to the README and the `CACHE_PUBLIC_KEY` repository Variable. Do not commit `cache-secret.key`.
4. In Cloudflare R2, create an S3 API token scoped to the `mise-nix-cache` bucket with Object Read & Write access. Store its Access Key ID and Secret Access Key as the two `cache-publish` Environment Secrets. Record the account ID as `R2_ACCOUNT_ID`.
5. Add `NIX_CACHE_SECRET_KEY` to the `cache-publish` Environment. If the secret contains a key name prefix and colon, preserve it exactly.
6. Configure required reviewers on the `cache-publish` Environment before enabling production publishing.
7. Confirm the R2 storage allowance and account usage, and complete the build-size P0 measurements before enabling the workflow.
8. Only after all P0 gates pass, set the repository Variable `CACHE_PUBLISH_ENABLED` to `true`. Without it, scheduled builds do not start and publish/verify jobs stay disabled. Manual dispatch remains available to measure a P0 build.

## P0 measurement

The build script uses the exact upstream SHA and records Nix version, build/export duration, sampled minimum free disk, closure bytes, and exported binary-cache bytes in `manifest.json`. A local laptop result does not prove that `macos-15` hosted runners can fit the build: current standard arm64 macOS runners provide 7 GB RAM and 14 GB SSD.

The build job exports an unsigned Nix binary cache, then uploads it as an artifact. The publish job runs on a fresh runner, validates manifest fields and filesystem entries, and uses Nix to sign and write the store path to R2. It does not execute binaries or scripts from the artifact. The verify job has no secrets and restores the signed output through the public cache URL.

`MAX_ARTIFACT_BYTES` defaults to 9,500,000,000 bytes to stop before attempting a near-10 GB transfer. This is a project safety threshold, not a GitHub or Cloudflare service limit. If the actual closure or exported artifact exceeds it, keep publishing disabled. Options are a larger dedicated macOS runner, a trusted self-hosted arm64 Mac, or a transfer design using an isolated staging bucket with no signing/R2 credentials on the build host. Do not move signing keys onto the build runner.

## Workflow operation

- The scheduled workflow checks `jdx/mise` `main` every six hours. `workflow_dispatch` can force a rebuild or select a SHA reachable from `main`.
- Existing paths are skipped only when Nix can restore them from the public URL with the configured signing public key.
- Only runs on the repository's `main` branch can publish. Pull requests and other branches cannot access the protected Environment.
- A failed build, artifact validation, upload, or public restore is not a successful publication. Inspect the named job and retain the previous cache objects.
- A Nix store path is immutable, so rerunning the same SHA does not need to replace successful NARs.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Build runs out of disk or memory | Record runner free disk, Nix build logs, and job termination reason. Do not retry indefinitely on the same standard runner. |
| Artifact upload fails or reaches the size threshold | Compare `export_size_bytes` and closure size in `manifest.json`; do not merge signing credentials into the build job. |
| R2 returns 403 | Check bucket-scoped Object Read & Write credentials, account ID, endpoint, and `region=auto`. |
| Public URL returns 404 | Confirm the key exists in R2, Worker binding points at `mise-nix-cache`, and the object path is a Nix cache key. |
| Signature is rejected | Check the public key name/value and the matching protected `NIX_CACHE_SECRET_KEY`. Never disable signature checks. |
| Public restore fails after upload | Do not mark the commit as usable. Check `.narinfo`, NAR retrieval, CDN cache behavior, and Worker responses. |
| Cache storage approaches the free allowance | Review current account/bucket usage and pricing. There is no automatic GC; pause publication or approve a retention/GC design before storage grows further. |

## Key rotation or suspected leak

1. Disable the `cache-publish` Environment or pause the workflow.
2. Revoke the leaked R2 S3 API token in Cloudflare. If the Nix signing key may have leaked, generate a new key pair on a trusted machine.
3. Replace GitHub Environment Secrets and repository Variables. Update the published public key and client configuration.
4. Verify a signed cache restore using a clean client before resuming publication.
5. Tell users to remove trust in the old public key if it was exposed. Do not delete old NARs as part of key rotation; deletion requires a separate reference-safe retention plan.

## Pause or disable serving

- Stop scheduled publication by disabling the GitHub Actions workflow.
- To stop anonymous reads, remove the Worker route or disable its workers.dev endpoint. Keep the bucket intact while investigating.
- Do not delete the R2 bucket or objects without reviewing cache references and the intended retention policy.
