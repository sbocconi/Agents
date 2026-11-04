
# Make sure the shared image for a Dockerfile exists and print its name.
# One image per Dockerfile (so per language), shared by all project containers: agent-sandbox-<language>:<hash>,
# where the hash is taken from the Dockerfile, so editing it gives a new image and the next new container uses it.
sandboxImage() {
  DOCKER_BIN=$(command -v podman || command -v docker)
  local Dockerfile=$(readlink -f ${1})
  local lang=$(basename ${Dockerfile} Dockerfile | tr '[:upper:]' '[:lower:]')
  local image="agent-sandbox-${lang}:$(shasum -a 256 ${Dockerfile} | cut -c1-12)"
  local context old

  if ! ${DOCKER_BIN} image inspect ${image} > /dev/null 2>&1; then
    echo "Building shared image ${image}..." >&2
    # Empty build context: the Dockerfile copies nothing, so there is no need to send the project directory
    context=$(mktemp -d)
    ${DOCKER_BIN} build -t ${image} --file ${Dockerfile} ${context} >&2 || { rm -rf ${context}; echo "Docker build failed." >&2; exit 1; }
    rm -rf ${context}
    # Builds are rare now (only when the Dockerfile changes), so the build cache is not worth keeping
    echo "Pruning unused Docker build cache..." >&2
    ${DOCKER_BIN} builder prune -f > /dev/null || echo "Failed to prune Docker build cache" >&2
    # Older versions of this image that no container uses anymore (removal fails, harmlessly, for those still in use)
    for old in $(${DOCKER_BIN} images agent-sandbox-${lang} --format '{{.Repository}}:{{.Tag}}' | grep -vxF ${image}); do
      ${DOCKER_BIN} image rm ${old} > /dev/null 2>&1 && echo "Removed unused old image ${old}" >&2
    done
  fi
  echo ${image}
}

startDocker() {
  DOCKER_BIN=$(command -v podman || command -v docker)
  cont_name=${1}
  agent=${2}
  mac_path=${3}
  map_dirs=${4}
  Dockerfile=${5}

  image=$(sandboxImage ${Dockerfile}) || exit 1

  if [ "$(${DOCKER_BIN} ps -aq -f name=^${cont_name}$)" ]; then
    used=$(${DOCKER_BIN} inspect -f '{{.Config.Image}}' ${cont_name})
    # Everything that matters is in the mounted directories, so a container on an older image is recreated,
    # unless an agent session is still running in it (only `sleep infinity` left = no session)
    if [ "${used}" != "${image}" ]; then
      if [ "$(${DOCKER_BIN} top ${cont_name} -o pid 2>/dev/null | tail -n +2 | wc -l)" -gt 1 ]; then
        echo "Note: container '${cont_name}' uses the older ${used}, but a session is running in it; it moves to ${image} next time."
      else
        echo "Container '${cont_name}' uses the older ${used}: recreating it from ${image}..."
        ${DOCKER_BIN} rm -f ${cont_name} > /dev/null
        ${DOCKER_BIN} image rm ${used} > /dev/null 2>&1 && echo "Removed unused old image ${used}"
      fi
    fi
  fi

  if [ "$(${DOCKER_BIN} ps -q -f name=^${cont_name}$)" ]; then
    echo "Container '${cont_name}' is already running."
  elif [ "$(${DOCKER_BIN} ps -aq -f name=^${cont_name}$)" ]; then
    echo "Container '${cont_name}' exists but is not running. Starting it..."
    ${DOCKER_BIN} start ${cont_name}
  else

    # Run the container in the background (-d)
    # We mount the current directory to the same path in the container, to be able to resume the session also outside of the container.
    # Nothing else from the Mac is mounted (apart from -d directories, read-only): every agent keeps its settings and
    # sessions in the repo (.claude, .opencode, .codex, .pi; see startDocker.sh), so repos do not share agent state.
    echo "Starting container..."
    case "${agent}" in
      claude|opencode|copilot|codex|pi|mlx-serve) ;;
      *)
        echo "Unsupported agent: ${agent}"
        exit 1
        ;;
    esac

    # Package caches shared by all containers (Docker volumes), so each package is downloaded and stored once
    # instead of once per container: uv, pip and the Go build cache (~/.cache), npm, Go modules
    cache_dirs="-v agent-sandbox-cache:/root/.cache -v agent-sandbox-npm:/root/.npm -v agent-sandbox-gomod:/go/pkg/mod"

    echo "running container: ${cont_name}"
    echo "from image: ${image}"
    echo "with path: ${mac_path}"
    echo "mapping directories: ${map_dirs}"

    ${DOCKER_BIN} run -d \
      --name ${cont_name} \
      -v "$mac_path:$mac_path" \
      ${map_dirs} \
      ${cache_dirs} \
      -w "$mac_path" \
      ${image} || { echo "Failed to start container"; exit 1; }

    # Wait for readiness
    echo "Waiting for container to be ready..."
    max_retries=10
    retry_count=0
    until [ "$(${DOCKER_BIN} inspect -f '{{.State.Running}}' ${cont_name} 2>/dev/null)" == "true" ]; do
        sleep 1
        ((retry_count++))
        if [ $retry_count -ge $max_retries ]; then
            echo "Container failed to start in time"
            ${DOCKER_BIN} logs ${cont_name}
            exit 1
        fi
    done
  fi
}

# Stop the container after an agent session, unless another session still runs in it
# (only `sleep infinity`, the container's main process, is left). Its files are kept: the next start reuses it.
stopIdle() {
  DOCKER_BIN=$(command -v podman || command -v docker)
  cont_name=${1}
  if [ "$(${DOCKER_BIN} top ${cont_name} -o pid 2>/dev/null | tail -n +2 | wc -l)" -le 1 ]; then
    echo "Stopping container '${cont_name}' (restarted automatically next time)..."
    ${DOCKER_BIN} stop -t 2 ${cont_name} > /dev/null
  fi
}
