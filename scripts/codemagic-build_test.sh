#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/source/cache"

export MOCK_UPSTREAM_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export MOCK_PROJECT_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
export MOCK_STORE_PATH=/nix/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-mise-test
export MOCK_ARCHIVE="$tmp/source.tar"
export MOCK_LOG="$tmp/curl.log"
jq -n --arg sha "$MOCK_UPSTREAM_SHA" --arg path "$MOCK_STORE_PATH" \
	'{schema_version: 1, upstream_sha: $sha, store_path: $path, system: "aarch64-darwin", closure_size_bytes: 10, export_size_bytes: 5}' > "$tmp/source/manifest.json"
printf 'StoreDir: /nix/store\n' > "$tmp/source/cache/nix-cache-info"
COPYFILE_DISABLE=1 tar -C "$tmp/source" -cf "$MOCK_ARCHIVE" manifest.json cache

cat > "$tmp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
method=GET
output=
headers=
data=
auth=false
url=
while (($#)); do
	case "$1" in
		-X) method=$2; shift 2 ;;
		-H) [[ "$2" != x-auth-token:* ]] || auth=true; shift 2 ;;
		--output) output=$2; shift 2 ;;
		--dump-header) headers=$2; shift 2 ;;
		--data) data=$2; method=POST; shift 2 ;;
		--write-out|--max-time|--max-filesize|--proto|--proto-redir) shift 2 ;;
		https://*) url=$1; shift ;;
		*) shift ;;
	esac
done
printf '%s %s auth=%s\n' "$method" "$url" "$auth" >> "$MOCK_LOG"
case "$method $url" in
	'POST https://api.codemagic.io/builds')
		[[ "$auth" == true ]]
		jq -e --arg upstream "$MOCK_UPSTREAM_SHA" --arg project "$MOCK_PROJECT_SHA" \
			'.workflowId == "build-mise-cache" and .environment.variables.UPSTREAM_SHA == $upstream and .environment.variables.EXPECTED_PROJECT_COMMIT == $project' <<< "$data" >/dev/null
		printf '{"buildId":"123abc"}\n'
		;;
	'GET https://codemagic.io/api/v3/builds/123abc')
		[[ "$auth" == true ]]
		status=finished
		[[ "$MOCK_CASE" != failed ]] || status=failed
		[[ "$MOCK_CASE" != unexpected ]] || status=unknown
		jq -n --arg status "$status" '{data: {status: $status}}'
		;;
	'GET https://api.codemagic.io/builds/123abc')
		[[ "$auth" == true ]]
		commit=$MOCK_PROJECT_SHA
		[[ "$MOCK_CASE" != wrong_commit ]] || commit=$MOCK_UPSTREAM_SHA
		jq -n --arg commit "$commit" \
			'{build: {commit: {hash: $commit}, artefacts: [{url: "https://api.codemagic.io/artifacts/a/b/mise-cache.tar"}]}}'
		;;
	'GET https://api.codemagic.io/artifacts/a/b/mise-cache.tar')
		[[ "$auth" == true ]]
		printf 'HTTP/1.1 302 Found\r\nLocation: https://storage.example.test/archive\r\n\r\n' > "$headers"
		: > "$output"
		printf 302
		;;
	'GET https://storage.example.test/archive')
		[[ "$auth" == false ]]
		cp "$MOCK_ARCHIVE" "$output"
		;;
	'POST https://api.codemagic.io/builds/123abc/cancel')
		[[ "$auth" == true ]]
		;;
	*) echo "unexpected mock request: $method $url" >&2; exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/curl"

export PATH="$tmp/bin:$PATH"
export CODEMAGIC_API_TOKEN=test-token
export CODEMAGIC_APP_ID=123abc
export UPSTREAM_SHA=$MOCK_UPSTREAM_SHA
export EXPECTED_STORE_PATH=$MOCK_STORE_PATH
export GITHUB_SHA=$MOCK_PROJECT_SHA
export GITHUB_REF_NAME=main

run_case() {
	export MOCK_CASE=$1
	export RUNNER_TEMP="$tmp/$MOCK_CASE"
	export GITHUB_OUTPUT="$RUNNER_TEMP/output"
	mkdir "$RUNNER_TEMP"
	: > "$GITHUB_OUTPUT"
	: > "$MOCK_LOG"
	bash "$root/scripts/codemagic-build.sh"
}

cd "$root"
run_case success
test -f "$tmp/success/mise-cache/manifest.json"
grep -q '^closure_bytes=10$' "$tmp/success/output"
grep -q '^export_bytes=5$' "$tmp/success/output"
grep -q '^GET https://storage.example.test/archive auth=false$' "$MOCK_LOG"

if run_case failed; then echo 'failed build was accepted' >&2; exit 1; fi
if run_case wrong_commit; then echo 'wrong commit was accepted' >&2; exit 1; fi
if run_case unexpected; then echo 'unexpected status was accepted' >&2; exit 1; fi
grep -q '^POST https://api.codemagic.io/builds/123abc/cancel auth=true$' "$MOCK_LOG"
echo 'Codemagic orchestration checks passed'
