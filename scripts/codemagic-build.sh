#!/usr/bin/env bash
set -euo pipefail

: "${CODEMAGIC_API_TOKEN:?CODEMAGIC_API_TOKEN is required}"
: "${CODEMAGIC_APP_ID:?CODEMAGIC_APP_ID is required}"
: "${UPSTREAM_SHA:?UPSTREAM_SHA is required}"
: "${EXPECTED_STORE_PATH:?EXPECTED_STORE_PATH is required}"
: "${GITHUB_SHA:?GITHUB_SHA is required}"
: "${GITHUB_REF_NAME:?GITHUB_REF_NAME is required}"
: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

[[ "$CODEMAGIC_APP_ID" =~ ^[a-zA-Z0-9-]+$ && "$UPSTREAM_SHA" =~ ^[0-9a-f]{40}$ && "$GITHUB_SHA" =~ ^[0-9a-f]{40}$ ]] || {
	echo "Invalid application ID or commit SHA" >&2
	exit 1
}

request=$(jq -n --arg app "$CODEMAGIC_APP_ID" --arg branch "$GITHUB_REF_NAME" \
	--arg upstream "$UPSTREAM_SHA" --arg commit "$GITHUB_SHA" \
	'{appId: $app, workflowId: "build-mise-cache", branch: $branch, environment: {variables: {UPSTREAM_SHA: $upstream, EXPECTED_PROJECT_COMMIT: $commit}}}')
response=$(curl --fail-with-body --silent --show-error --max-time 30 \
	-H "x-auth-token: $CODEMAGIC_API_TOKEN" -H 'Content-Type: application/json' \
	--data "$request" https://api.codemagic.io/builds)
build_id=$(jq -er '.buildId | select(type == "string" and test("^[a-zA-Z0-9-]+$"))' <<< "$response")
build_running=true
cleanup() {
	if [[ "$build_running" == true ]]; then
		curl --fail --silent --show-error --max-time 15 -X POST \
			-H "x-auth-token: $CODEMAGIC_API_TOKEN" "https://api.codemagic.io/builds/$build_id/cancel" >/dev/null || true
	fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM
echo "Codemagic build: https://codemagic.io/app/$CODEMAGIC_APP_ID/build/$build_id"

for ((attempt = 0; attempt < 420; attempt++)); do
	response=$(curl --fail --silent --show-error --max-time 30 \
		-H "x-auth-token: $CODEMAGIC_API_TOKEN" "https://codemagic.io/api/v3/builds/$build_id")
	status=$(jq -er '.data.status | select(type == "string")' <<< "$response")
	case "$status" in
		finished)
			build_running=false
			break
			;;
		failed|canceled|timeout|skipped)
			build_running=false
			echo "Codemagic build ended with status: $status" >&2
			exit 1
			;;
		initializing|queued|preparing|fetching|testing|building|publishing|finishing)
			sleep 20
			;;
		*)
			echo "Unexpected Codemagic build status: $status" >&2
			exit 1
			;;
	esac
done
[[ "$build_running" == false ]] || { echo "Timed out waiting for Codemagic" >&2; exit 1; }

response=$(curl --fail --silent --show-error --max-time 30 \
	-H "x-auth-token: $CODEMAGIC_API_TOKEN" "https://api.codemagic.io/builds/$build_id")
jq -e --arg commit "$GITHUB_SHA" '.build.commit.hash == $commit' <<< "$response" >/dev/null || {
	echo "Codemagic built a different project commit" >&2
	exit 1
}
artifact_url=$(jq -er '[.build.artefacts[].url | select(endswith("/mise-cache.tar"))] | if length == 1 then .[0] else error("expected one cache artifact") end' <<< "$response")
[[ "$artifact_url" =~ ^https://api\.codemagic\.io/artifacts/[A-Za-z0-9._~/%-]+$ ]] || {
	echo "Unexpected artifact URL" >&2
	exit 1
}

archive="$RUNNER_TEMP/mise-cache.tar"
headers="$RUNNER_TEMP/codemagic-artifact-headers"
http_status=$(curl --silent --show-error --fail --max-filesize 9600000000 \
	-H "x-auth-token: $CODEMAGIC_API_TOKEN" --dump-header "$headers" --output "$archive" \
	--write-out '%{http_code}' "$artifact_url")
case "$http_status" in
	200) ;;
	301|302|303|307|308)
		location=$(awk 'tolower($0) ~ /^location:/ { sub(/^[^:]*:[[:space:]]*/, ""); sub(/\r$/, ""); print }' "$headers")
		[[ "$location" == https://* && "$location" != *$'\n'* ]] || { echo "Invalid artifact redirect" >&2; exit 1; }
		curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
			--max-filesize 9600000000 --output "$archive" "$location"
		;;
	*) echo "Unexpected artifact response: $http_status" >&2; exit 1 ;;
esac

go run scripts/extract-cache.go "$archive" "$RUNNER_TEMP/mise-cache"
manifest="$RUNNER_TEMP/mise-cache/manifest.json"
jq -e --arg sha "$UPSTREAM_SHA" --arg path "$EXPECTED_STORE_PATH" \
	'.schema_version == 1 and .upstream_sha == $sha and .store_path == $path and .system == "aarch64-darwin"' "$manifest" >/dev/null
{
	printf 'store_path=%s\n' "$EXPECTED_STORE_PATH"
	printf 'closure_bytes=%s\n' "$(jq -er '.closure_size_bytes | select(type == "number" and . >= 0 and floor == .)' "$manifest")"
	printf 'export_bytes=%s\n' "$(jq -er '.export_size_bytes | select(type == "number" and . >= 0 and floor == .)' "$manifest")"
} >> "$GITHUB_OUTPUT"
