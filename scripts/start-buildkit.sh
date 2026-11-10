#!/usr/bin/env bash
# Starts BuildKit with its state on the pols runner cache and makes it a
# Buildx builder (driver remote), so a build reuses the layers of the
# repository's earlier builds.
#
# Environment: CACHE (the cache directory), and the action's inputs as
# BUILDER_NAME, USE, INSTALL, PLATFORMS, BUILDKITD_FLAGS, BUILDKITD_CONFIG,
# BUILDKITD_CONFIG_INLINE, DRIVER, DRIVER_OPTS.
set -euo pipefail

# The BuildKit release, and the SHA-256 GitHub publishes for each archive.
version="v0.34.1"
case "$(uname -m)" in
x86_64) arch=amd64 sum=a59539daf547fe0958efe2d07e41c0a6944e1112a66d7e519ec1cf5b673ef15b ;;
aarch64) arch=arm64 sum=c8c97b84baf89dfe0ea85063ac24ad88eb909979ea476ce3ef9e8e11e60ebef8 ;;
*)
	echo "::error::pols-docker-builder: no BuildKit for $(uname -m)"
	exit 1
	;;
esac

out="${GITHUB_OUTPUT:-/dev/stdout}"
name="${BUILDER_NAME:-pols}"
home="${CACHE}/buildkit"
archive="${home}/buildkit-${version}.linux-${arch}.tar.gz"
mkdir -p "${home}"

if [[ -n "${DRIVER:-}" && "${DRIVER}" != "docker-container" ]] || [[ -n "${DRIVER_OPTS:-}" ]]; then
	echo "::notice title=pols-docker-builder::driver and driver-opts do not apply on a pols runner: BuildKit runs next to the job with its state on the cache."
fi

# The archive is kept on the cache and checked on every use.
if ! [[ -f "${archive}" ]] || ! echo "${sum}  ${archive}" | sha256sum -c --status -; then
	rm -f "${archive}"
	curl -fsSL --retry 3 -o "${archive}.part" \
		"https://github.com/moby/buildkit/releases/download/${version}/buildkit-${version}.linux-${arch}.tar.gz"
	if ! echo "${sum}  ${archive}.part" | sha256sum -c --status -; then
		rm -f "${archive}.part"
		echo "::error::the BuildKit ${version} download does not match its published SHA-256"
		exit 1
	fi
	mv "${archive}.part" "${archive}"
fi
bin="$(mktemp -d)"
tar -xzf "${archive}" -C "${bin}" --strip-components=1 bin/

run=/run/pols-buildkit
sock="${run}/buildkitd.sock"
sudo mkdir -p "${run}" "${home}/state"

args=(--root "${home}/state" --addr "unix://${sock}" --group "$(id -g)")
# Garbage-collect the layer cache by the cache disk's size (MB): keep a
# fifth always, leave a tenth free, use at most three fifths.
total_mb="$(df -Pm "${CACHE}" | awk 'NR == 2 { print $2 }')"
args+=(--oci-worker-gc --oci-worker-gc-keepstorage "$((total_mb / 5)),$((total_mb / 10)),$((total_mb * 3 / 5))")
if [[ -n "${BUILDKITD_CONFIG_INLINE:-}" ]]; then
	config="$(mktemp)"
	printf '%s\n' "${BUILDKITD_CONFIG_INLINE}" >"${config}"
	args+=(--config "${config}")
elif [[ -n "${BUILDKITD_CONFIG:-}" ]]; then
	args+=(--config "${BUILDKITD_CONFIG}")
fi
if [[ -n "${BUILDKITD_FLAGS:-}" ]]; then
	read -r -a extra <<<"${BUILDKITD_FLAGS}"
	args+=("${extra[@]}")
fi

if ! sudo test -S "${sock}" || ! "${bin}/buildctl" --addr "unix://${sock}" debug workers >/dev/null 2>&1; then
	# Stopped by pols at the end of the job (SIGTERM, then SIGKILL), before
	# the cache is unmounted and kept.
	# shellcheck disable=SC2024 # the log is the job user's, not root's
	sudo env PATH="${bin}:${PATH}" nohup "${bin}/buildkitd" "${args[@]}" >"${RUNNER_TEMP:-/tmp}/pols-buildkitd.log" 2>&1 &
	for _ in $(seq 1 300); do
		"${bin}/buildctl" --addr "unix://${sock}" debug workers >/dev/null 2>&1 && break
		sleep 0.1
	done
	if ! "${bin}/buildctl" --addr "unix://${sock}" debug workers >/dev/null 2>&1; then
		echo "::error::BuildKit did not start; its log:"
		cat "${RUNNER_TEMP:-/tmp}/pols-buildkitd.log" || true
		exit 1
	fi
fi

docker buildx rm "${name}" >/dev/null 2>&1 || true
create=(docker buildx create --name "${name}" --driver remote)
if [[ -n "${PLATFORMS:-}" ]]; then create+=(--platform "${PLATFORMS}"); fi
if [[ "${USE:-true}" == "true" ]]; then create+=(--use); fi
"${create[@]}" "unix://${sock}"
docker buildx inspect --bootstrap "${name}"
if [[ "${INSTALL:-false}" == "true" ]]; then docker buildx install; fi

# awk reads it all: stopping early would kill docker with SIGPIPE.
platforms="$(docker buildx inspect "${name}" | awk -F': *' '/^Platforms:/ && !p { print $2; p = 1 }')"
{
	echo "name=${name}"
	echo "driver=remote"
	echo "platforms=${platforms}"
	echo "endpoint=unix://${sock}"
	echo "status=running"
	echo "nodes=[{\"name\":\"${name}0\",\"endpoint\":\"unix://${sock}\",\"status\":\"running\",\"platforms\":\"${platforms}\"}]"
} >>"${out}"
{
	echo "POLS_DOCKER_BUILDER=${name}"
	echo "POLS_DOCKER_CACHED=true"
} >>"${GITHUB_ENV:-/dev/null}"
echo "BuildKit ${version} runs with its state in ${home}/state; builder ${name} uses it."
