#!/usr/bin/env bash
set -euo pipefail

artifact_dir=${1:?usage: validate-cache-artifact.sh <artifact-dir> <sha> <store-path>}
expected_sha=${2:?usage: validate-cache-artifact.sh <artifact-dir> <sha> <store-path>}
expected_store_path=${3:?usage: validate-cache-artifact.sh <artifact-dir> <sha> <store-path>}
manifest_path="$artifact_dir/manifest.json"
cache_dir="$artifact_dir/cache"

[[ -f "$manifest_path" && ! -L "$manifest_path" ]] || { echo "manifest is missing or is a symlink" >&2; exit 1; }
[[ $(stat -f '%z' "$manifest_path") -le 8388608 ]] || { echo "artifact manifest is too large" >&2; exit 1; }
[[ -d "$cache_dir" && ! -L "$cache_dir" ]] || { echo "cache directory is missing or is a symlink" >&2; exit 1; }
[[ "$expected_sha" =~ ^[0-9a-f]{40}$ && "$expected_store_path" =~ ^/nix/store/[a-z0-9]{32}-mise-[^/]+$ ]] || {
	echo "invalid upstream SHA or store path" >&2
	exit 1
}

jq -e \
	--arg sha "$expected_sha" \
	--arg store_path "$expected_store_path" \
	'.schema_version == 1 and .upstream_repository == "jdx/mise" and .upstream_sha == $sha and .system == "aarch64-darwin" and .store_path == $store_path and (.export_size_bytes | type == "number") and (.files | type == "array")' \
	"$manifest_path" >/dev/null || { echo "artifact manifest metadata mismatch" >&2; exit 1; }

if find "$cache_dir" ! -type d ! -type f -print -quit | grep -q .; then
	echo "non-regular entry in cache artifact" >&2
	exit 1
fi

validation_dir=$(mktemp -d)
expected_paths="$validation_dir/expected-paths.txt"
actual_paths="$validation_dir/actual-paths.txt"
trap 'rm -rf "$validation_dir"' EXIT
: > "$expected_paths"
: > "$actual_paths"
total=0

while IFS= read -r -d '' path; do
	[[ -f "$path" ]] || { echo "non-regular cache file: $path" >&2; exit 1; }
	relative_path=${path#"$cache_dir"/}
	if [[ "$relative_path" != "nix-cache-info" && ! "$relative_path" =~ ^[a-z0-9]{32}\.narinfo$ && ! "$relative_path" =~ ^nar/[A-Za-z0-9+._-]+\.nar(\.(xz|zst|bz2|gz|lz4|br))?$ ]]; then
		echo "unexpected file in Nix cache artifact: $relative_path" >&2
		exit 1
	fi
	size=$(stat -f '%z' "$path")
	sha256=$(shasum -a 256 "$path" | awk '{ print $1 }')
	if ! jq -e --arg path "$relative_path" --arg sha256 "$sha256" --argjson size "$size" \
		'.files | any(.[]; .path == $path and .size_bytes == $size and .sha256 == $sha256)' \
		"$manifest_path" >/dev/null; then
		echo "manifest mismatch for $relative_path" >&2
		exit 1
	fi
	printf '%s\n' "$relative_path" >> "$actual_paths"
	total=$((total + size))
done < <(find "$cache_dir" -type f -print0)

jq -r '.files[] | .path' "$manifest_path" | sort > "$expected_paths"
sort -o "$actual_paths" "$actual_paths"
cmp -s "$expected_paths" "$actual_paths" || { echo "artifact files do not match manifest" >&2; exit 1; }
manifest_total=$(jq -er '.export_size_bytes' "$manifest_path")
[[ "$total" -eq "$manifest_total" ]] || { echo "exported cache size does not match manifest" >&2; exit 1; }
max_artifact_bytes=${MAX_ARTIFACT_BYTES:-9500000000}
(( total <= max_artifact_bytes )) || { echo "cache artifact exceeds transfer limit: $total bytes" >&2; exit 1; }
[[ -f "$cache_dir/nix-cache-info" ]] || { echo "nix-cache-info is missing" >&2; exit 1; }
