#!/usr/bin/env bash
set -euo pipefail

sha=${1:?usage: write-success-metadata.sh <upstream-sha> <store-path> <export-bytes> <workflow-run-url>}
store_path=${2:?usage: write-success-metadata.sh <upstream-sha> <store-path> <export-bytes> <workflow-run-url>}
export_bytes=${3:?usage: write-success-metadata.sh <upstream-sha> <store-path> <export-bytes> <workflow-run-url>}
workflow_run_url=${4:?usage: write-success-metadata.sh <upstream-sha> <store-path> <export-bytes> <workflow-run-url>}

if [[ ! "$sha" =~ ^[0-9a-f]{40}$ || ! "$store_path" =~ ^/nix/store/[a-z0-9]{32}-mise-[^/]+$ || ! "$export_bytes" =~ ^[0-9]+$ ]]; then
	echo "Invalid upstream SHA, store path, or export size" >&2
	exit 1
fi
if [[ ! "$workflow_run_url" =~ ^https://github\.com/[^/]+/[^/]+/actions/runs/[0-9]+$ ]]; then
	echo "Invalid workflow run URL" >&2
	exit 1
fi
if [[ ! "$R2_ACCOUNT_ID" =~ ^[a-f0-9]{32}$ || ! "$R2_BUCKET" =~ ^[a-z0-9-]+$ ]]; then
	echo "Invalid R2 account ID or bucket" >&2
	exit 1
fi

metadata_dir=$(mktemp -d)
trap 'rm -rf "$metadata_dir"' EXIT
published_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq -n \
	--arg sha "$sha" \
	--arg store_path "$store_path" \
	--arg published_at "$published_at" \
	--arg workflow_run_url "$workflow_run_url" \
	--argjson export_bytes "$export_bytes" \
	'{schema_version: 1, upstream_repository: "jdx/mise", upstream_sha: $sha, system: "aarch64-darwin", store_path: $store_path, status: "success", published_at: $published_at, workflow_run_url: $workflow_run_url, export_size_bytes: $export_bytes}' \
	> "$metadata_dir/$sha.json"
cp "$metadata_dir/$sha.json" "$metadata_dir/latest-success-aarch64-darwin.json"

endpoint="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
aws s3api put-object \
	--bucket "$R2_BUCKET" \
	--key "_meta/latest-success-aarch64-darwin.json" \
	--body "$metadata_dir/latest-success-aarch64-darwin.json" \
	--content-type "application/json" \
	--endpoint-url "$endpoint" \
	--region auto
aws s3api put-object \
	--bucket "$R2_BUCKET" \
	--key "_meta/aarch64-darwin/$sha.json" \
	--body "$metadata_dir/$sha.json" \
	--content-type "application/json" \
	--endpoint-url "$endpoint" \
	--region auto
