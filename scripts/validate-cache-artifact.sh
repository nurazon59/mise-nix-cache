#!/usr/bin/env bash
set -euo pipefail

artifact_dir=${1:?usage: validate-cache-artifact.sh <artifact-dir> <sha> <store-path>}
expected_sha=${2:?usage: validate-cache-artifact.sh <artifact-dir> <sha> <store-path>}
expected_store_path=${3:?usage: validate-cache-artifact.sh <artifact-dir> <sha> <store-path>}

python3 - "$artifact_dir/manifest.json" "$expected_sha" "$expected_store_path" "$artifact_dir/cache" <<'PY'
import hashlib
import json
import os
import pathlib
import re
import sys

manifest_path, expected_sha, expected_store_path, cache_dir = sys.argv[1:]
if os.path.getsize(manifest_path) > 8 * 1024 * 1024:
    raise SystemExit("artifact manifest is too large")
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

if os.path.islink(cache_dir) or not os.path.isdir(cache_dir):
    raise SystemExit("cache directory is missing or is a symlink")
artifact_root = os.path.realpath(os.path.dirname(cache_dir))
if os.path.commonpath((artifact_root, os.path.abspath(cache_dir))) != artifact_root:
    raise SystemExit("cache directory escaped artifact root")
root = os.path.realpath(cache_dir)
manifest_files = manifest.get("files")
if not isinstance(manifest_files, list):
    raise SystemExit("artifact manifest has no file checksums")
expected = {}
for item in manifest_files:
    if not isinstance(item, dict):
        raise SystemExit("invalid file entry in artifact manifest")
    relative_path = item.get("path")
    if not isinstance(relative_path, str) or relative_path.startswith("/"):
        raise SystemExit("invalid file path in artifact manifest")
    path_parts = pathlib.PurePosixPath(relative_path).parts
    if pathlib.PurePosixPath(relative_path).is_absolute() or ".." in path_parts:
        raise SystemExit("artifact manifest path escapes cache directory")
    if not (
        relative_path == "nix-cache-info"
        or re.fullmatch(r"[a-z0-9]{32}\.narinfo", relative_path)
        or re.fullmatch(r"nar/[A-Za-z0-9+._-]+\.nar(?:\.(?:xz|zst|bz2|gz|lz4|br))?", relative_path)
    ):
        raise SystemExit("unexpected file in Nix cache artifact")
    if relative_path in expected:
        raise SystemExit("duplicate file path in artifact manifest")
    if not re.fullmatch(r"[0-9a-f]{64}", str(item.get("sha256", ""))):
        raise SystemExit("invalid checksum in artifact manifest")
    expected[relative_path] = item

actual = set()
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
        relative_path = os.path.relpath(path, root)
        actual.add(relative_path)
        item = expected.get(relative_path)
        if item is None:
            raise SystemExit(f"unlisted file in cache artifact: {relative_path}")
        size = os.path.getsize(path)
        if item.get("size_bytes") != size:
            raise SystemExit(f"file size mismatch: {relative_path}")
        digest = hashlib.sha256()
        with open(path, "rb") as file:
            for chunk in iter(lambda: file.read(1024 * 1024), b""):
                digest.update(chunk)
        if digest.hexdigest() != item["sha256"]:
            raise SystemExit(f"checksum mismatch: {relative_path}")
        total += size

if actual != set(expected):
    raise SystemExit("artifact files do not match manifest")
if total != manifest.get("export_size_bytes"):
    raise SystemExit("exported cache size does not match manifest")
if total > 9_500_000_000:
    raise SystemExit(f"cache artifact exceeds transfer limit: {total} bytes")
PY
cache_dir="$artifact_dir/cache"
[[ -d "$cache_dir" ]] || { echo "cache directory is missing" >&2; exit 1; }
[[ -f "$cache_dir/nix-cache-info" ]] || { echo "nix-cache-info is missing" >&2; exit 1; }
