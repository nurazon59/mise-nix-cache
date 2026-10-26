#!/usr/bin/env bash
set -euo pipefail

requested_sha=${1:-}

if [[ -z "$requested_sha" ]]; then
	sha=$(gh api repos/jdx/mise/commits/main --jq .sha)
else
	if [[ ! "$requested_sha" =~ ^[0-9a-f]{40}$ ]]; then
		echo "upstream_sha must be a 40-character lowercase commit SHA" >&2
		exit 2
	fi

	sha=$(gh api "repos/jdx/mise/commits/$requested_sha" --jq .sha)
	status=$(gh api "repos/jdx/mise/compare/$sha...main" --jq .status)
	if [[ "$status" != ahead && "$status" != identical ]]; then
		echo "upstream_sha must be reachable from jdx/mise main" >&2
		exit 2
	fi
fi

if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
	echo "GitHub returned an invalid upstream SHA" >&2
	exit 1
fi

echo "sha=$sha" >> "$GITHUB_OUTPUT"
echo "Resolved jdx/mise main at $sha"
