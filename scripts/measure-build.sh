#!/usr/bin/env bash
set -euo pipefail

sha=${1:?usage: measure-build.sh <upstream-sha> <output-dir>}
output_dir=${2:?usage: measure-build.sh <upstream-sha> <output-dir>}
if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
	echo "upstream_sha must be a 40-character lowercase commit SHA" >&2
	exit 2
fi

mkdir -p "$output_dir"
flake_ref="github:jdx/mise/$sha#mise"
metrics_file="$output_dir/resources.log"
started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
start_seconds=$(date +%s)

{
	printf 'upstream_sha=%s\nstarted_at=%s\n' "$sha" "$started_at"
	nix --version
	uname -a
	sysctl hw.ncpu hw.memsize || true
} > "$output_dir/runner.txt"

(
	trap 'if [[ -n "${sleep_pid:-}" ]]; then kill "$sleep_pid" 2>/dev/null || true; fi; exit 0' TERM INT
	while true; do
		{
			printf '\n--- %s ---\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
			df -k /nix || true
			vm_stat || true
			sysctl vm.swapusage || true
			top -l 2 -s 1 -n 0 | awk '/CPU usage:|PhysMem:/ { print }' || true
			printf '%s\n' 'CPU percentage, RSS in KiB, command (top 15 processes)'
			ps -A -o %cpu=,rss=,comm= | sort -nr | head -n 15 || true
		} >> "$metrics_file" 2>&1
		sleep 30 &
		sleep_pid=$!
		wait "$sleep_pid" || true
	done
) &
sampler_pid=$!
trap 'kill "$sampler_pid" 2>/dev/null || true; wait "$sampler_pid" 2>/dev/null || true' EXIT

set +e
nix build -L --no-link "$flake_ref" 2>&1 | tee "$output_dir/build.log"
build_status=("${PIPESTATUS[@]}")
set -e

kill "$sampler_pid" 2>/dev/null || true
wait "$sampler_pid" 2>/dev/null || true
trap - EXIT

finished_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
elapsed_seconds=$(( $(date +%s) - start_seconds ))
{
	printf 'finished_at=%s\nelapsed_seconds=%s\nnix_exit_status=%s\ntee_exit_status=%s\n' \
		"$finished_at" "$elapsed_seconds" "${build_status[0]}" "${build_status[1]}"
	df -k /nix || true
	vm_stat || true
	sysctl vm.swapusage || true
} >> "$output_dir/runner.txt"

if (( build_status[0] != 0 || build_status[1] != 0 )); then
	exit 1
fi

store_path=$(nix eval --raw "$flake_ref.outPath")
printf 'store_path=%s\n' "$store_path" >> "$output_dir/runner.txt"
nix path-info --closure-size --json-format 1 --json "$store_path" > "$output_dir/closure.json"
"$store_path/bin/mise" --version
