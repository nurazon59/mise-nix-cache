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

closure_bytes=$(nix path-info --closure-size --json-format 1 --json "$store_path" | python3 -c 'import json,sys; print(next(iter(json.load(sys.stdin).values()))["closureSize"])')

cache_dir="$output_dir/cache"
mkdir -p "$cache_dir"
nix copy --to "file://$cache_dir?compression=zstd&compression-level=3" "$store_path"

cache_bytes=$(python3 - "$cache_dir" <<'PY'
import os
import sys

total = 0
for current, _, files in os.walk(sys.argv[1]):
    for name in files:
        total += os.path.getsize(os.path.join(current, name))
print(total)
PY
)
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
peak_free_disk=$(sort -n "$disk_samples" | head -n 1)
rm -f "$disk_samples"
python3 - "$output_dir/manifest.json" "$sha" "$system" "$store_path" "$closure_bytes" "$cache_bytes" "$started_at" "$finished_at" "$elapsed_seconds" "$disk_before" "$disk_after" "$peak_free_disk" "$nix_version" <<'PY'
import json
import sys

(path, sha, system, store_path, closure_bytes, cache_bytes, started_at,
 finished_at, elapsed_seconds, disk_before, disk_after, peak_free_disk, nix_version) = sys.argv[1:]
manifest = {
    "schema_version": 1,
    "upstream_repository": "jdx/mise",
    "upstream_sha": sha,
    "system": system,
    "store_path": store_path,
    "nix_version": nix_version,
    "closure_size_bytes": int(closure_bytes),
    "export_size_bytes": int(cache_bytes),
    "started_at": started_at,
    "finished_at": finished_at,
    "elapsed_seconds": int(elapsed_seconds),
    "free_disk_before_bytes": int(disk_before),
    "free_disk_after_bytes": int(disk_after),
    "minimum_free_disk_bytes": int(peak_free_disk),
}
with open(path, "w", encoding="utf-8") as file:
    json.dump(manifest, file, indent=2)
    file.write("\n")
PY

echo "store_path=$store_path" >> "$GITHUB_OUTPUT"
echo "closure_bytes=$closure_bytes" >> "$GITHUB_OUTPUT"
echo "export_bytes=$cache_bytes" >> "$GITHUB_OUTPUT"
echo "peak_free_disk_bytes=$peak_free_disk" >> "$GITHUB_OUTPUT"
echo "Build/export took ${elapsed_seconds}s; closure ${closure_bytes} bytes; artifact ${cache_bytes} bytes"
