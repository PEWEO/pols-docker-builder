#!/usr/bin/env bash
# Finds out whether this job has a pols runner cache.
#
# On a pols runner, the runner's environment names a status file
# (POLS_CACHE_STATUS) that pols writes once GitHub has told it which job the
# runner runs: {"state":"ready","path":...,"saved":...} when the repository's
# cache is mounted, or {"state":"none","reason":...}. Anywhere else the
# variable is unset and the action behaves like the one it replaces.
#
# Writes mode=cached|fallback, path, saved and reason to $GITHUB_OUTPUT.
set -euo pipefail

out="${GITHUB_OUTPUT:-/dev/stdout}"
status="${POLS_CACHE_STATUS:-}"
wait_s="${POLS_CACHE_WAIT:-60}"

emit() {
	local mode="$1" path="$2" saved="$3" reason="$4"
	{
		echo "mode=${mode}"
		echo "path=${path}"
		echo "saved=${saved}"
		echo "reason=${reason}"
	} >>"${out}"
}

if [[ -z "${status}" ]]; then
	echo "Not on a pols runner: no cache, doing what the upstream action does."
	emit fallback "" false "not a pols runner"
	exit 0
fi
if ! [[ "${wait_s}" =~ ^[0-9]+$ ]]; then
	echo "::error::cache-wait must be a whole number of seconds, not '${wait_s}'"
	exit 1
fi

deadline=$((SECONDS + wait_s))
until [[ -s "${status}" ]]; do
	if ((SECONDS >= deadline)); then
		echo "::notice title=pols cache::pols did not say within ${wait_s}s whether this job has a cache; running without one."
		emit fallback "" false "no word from pols within ${wait_s}s"
		exit 0
	fi
	sleep 0.5
done

read_field() {
	python3 -c 'import json, sys
d = json.load(open(sys.argv[1]))
v = d.get(sys.argv[2], "")
print(str(v).lower() if isinstance(v, bool) else v)' "${status}" "$1"
}

state="$(read_field state)"
path="$(read_field path)"
saved="$(read_field saved)"
reason="$(read_field reason)"

if [[ "${state}" != "ready" ]]; then
	echo "::notice title=pols cache::No cache for this job: ${reason:-pols gave none}."
	emit fallback "" false "${reason:-no cache}"
	exit 0
fi
if ! [[ -d "${path}" && -w "${path}" ]]; then
	echo "::warning title=pols cache::pols said the cache is at '${path}', but it is not a writable directory; running without one."
	emit fallback "" false "cache directory not writable"
	exit 0
fi
if [[ "${saved}" == "true" ]]; then
	echo "pols cache at ${path}: kept for the next job if this one succeeds."
else
	echo "pols cache at ${path}: read from, but not kept (${reason:-this job does not write to the cache})."
fi
emit cached "${path}" "${saved}" "${reason}"
