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
agent="claude"
claude_max_output_tokens=64000
anthropic_timeout_ms=600000

# add_options="--permission-mode bypassPermissions"
add_options=""
map_dirs=""
is_sandbox=0
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
        is_sandbox=1
        ;;
      # w)
      #   writerequirements="true"
      #   ;;
      *)
        echo "Invalid option: -$opt"
        exit 1
        ;;
    esac
done

# if [ "${writerequirements}" = "true" ]; then
#     echo "Writing requirements.txt with current venv packages..."
#     pip list --format=freeze > requirements.txt || { echo "Failed to write requirements.txt, are you in a virtual environment?"; exit 1; }
# fi

startDocker ${cont_name} ${agent} ${mac_path} "${map_dirs}" ${SCRIPT_DIR}/GoDockerfile ${is_sandbox} ${anthropic_timeout_ms} ${claude_max_output_tokens}

# # Handle Virtual Environment with UV
# echo "Setting up Python sandbox..."
# # Create venv if it doesn't exist
# docker exec ${cont_name} uv venv --allow-existing --quiet || { echo "Failed to create venv"; exit 1; }

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

# Launch the Agent
echo "Container is UP. Launching ${agent} Agent..."
docker exec -it ${cont_name} bash -c "source /root/.bashrc; ollama launch ${agent} --model ${model} -- ${add_options}"