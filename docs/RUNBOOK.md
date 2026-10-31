# Runbook

## Current state

- R2 bucket: `mise-nix-cache` (Standard, private by default).
- Worker: deployed at `https://mise-nix-cache.itk-koshiishi.net`; signed cache retrieval and restoration are verified. The first successful publication is recorded for mise `v2026.10.24` at `aa26090fc10184bf61997e5784f72c365c8c8ece`.
- Upstream target: the latest published stable `jdx/mise` GitHub release tag, `aarch64-darwin`, `#mise`. Unreleased `main` commits are excluded from automatic publication.
- Scheduled publication is disabled until the remaining P0 gates, including redistribution licensing review, pass.
- `CACHE_URL`, `CACHE_PUBLIC_KEY`, and `R2_ACCOUNT_ID` are GitHub repository Variables. `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, and `NIX_CACHE_SECRET_KEY` belong only to the protected `cache-publish` Environment.
- `CODEMAGIC_API_TOKEN` is a GitHub Actions repository Secret used to start Codemagic builds and download artifacts. `CODEMAGIC_APP_ID` optionally overrides the application ID configured in the workflow.

## Initial setup

1. Confirm the `mise-nix-cache` R2 bucket is the intended project bucket. Keep the bucket private; the Worker provides anonymous read-only access.
2. Deploy the Worker with `wrangler deploy`. Its configured custom domain is `https://mise-nix-cache.itk-koshiishi.net`; use this URL as `CACHE_URL` after verifying public cache retrieval.
3. Generate the Nix signing key once on a trusted operator machine:

   ```sh
   nix-store --generate-binary-cache-key mise-cache-1 cache-secret.key cache-public.key
   ```

   Add `mise-cache-1:<public-key>` to the README and the `CACHE_PUBLIC_KEY` repository Variable. Do not commit `cache-secret.key`.
4. In Cloudflare R2, create an S3 API token scoped to the `mise-nix-cache` bucket with Object Read & Write access. Store its Access Key ID and Secret Access Key as the two `cache-publish` Environment Secrets. Record the account ID as `R2_ACCOUNT_ID`.
5. Add `NIX_CACHE_SECRET_KEY` to the `cache-publish` Environment. If the secret contains a key name prefix and colon, preserve it exactly.
6. Configure required reviewers on the `cache-publish` Environment before enabling production publishing. Add the Codemagic account API token as the `CODEMAGIC_API_TOKEN` repository Secret. If the Codemagic application changes, set the `CODEMAGIC_APP_ID` repository Variable to its application ID.
7. Confirm the R2 storage allowance and account usage, and complete the build-size P0 measurements before enabling the workflow.
8. With scheduling still disabled, run the workflow manually on `main` with `publish=true` and approve the protected environment. Verify the artifact transfer, signed upload, public restore, success metadata, licensing, and storage usage. Only after all P0 gates pass, set the repository Variable `CACHE_PUBLISH_ENABLED` to `true` to enable scheduled publication.

## Codemagic build

GitHub Actions selects the release and starts `build-mise-cache` on Codemagic. The Codemagic job checks that it has the same project commit, builds the selected upstream SHA, and exports an unsigned Nix cache. It receives no Codemagic API token, signing key, or R2 credentials. GitHub Actions downloads the artifact without forwarding its API token to a redirect, extracts only allowed regular files, and transfers it to the protected publish job for validation and signing.

Start a forced manual workflow with `publish=false` to verify the handoff before enabling publication. Check the Codemagic build URL printed by the GitHub Actions build job, the manifest, and the transferred artifact. If the branch moves before Codemagic checks it out, the project-commit check fails; rerun against the new commit. The build and artifact transfer are not yet verified end to end.

Codemagic's job limit is 120 minutes. The personal plan provides 500 free M2 minutes per month. The project artifact size threshold is not a Codemagic service limit; confirm the actual build time, disk usage, and transfer size before enabling scheduling.

## P0 measurement

The build script uses the exact upstream SHA and records Nix version, build/export duration, sampled minimum free disk, closure bytes, and exported binary-cache bytes in `manifest.json`. A local laptop result does not prove that `macos-15` hosted runners can fit the build: current standard arm64 macOS runners provide 7 GB RAM and 14 GB SSD.

For a build-only measurement, manually run the `Measure mise Nix build` workflow with a SHA reachable from upstream `main`; an empty input selects the current upstream head. This diagnostic workflow does not publish or determine the production release selection. The job uses `macos-15`, streams full Nix build logs, and samples the runner about every 30 seconds. Download the `mise-build-measurement-<SHA>` artifact for the build log, free disk on `/nix`, `vm_stat`, swap and CPU usage, and the 15 processes with the highest CPU usage. CPU percentages and RSS in the process list are per process; system CPU, memory and disk samples cover the runner, not just Nix. A 225-minute build timeout leaves time for artifact upload inside the 240-minute job timeout. A forced cancellation or runner loss may prevent artifact upload. The measurement job has no signing key or R2 credentials and does not publish a cache.

Local PoC on 2026-10-27 evaluated upstream `jdx/mise` SHA `58e4ab47dc64a8486370b923629601964173b883` and ran for about 50 minutes. Compilation completed, but the upstream test suite failed: 3,282 passed and `toolset::running::tests::lists_every_process_on_macos` panicked because its process-list command was unavailable in this execution environment. Nix therefore did not produce the exact upstream derivation output path; its closure size and artifact transfer remain unmeasured. This is not a verified successful build and must not be published. The local `/nix` filesystem grew from roughly 42 GiB to 60 GiB used during the run, while ending with 270 GiB free; this is an observed host-store delta, not an isolated peak or closure measurement. Repeat the unchanged upstream build on the intended GitHub runner or an equivalent macOS environment where the upstream process-list test can run. Do not bypass the failing test to enable publication.

On 2026-10-30, the unchanged upstream release `v2026.10.24` at `aa26090fc10184bf61997e5784f72c365c8c8ece` passed the [macOS build measurement](https://github.com/nurazon59/mise-nix-cache/actions/runs/41039109681). This validates that build on that runner, but does not establish artifact transfer, signing, R2 upload, or public restoration.

At the operator's request, a separate diagnostic build used the same upstream source SHA with its check phase replaced by a no-op. Release compilation completed in 25m 35s, and the resulting binary reported `2026.10.19 macos-arm64`. The manually altered derivation did not register its expected output path because its embedded output path remained the original one. For size measurement only, the binary directory was copied into a content-addressed local store path: NAR/closure size was 231,246,224 bytes and the exported unsigned Nix cache files totaled 70,419,152 bytes. This is an indicative transfer size for this build, not a successful build of the exact upstream derivation path; no signature, R2 upload, GitHub artifact transfer, or clean-client restore was tested.

The build job exports an unsigned Nix binary cache, then uploads it as an artifact. The publish job runs on a fresh runner, validates the artifact against the independently evaluated store path, and uses Nix to sign and write it to R2. It disables signature checks only for the copy from this validated unsigned artifact; it does not execute binaries or scripts from the artifact. The verify job has no secrets, verifies signatures and contents from the public URL, and restores the signed output. Success metadata is written only after verification.

`MAX_ARTIFACT_BYTES` defaults to 9,500,000,000 bytes to stop before attempting a near-10 GB transfer. This is a project safety threshold, not a GitHub or Cloudflare service limit. If the actual closure or exported artifact exceeds it, keep publishing disabled. Options are a trusted self-hosted arm64 Mac with sufficient disk, or a separate handoff service that grants the build job only a short-lived upload capability with no access to production R2 or the signing key. Do not move signing keys or production R2 credentials onto the build runner.

## Workflow operation

- The scheduled workflow polls `jdx/mise` GitHub Releases every hour and selects only the latest published, non-prerelease release tag (for example, `v2026.10.24`). GitHub's release API resolves the tag to an immutable commit SHA for the build. Commits on `main` without a published stable release are ignored; multiple releases between polls may result in only the latest being built.
- `workflow_dispatch` builds the latest published stable release (optionally with `force=true` to bypass the existing-cache check). Set `publish=true` for a one-off publication while scheduled publication is disabled; otherwise a manual run is build-only unless scheduled publication is enabled. Arbitrary commit SHAs cannot be selected through the production workflow. Use the separate measurement workflow for diagnostics.
- Existing release paths are skipped only when their contents and signatures verify from the public URL with the configured signing public key. If publishing is disabled, scheduled runs do not start.
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
- To stop anonymous reads, remove the Worker's custom domain. Keep the bucket intact while investigating.
- Do not delete the R2 bucket or objects without reviewing cache references and the intended retention policy.
