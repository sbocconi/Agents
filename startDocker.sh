#!/usr/bin/env bash
SCRIPT_DIR=$(dirname $(readlink -f "$0"))

# Import common functions
. ${SCRIPT_DIR}/comm_fun.sh

# Get the absolute path of the current directory on your Mac
mac_path=$(pwd)
echo "Current directory on Mac: ${mac_path}"

parentbasename=$(basename $(dirname $mac_path)| tr '[:upper:]' '[:lower:]')
currentbasename=$(basename $mac_path | tr '[:upper:]' '[:lower:]')
cont_name="agent-sandbox-${parentbasename}_${currentbasename}"
model="qwen3-coder-next:latest"

# Avoid for local agents: copilot, codex, or kimi are primarily heavily tuned toward cloud endpoints 
# and have worse translation layers when forced to run locally.
agent="claude"

resume=""
map_dirs=""
language=""

while getopts "a:d:hl:r:" opt; do
    case $opt in
      a)
        agent="${OPTARG}"
        ;;
      d)
        map_dirs="${map_dirs} -v ${OPTARG}:${OPTARG}:ro"
        ;;
      h)
        echo "Usage: $0 [OPTIONS]"
        echo "Options:"
        echo "  -a AGENT    Specify the agent to use (default: claude)"
        echo "  -d DIR      Specify a directory to map into the container"
        echo "  -h          Display this help message"
        echo "  -l LANGUAGE  Specify the programming language"
        echo "  -r RESUME   Specify a resume checkpoint for the agent"
        exit 0
        ;;
      l)
        language="${OPTARG}"
        ;;
      r)
        resume="${OPTARG}"
        ;;
      *)
        echo "Invalid option: -$opt"
        exit 1
        ;;
    esac
done

if [ "${language}" = "python" ]; then
    dockerfile="${SCRIPT_DIR}/PythonDockerfile"
    cont_name="${cont_name}-python"
elif [ "${language}" = "go" ]; then
    dockerfile="${SCRIPT_DIR}/GoDockerfile"
    cont_name="${cont_name}-go"
else
    echo "No language specified or unsupported language"
    exit 1
fi

startDocker ${cont_name} ${agent} ${mac_path} "${map_dirs}" ${dockerfile}

if [ "${language}" = "python" ]; then
  # Handle Virtual Environment with UV
  echo "Setting up Python sandbox..."
  # Create venv if it doesn't exist
  ${DOCKER_BIN} exec ${cont_name} uv venv --allow-existing --quiet || { echo "Failed to create venv"; exit 1; }
  echo "Writing requirements.txt with current venv packages..."
  pip list --format=freeze > requirements.txt || { echo "Failed to write requirements.txt, are you in a virtual environment?"; exit 1; }

  # Install requirements if they exist
  if [ -f requirements.txt ]; then
      echo "Syncing project dependencies..."
      has_torch=false
      while IFS= read -r line || [[ -n "$line" ]]; do
        package=$(echo "${line}" | tr -s '=' | cut -d'=' -f1)
        if [ "${package}" == "torch" ]
        then
          has_torch=true      
        else
          packages+=("${line}")
        fi
      done < requirements.txt
      # echo "Packages to install: ${packages[*]}"
      if [ "${has_torch}" = "true" ]
      then
        # PyTorch has a separate index for CPU-only packages, so we need to specify it when installing torch
          ${DOCKER_BIN} exec ${cont_name} uv pip install --index-url=https://download.pytorch.org/whl/cpu torch || { echo "Torch install failed"; exit 1; }
      fi
      ${DOCKER_BIN} exec ${cont_name} uv pip install ${packages[*]} || { echo "Dependency sync failed"; exit 1; }
  fi
elif [ "${language}" = "go" ]; then
      # Install requirements if they exist
    for gomod in $(find . -name go.mod)
    do
      pack_dir=${mac_path}/$(dirname ${gomod})
      echo "Installing Go dependencies in ${pack_dir}..."
      docker exec ${cont_name} bash -c "cd ${pack_dir} && go mod download" || { echo 'go mod download failed'; exit 1; };
      if ls ${pack_dir}/*.go 1> /dev/null 2>&1
      then
        echo "Go files found in ${pack_dir}, proceeding to build..."
        docker exec ${cont_name} bash -c "cd ${pack_dir} && go build ." || { echo 'go build failed'; exit 1; };
      else
        echo "No Go files found in ${pack_dir}, skipping build."
        cd -
        continue
      fi
      cd -
    done
fi

case $agent in
      claude)
        # we need to add the env var IS_SANDBOX to avoid getting an error
        # https://code.claude.com/docs/en/permission-modes#skip-all-checks-with-bypasspermissions-mode
        # https://github.com/anthropics/claude-code/issues/3490
        my_exports="ANTHROPIC_BASE_URL=\"http://host.docker.internal:11434\" \
          ANTHROPIC_AUTH_TOKEN=\"ollama\" \
          ANTHROPIC_API_KEY=\"\" \
          ANTHROPIC_TIMEOUT_MS=600000 \
          CLAUDE_CODE_MAX_OUTPUT_TOKENS=64000 \
          IS_SANDBOX=1 \
          CLAUDE_CODE_DISABLE_MOUSE=1 \
          "
          add_commands="source /root/.bashrc"
          add_options="--effort xhigh --dangerously-skip-permissions"
          if [ -n "${resume}" ]; then
            add_options="$add_options --resume ${resume}"
          fi
        ;;
      opencode)
        conf_dir="${mac_path}/.opencode"
        mkdir -p "${conf_dir}"
        my_exports="OPENCODE_CONFIG=\"${conf_dir}\"/opencode.json"
        cat << EOF > "${conf_dir}"/opencode.json 
{
  "\$schema": "https://opencode.ai/config.json",
  "provider": {
    "ollama": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Ollama Local",
      "options": {
        "baseURL": "http://host.docker.internal:11434/v1"
      },
      "models": {
        "${model}": {
          "name": "${model}",
          "tools": true
        }
      }
    }
  },
  "model": "ollama/${model}",
  "permission": "allow"
}
EOF
        add_commands="source /root/.bashrc"
        add_options=""
        if [ -n "${resume}" ]; then
              add_options="$add_options -s ${resume}"
        fi
        ;;
      copilot)
        echo "Copilot agent is not yet supported, please use claude or opencode agents for now."
        exit 1
        ;;
      codex)
        echo "Codex agent is not yet supported, please use claude or opencode agents for now."
        exit 1
        ;;
      *)
        echo "Invalid agent: -$agent"
        exit 1
        ;;
    esac

echo "commands to run in container: ${add_commands}"
echo "options to run in container: ${add_options}"

# exit 0
# Launch the Agent
echo "Container is UP. Launching ${agent} Agent with model ${model} and options: ${add_options}"
docker exec -it ${cont_name} bash -c "export ${my_exports}; ${add_commands} ; ${agent} --model ${model} ${add_options}"

