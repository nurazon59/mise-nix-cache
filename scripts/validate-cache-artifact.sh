#!/usr/bin/env bash
set -euo pipefail

artifact_dir=${1:?usage: validate-cache-artifact.sh <artifact-dir> <sha> <store-path>}
expected_sha=${2:?usage: validate-cache-artifact.sh <artifact-dir> <sha> <store-path>}
expected_store_path=${3:?usage: validate-cache-artifact.sh <artifact-dir> <sha> <store-path>}

python3 - "$artifact_dir/manifest.json" "$expected_sha" "$expected_store_path" <<'PY'
import json
import re
import sys

manifest_path, expected_sha, expected_store_path = sys.argv[1:]
with open(manifest_path, encoding="utf-8") as file:
    manifest = json.load(file)

if manifest.get("schema_version") != 1:
    raise SystemExit("unsupported artifact manifest schema")
if manifest.get("upstream_repository") != "jdx/mise":
    raise SystemExit("artifact is not from jdx/mise")
if manifest.get("upstream_sha") != expected_sha:
    raise SystemExit("artifact upstream SHA mismatch")
if manifest.get("system") != "aarch64-darwin":
    raise SystemExit("artifact system mismatch")
if manifest.get("store_path") != expected_store_path:
    raise SystemExit("artifact store path mismatch")
if not re.fullmatch(r"/nix/store/[a-z0-9]{32}-mise-[^/]+", expected_store_path):
    raise SystemExit("invalid store path")
PY

cache_dir="$artifact_dir/cache"
[[ -d "$cache_dir" ]] || { echo "cache directory is missing" >&2; exit 1; }
[[ -f "$cache_dir/nix-cache-info" ]] || { echo "nix-cache-info is missing" >&2; exit 1; }

python3 - "$cache_dir" <<'PY'
import os
import sys

root = os.path.realpath(sys.argv[1])
total = 0
for current, directories, files in os.walk(root, followlinks=False):
    for name in directories + files:
        path = os.path.join(current, name)
        if os.path.islink(path):
            raise SystemExit(f"symlink in cache artifact: {path}")
    for name in files:
        path = os.path.join(current, name)
        if not os.path.isfile(path):
            raise SystemExit(f"non-regular file in cache artifact: {path}")
        if os.path.commonpath((root, os.path.realpath(path))) != root:
            raise SystemExit(f"path escaped cache artifact: {path}")
        total += os.path.getsize(path)

if total > 9_500_000_000:
    raise SystemExit(f"cache artifact exceeds transfer limit: {total} bytes")
PY
