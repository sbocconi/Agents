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

startDocker ${cont_name} ${agent} ${mac_path} "${map_dirs}" ${SCRIPT_DIR}/PythonDockerfile

# Handle Virtual Environment with UV
echo "Setting up Python sandbox..."
# Create venv if it doesn't exist
docker exec ${cont_name} uv venv --allow-existing --quiet || { echo "Failed to create venv"; exit 1; }

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
        docker exec ${cont_name} uv pip install --index-url=https://download.pytorch.org/whl/cpu torch || { echo "Torch install failed"; exit 1; }
    fi
    docker exec ${cont_name} uv pip install ${packages[*]} || { echo "Dependency sync failed"; exit 1; }
fi

# Launch the Agent
# We use 'uv run' which automatically activates the .venv for the agent
echo "Container is UP. Launching ${agent} Agent..."
docker exec -it ${cont_name} bash -c "echo \"export IS_SANDBOX=${IS_SANDBOX}\" >> /root/.bashrc; source /root/.bashrc; uv run ollama launch ${agent} --model ${model} -- ${add_options}"
