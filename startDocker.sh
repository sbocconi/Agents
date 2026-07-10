#!/usr/bin/env bash
SCRIPT_DIR=$(dirname $(readlink -f "$0"))

# Import common functions
. ${SCRIPT_DIR}/comm_fun.sh


if ! colima status > /dev/null 2>&1; then
  echo "Colima is not running. Starting Colima..."
  colima start --vm-type=vz --mount-type=virtiofs --cpu 4 --memory 8 || { echo "Failed to start Colima. Please ensure Colima is installed and configured correctly."; exit 1; }
else
  echo "Colima is already running."
fi

# Get the absolute path of the current directory on your Mac
mac_path=$(pwd)
echo "Current directory on Mac: ${mac_path}"

parentbasename=$(basename $(dirname $mac_path)| tr '[:upper:]' '[:lower:]')
currentbasename=$(basename $mac_path | tr '[:upper:]' '[:lower:]')
cont_name="agent-sandbox-${parentbasename}_${currentbasename}"
model="qwen3-coder-next"

# Avoid for local agents: copilot, codex, or kimi are primarily heavily tuned toward cloud endpoints 
# and have worse translation layers when forced to run locally.
# Installed on the docker image:  claude.ai, opencode.ai, codex, copilot, pi      
agent="claude"

resume=""
map_dirs=""
language=""
provider=""

while getopts "a:d:hl:m:p:r:" opt; do
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
        echo "  -m MODEL     Specify the model to use"
        echo "  -p PROVIDER  Specify the provider (ollama, wrapped_ollama, or lms)"
        echo "  -r RESUME   Specify a resume checkpoint for the agent"
        exit 0
        ;;
      l)
        language="${OPTARG}"
        ;;
      m)
        model="${OPTARG}"
        ;;
      p)
        provider="${OPTARG}"
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

if [ "$provider" = "ollama" ]; then
  echo "Using Ollama provider"
  provider_port="11434"
  provider_name="ollama"
elif [ "$provider" = "wrapped_ollama" ]; then
  echo "Using Wrapped Ollama to Ollamaprovider"
  provider_port="11434"
  provider_name="ollama"
elif [ "$provider" = "lms" ]; then
  echo "Using LMS provider"
  provider_port="1234"
  provider_name="lms"
elif [ "$provider" = "wrapped_lms" ]; then
  echo "Using Wrapped Ollama to LMS provider"
  provider_port="1234"
  provider_name="lms"
elif [ "$provider" = "mlx-serve" ]; then
  echo "Using mlx-serve provider"
  provider_port="1234"
  provider_name="mlx-serve"
else
  echo "Invalid provider: $provider"
  exit 1
fi

model_realname=$(curl http://localhost:${provider_port}/v1/models 2>/dev/null | jq -r '.data[].id' | grep -i --max-count 1 ${model})

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
        # https://backgroundclaude.com/cli-reference
        
        # we need to add the env var IS_SANDBOX to avoid getting an error
        # https://code.claude.com/docs/en/permission-modes#skip-all-checks-with-bypasspermissions-mode
        # https://github.com/anthropics/claude-code/issues/3490
        my_exports=" \
          ANTHROPIC_TIMEOUT_MS=600000 \
          CLAUDE_CODE_MAX_OUTPUT_TOKENS=128000 \
          IS_SANDBOX=1 \
          CLAUDE_CODE_DISABLE_MOUSE=1 \
          CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1 \
          "
          if [ "$provider" = "ollama" -o "$provider" = "lms" -o "$provider" = "mlx-serve" ]; then
            my_exports=" ${my_exports} \
              ANTHROPIC_BASE_URL=http://host.docker.internal:${provider_port} \
              ANTHROPIC_AUTH_TOKEN=\"$provider_name\" \
              "
            # Claude defaults to injecting hundreds of specialized system prompt instructions and dynamic tags on every single turn,
            # destroying your local model's Key-Value (KV) cache.
            # Adding the --bare flag strip-mines unnecessary telemetry and forces a leaner, faster context loop
            # https://medium.com/@vito.rallo/running-claude-code-with-local-llms-all-lies-until-now-3e9a0084dfe1
            add_options="--bare --strict-mcp-config" # and --tools
          elif [ "$provider" = "wrapped_ollama" -o "$provider" = "wrapped_lms" ]; then
            my_exports=" ${my_exports} \
            OLLAMA_API_BASE_URL=http://host.docker.internal:${provider_port} \
            OLLAMA_HOST=http://host.docker.internal:${provider_port} \
            ANTHROPIC_AUTH_TOKEN=\"$provider_name\" \
            "
          else
            echo "Invalid provider: $provider"
            exit 1
          fi
          add_commands=":"
                    
          add_options="${add_options} --effort xhigh --dangerously-skip-permissions"
          if [ -n "${resume}" ]; then
            add_options="$add_options --resume ${resume}"
          fi
        ;;
      opencode)
        conf_dir="${mac_path}/.opencode"
        mkdir -p "${conf_dir}"
        my_exports="OPENCODE_CONFIG=\"${conf_dir}\"/opencode.json \
        OPENCODE_TUI_CONFIG=\"${conf_dir}\"/tui.json \
        "
        prov_models_list=()
        for mod in $(curl http://localhost:${provider_port}/v1/models 2>/dev/null | jq -r '.data[].id');
        do
            prov_models_list+=("\"${mod}\": { \
                  \"name\": \"${mod}\", \
                  \"tools\": true
                }")
        done
        prov_models_list=$(echo $(IFS=,;printf  "%s" "${prov_models_list[*]}"))

        if [ "$provider" = "ollama" -o "$provider" = "lms" -o "$provider" = "mlx-serve" ]; then
          :
        elif [ "$provider" = "wrapped_ollama" -o "$provider" = "wrapped_lms" ]; then
          my_exports=" ${my_exports} \
            OLLAMA_API_BASE_URL=http://host.docker.internal:${provider_port} \
            OLLAMA_HOST=http://host.docker.internal:${provider_port} \
            "
        else
          echo "Invalid provider: $provider"
          exit 1
        fi

        cat << EOF > "${conf_dir}"/opencode.json 
{
  "\$schema": "https://opencode.ai/config.json",
  "provider": {
    "${provider_name}": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "${provider} local",
      "options": {
        "baseURL": "http://host.docker.internal:${provider_port}/v1"
      },
      "models": {
        $prov_models_list
      }
    }
  },
  "model": "${provider_name}/${model_realname}",
  "permission": "allow"
}
EOF
        cat << EOF > "${conf_dir}"/tui.json
{
  "\$schema": "https://opencode.ai/tui.json",
  "mouse": false
}
EOF
        add_commands=":"
        add_options=""
        if [ -n "${resume}" ]; then
              add_options="$add_options -s ${resume}"
        fi
        ;;
      copilot)
        echo "Copilot agent is not yet supported, please use another agent for now."
        exit 1
        ;;
      codex)
        conf_dir="./.codex"
        mkdir -p "${conf_dir}"
        if [ "$provider" = "ollama" -o "$provider" = "lms" -o "$provider" = "mlx-serve" ]; then
          echo "codex does not play well without ollama, use wrapped_ollama"
          exit 1
          my_exports=" ${my_exports} \
            OPENAI_API_BASE=\"http://host.docker.internal:${provider_port}\" \
            OPENAI_API_KEY=\"${provider_name}\" \
            "
            add_options="--profile ${provider_name}_id $add_options"
        elif [ "$provider" = "wrapped_ollama" -o "$provider" = "wrapped_lms" ]; then
          if [ "$provider" = "wrapped_lms" ]; then
            echo "codex does not play well with ollama talking to lms, use wrapped_ollama"
            exit 1
          fi
          my_exports=" ${my_exports} \
            OLLAMA_API_BASE_URL=http://host.docker.internal:${provider_port} \
            OLLAMA_HOST=http://host.docker.internal:${provider_port} \
            OPENAI_API_KEY=\"${provider_name}\" \
            "
        else
          echo "Invalid provider: $provider"
          exit 1
        fi
# Codex is transitioning to a new way to have profiles
# and the config here under does not work anymore
# https://developers.openai.com/codex/config-advanced#profiles

#         cat << EOF > "${conf_dir}"/config.toml
# oss_provider = "${provider_name}"
# model = "${model_realname}"
# model_reasoning_effort = "high"
# model_provider = "${provider_name}_id"
# [model_providers.${provider_name}_id]
# name = "${provider_name}"
# base_url = "http://host.docker.internal:${provider_port}/v1"
# requires_openai_auth = false
# api_key = "${provider}"
# env_key = "${provider}"
# wire_api = "responses"
# [projects."${mac_path}"]
# trust_level = "trusted"

# EOF
        add_commands=":"
        if [ -n "${resume}" ]; then
              add_options="$add_options resume ${resume}"
        fi
        ;;
      pi)
        conf_dir="./.pi"
        mkdir -p "${conf_dir}"
        my_exports="PI_CODING_AGENT_DIR=\"${conf_dir}\" \
        "
        prov_models_list=$(curl http://localhost:${provider_port}/v1/models 2>/dev/null | jq -r '.data[] | "{\"id\" : \"\(.id)\",\"contextWindow\" : 48128},"')
        prov_models_list=$(echo ${prov_models_list::-1})
        # prov_models_list=$(curl http://localhost:${provider_port}/api/v0/models 2>/dev/null | jq -r '.data[] | select(.loaded_context_length != null) | "{\"id\" : \"\(.id)\",\"contextWindow\" : \(.loaded_context_length)},"')

        if [ "$provider" = "ollama" -o "$provider" = "lms" -o "$provider" = "mlx-serve" ]; then
          :
        elif [ "$provider" = "wrapped_ollama" -o "$provider" = "wrapped_lms" ]; then
          my_exports=" ${my_exports} \
            OLLAMA_API_BASE_URL=http://host.docker.internal:${provider_port} \
            OLLAMA_HOST=http://host.docker.internal:${provider_port} \
            "
        else
          echo "Invalid provider: $provider"
          exit 1
        fi

        cat << EOF > "${conf_dir}"/models.json 
{
  "providers": {
    "$provider": {
      "baseUrl": "http://host.docker.internal:${provider_port}/v1",
      "api": "openai-completions",
      "apiKey": "$provider",
      "models": [
        $prov_models_list
      ]
    }
  }
}
EOF
        add_commands="pi update && pi update --extensions"
        add_options=""
        if [ -n "${resume}" ]; then
              add_options="$add_options --session ${resume}"
        fi
        ;;
      *)
        echo "Invalid agent: -$agent"
        exit 1
        ;;
    esac

my_exports=$(echo "${my_exports}" | tr -s ' ')
echo "commands to run in container: ${add_commands}"
echo "options to run in container: ${add_options}"
echo "exports to run in container: ${my_exports}"
# exit 0
# Launch the Agent
echo "Container is UP. Launching ${agent} Agent with provider ${provider}"
if [[ "${provider}" == *"wrapped_"* ]]; then
  docker exec -it ${cont_name} bash -c "export ${my_exports}; ${add_commands} ; ollama launch ${agent} --model ${model_realname} -- ${add_options}"
else
  docker exec -it ${cont_name} bash -c "export ${my_exports}; ${add_commands} ; ${agent} --model ${model_realname} ${add_options}"
fi

