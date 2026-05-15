# Get the absolute path of the current directory on your Mac
mac_path=$(pwd)
echo "Current directory on Mac: ${mac_path}"

parentbasename=$(basename $(dirname $mac_path)| tr '[:upper:]' '[:lower:]')
currentbasename=$(basename $mac_path | tr '[:upper:]' '[:lower:]')
cont_name="agent-sandbox-${parentbasename}_${currentbasename}"
model="qwen3.6:latest"
agent="claude"


# add_options="--permission-mode bypassPermissions"
add_options=""
map_dirs=""
IS_SANDBOX=0
while getopts "d:hr:sw" opt; do
    case $opt in
      d)
        map_dirs="${map_dirs} -v ${OPTARG}:${OPTARG}:ro"
        ;;
      h)
        add_options="${add_options} --effort xhigh"
        ;;
      r)
        add_options="${add_options} --resume ${OPTARG}"
        ;;
      s)
        # Given this flag cannot be set when the user is root even in a container, 
        # we need to add the env var IS_SANDBOX to avoid getting an error
        # https://code.claude.com/docs/en/permission-modes#skip-all-checks-with-bypasspermissions-mode
        # https://github.com/anthropics/claude-code/issues/3490
        add_options="${add_options} --dangerously-skip-permissions"
        IS_SANDBOX=1
        ;;
      w)
        writerequirements="true"
        ;;
      *)
        echo "Invalid option: -$opt"
        exit 1
        ;;
    esac
done

if [ "${writerequirements}" = "true" ]; then
    echo "Writing requirements.txt with current venv packages..."
    pip list --format=freeze > requirements.txt || { echo "Failed to write requirements.txt, are you in a virtual environment?"; exit 1; }
fi

if [ "$(docker ps -q -f name=${cont_name})" ]; then
  echo "Container '${cont_name}' is already running."
elif [ "$(docker ps -aq -f name=${cont_name})" ]; then
  echo "Container '${cont_name}' exists but is not running. Starting it..."
  docker start ${cont_name}
else

  docker build -t ${cont_name}-image --file $(readlink -f ~/bin/Agents/Dockerfile) . || { echo "Docker build failed."; exit 1; }

  # Remove old container if it exists
  docker rm -f ${cont_name} 2>/dev/null || true

  # Run the container in the background (-d)
  # We mount the current directory to the same path in the container, to be able to resume the session also outside of the container.
  # We also mount the .claude directory to share the same settings.
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

  docker run -d \
    --name ${cont_name} \
    -e OLLAMA_HOST=host.docker.internal:11434 \
    -v "$mac_path:$mac_path" \
    ${map_dirs} \
    -w "$mac_path" \
    ${cont_name}-image || { echo "Failed to start container"; exit 1; }


  # Wait for readiness
  echo "Waiting for container to be ready..."
  max_retries=10
  retry_count=0
  until [ "$(docker inspect -f '{{.State.Running}}' ${cont_name} 2>/dev/null)" == "true" ]; do
      sleep 1
      ((retry_count++))
      if [ $retry_count -ge $max_retries ]; then
          echo "Container failed to start in time"
          docker logs ${cont_name}
          exit 1
      fi
  done
fi

# Handle Virtual Environment with UV
echo "Setting up Python sandbox..."
# Create venv if it doesn't exist
docker exec ${cont_name} uv venv --allow-existing --quiet || { echo "Failed to create venv"; exit 1; }

# Install requirements if they exist
if [ -f requirements.txt ]; then
    echo "Syncing project dependencies..."
    docker exec ${cont_name} uv pip install -r requirements.txt || { echo "Dependency sync failed"; exit 1; }
fi

# Launch the Agent
# We use 'uv run' which automatically activates the .venv for the agent
echo "Container is UP. Launching ${agent} Agent..."
docker exec -it ${cont_name} bash -c "echo \"export IS_SANDBOX=${IS_SANDBOX}\" >> /root/.bashrc; source /root/.bashrc; uv run ollama launch ${agent} --model ${model} -- ${add_options}"
