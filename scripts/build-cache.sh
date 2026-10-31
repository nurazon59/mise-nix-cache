#!/usr/bin/env bash
set -euo pipefail

sha=${1:?usage: build-cache.sh <upstream-sha> <output-dir>}
output_dir=${2:?usage: build-cache.sh <upstream-sha> <output-dir>}
system=aarch64-darwin
flake_ref="github:jdx/mise/$sha#mise"
store_path=$(nix eval --raw "$flake_ref.outPath")
mkdir -p "$output_dir"

if [[ ! "$sha" =~ ^[0-9a-f]{40}$ || ! "$store_path" =~ ^/nix/store/[a-z0-9]{32}-mise-[^/]+$ ]]; then
	echo "Invalid upstream SHA or evaluated store path" >&2
	exit 1
fi

started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
start_seconds=$(date +%s)
nix_version=$(nix --version)
disk_before=$(df -k /nix | awk 'NR == 2 { print $4 * 1024 }')
disk_samples="$output_dir/disk-samples.txt"
(
	while true; do
		df -k /nix | awk 'NR == 2 { print $4 * 1024 }' >> "$disk_samples"
		sleep 2
	done
) &
sampler_pid=$!
trap 'kill "$sampler_pid" 2>/dev/null || true; wait "$sampler_pid" 2>/dev/null || true' EXIT

nix build --no-link "$flake_ref"
"$store_path/bin/mise" --version

closure_bytes=$(nix path-info --closure-size --json-format 1 --json "$store_path" | jq -er 'to_entries[0].value.closureSize')

cache_dir="$output_dir/cache"
mkdir -p "$cache_dir"
nix copy --to "file://$cache_dir?compression=zstd&compression-level=3" "$store_path"

cache_bytes=$(find "$cache_dir" -type f -exec stat -f '%z' {} + | awk '{ total += $1 } END { print total + 0 }')
max_artifact_bytes=${MAX_ARTIFACT_BYTES:-9500000000}
if (( cache_bytes > max_artifact_bytes )); then
	echo "Exported cache is ${cache_bytes} bytes; transfer limit is ${max_artifact_bytes}" >&2
	exit 42
fi

finished_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
elapsed_seconds=$(( $(date +%s) - start_seconds ))
disk_after=$(df -k /nix | awk 'NR == 2 { print $4 * 1024 }')
kill "$sampler_pid" 2>/dev/null || true
wait "$sampler_pid" 2>/dev/null || true
trap - EXIT
peak_free_disk=$(awk 'NR == 1 || $1 < min { min = $1 } END { if (NR == 0) exit 1; print min }' "$disk_samples")
rm -f "$disk_samples"
entries_file="$output_dir/manifest-files.jsonl"
: > "$entries_file"
while IFS= read -r -d '' file_path; do
	[[ ! -L "$file_path" && -f "$file_path" ]] || { echo "non-regular file in exported cache: $file_path" >&2; exit 1; }
	relative_path=${file_path#"$cache_dir"/}
	file_size=$(stat -f '%z' "$file_path")
	file_sha=$(shasum -a 256 "$file_path" | awk '{ print $1 }')
	jq -cn --arg path "$relative_path" --arg sha256 "$file_sha" --argjson size "$file_size" \
		'{path: $path, size_bytes: $size, sha256: $sha256}' >> "$entries_file"
done < <(find "$cache_dir" -type f -print0)
files_json=$(jq -s 'sort_by(.path)' "$entries_file")
rm -f "$entries_file"
jq -n \
	--arg sha "$sha" --arg system "$system" --arg store_path "$store_path" \
	--arg nix_version "$nix_version" --arg started_at "$started_at" --arg finished_at "$finished_at" \
	--argjson closure_bytes "$closure_bytes" --argjson cache_bytes "$cache_bytes" \
	--argjson elapsed_seconds "$elapsed_seconds" --argjson disk_before "$disk_before" \
	--argjson disk_after "$disk_after" --argjson peak_free_disk "$peak_free_disk" \
	--argjson files "$files_json" \
	'{schema_version: 1, upstream_repository: "jdx/mise", upstream_sha: $sha, system: $system, store_path: $store_path, nix_version: $nix_version, closure_size_bytes: $closure_bytes, export_size_bytes: $cache_bytes, started_at: $started_at, finished_at: $finished_at, elapsed_seconds: $elapsed_seconds, free_disk_before_bytes: $disk_before, free_disk_after_bytes: $disk_after, minimum_free_disk_bytes: $peak_free_disk, files: $files}' \
	> "$output_dir/manifest.json"

echo "store_path=$store_path" >> "$GITHUB_OUTPUT"
echo "closure_bytes=$closure_bytes" >> "$GITHUB_OUTPUT"
echo "export_bytes=$cache_bytes" >> "$GITHUB_OUTPUT"
echo "peak_free_disk_bytes=$peak_free_disk" >> "$GITHUB_OUTPUT"
echo "Build/export took ${elapsed_seconds}s; closure ${closure_bytes} bytes; artifact ${cache_bytes} bytes"
