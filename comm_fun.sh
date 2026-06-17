
startDocker() {
  DOCKER_BIN=$(command -v podman || command -v docker)
  cont_name=${1}
  agent=${2}
  mac_path=${3}
  map_dirs=${4}
  Dockerfile=${5}

  echo "Pruning unused Docker cache..."
  ${DOCKER_BIN} builder prune -f || { echo "Failed to prune Docker cache"; exit 1; }

  if [ "$(${DOCKER_BIN} ps -q -f name=${cont_name})" ]; then
    echo "Container '${cont_name}' is already running."
  elif [ "$(${DOCKER_BIN} ps -aq -f name=${cont_name})" ]; then
    echo "Container '${cont_name}' exists but is not running. Starting it..."
    ${DOCKER_BIN} start ${cont_name}
  else

    ${DOCKER_BIN} build -t ${cont_name}-image --file $(readlink -f ${Dockerfile}) . || { echo "Docker build failed."; exit 1; }

    # Remove old container if it exists
    ${DOCKER_BIN} rm -f ${cont_name} 2>/dev/null || true

    # Run the container in the background (-d)
    # We mount the current directory to the same path in the container, to be able to resume the session also outside of the container.
    # We also mount the agent directory (for example, .claude) to share the same settings.
    # The idea is to support other agents, such as Opencode and codex, here we mount opencode's .config directory,
    # but this has not been tested yet.
    echo "Starting container..."
    if [ "${agent}" == "claude" ]; then
        map_dirs="${map_dirs} -v $HOME/.claude:/root/.claude -v $HOME/.claude.json:/root/.claude.json"
    elif [ "${agent}" == "opencode" ]; then
      map_dirs="${map_dirs} -v $HOME/.config/opencode:/root/.config/opencode"
    elif [ "${agent}" == "copilot" ]; then
      map_dirs="${map_dirs} -v $HOME/.copilot:/root/.copilot"
    else
      echo "Unsupported agent: ${agent}"
      exit 1
    fi

    ${DOCKER_BIN} run -d \
      --name ${cont_name} \
      -v "$mac_path:$mac_path" \
      ${map_dirs} \
      -w "$mac_path" \
      ${cont_name}-image || { echo "Failed to start container"; exit 1; }

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