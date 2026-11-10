#!/usr/bin/env bash
# Passes the build's cache-from and cache-to on, leaving out GitHub's
# cache service (type=gha) while the layer cache is on the pols runner
# cache: exporting to it would only slow the build down.
set -euo pipefail

out="${GITHUB_OUTPUT:-/dev/stdout}"

filter() {
	local line
	while IFS= read -r line; do
		if [[ "${POLS_DOCKER_CACHED:-}" == "true" && "${line}" =~ (^|,)[[:space:]]*type=gha([[:space:]]*,|[[:space:]]*$) ]]; then
			echo "Leaving out '${line}': the layer cache is on the pols runner cache." >&2
			continue
		fi
		printf '%s\n' "${line}"
	done <<<"$1"
}

for name in cache-from cache-to; do
	value="CACHE_FROM"
	[[ "${name}" == cache-to ]] && value="CACHE_TO"
	delim="EOF_$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
	{
		echo "${name}<<${delim}"
		[[ -n "${!value:-}" ]] && filter "${!value}"
		echo "${delim}"
	} >>"${out}"
done
