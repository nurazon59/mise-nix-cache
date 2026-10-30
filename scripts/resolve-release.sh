#!/usr/bin/env bash
set -euo pipefail

# Only build the latest published stable upstream release, never a moving main SHA.
release_tag=$(gh api repos/jdx/mise/releases/latest --jq .tag_name)
if [[ ! "$release_tag" =~ ^v[0-9]{4}\.[0-9]{1,2}\.[0-9]{1,2}$ ]]; then
  echo "Unexpected mise release tag: $release_tag" >&2
  exit 1
fi

# GitHub's commits endpoint dereferences lightweight and annotated tags.
sha=$(gh api "repos/jdx/mise/commits/$release_tag" --jq .sha)
if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
  echo "Could not resolve release $release_tag to a commit SHA" >&2
  exit 1
fi

{
  printf 'sha=%s\n' "$sha"
  printf 'release_tag=%s\n' "$release_tag"
} >> "$GITHUB_OUTPUT"
echo "Resolved latest stable mise release $release_tag at $sha"
