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

PROVIDERS="mlx-serve lmstudio ollama"
resume=""
map_dirs=""
language=""
provider=""
wrapped="n"
llm_context=0
echo_command="n"

while getopts "a:c:d:ehl:m:r:w" opt; do
    case $opt in
      a)
        agent="${OPTARG}"
        ;;
      c)
        llm_context=$(( "${OPTARG}" * 1024 ))
        ;;
      d)
        map_dirs="${map_dirs} -v ${OPTARG}:${OPTARG}:ro"
        ;;
      e)
        echo_command="y"
        ;;
      h)
        echo "Usage: $0 [OPTIONS]"
        echo "Options:"
        echo "  -a AGENT    Specify the agent to use (default: claude)"
        echo "  -c CONTEXT  Specify the size of the LLM context (in K)"
        echo "  -d DIR      Specify a directory to map into the container"
        echo "  -e          Echo the command that you would run instead of running it"
        echo "  -h          Display this help message"
        echo "  -l LANGUAGE  Specify the programming language"
        echo "  -m MODEL     Specify the model to use"
        echo "  -r RESUME   Specify a resume checkpoint for the agent"
        echo "  -w          Launch agent via ollama"
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
      w)
        wrapped="y"
        ;;
      *)
        echo "Invalid option: -$opt"
        exit 1
        ;;
    esac
done

if [ ${llm_context} = 0 ]; then
  echo "Please specify a context length"
  exit 1
fi

for pr in ${PROVIDERS};
do
  if ps -e | grep -v docker | grep $pr | grep -v grep >/dev/null; then
    provider="$pr"
    break
  fi
done  

if [ "$provider" = "ollama" ]; then
  echo "Using Ollama provider"
  provider_port="11434"
  wrapped="y"
elif [ "$provider" = "lmstudio" ]; then
  echo "Using LMStudio provider"
  provider_port="1234"
elif [ "$provider" = "mlx-serve" ]; then
  echo "Using mlx-serve provider"
  provider_port="1234"
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
      if ls ${pack_dir}/*.go >/dev/null 2>&1
      then
        echo "Go files found in ${pack_dir}, proceeding to build..."
        docker exec ${cont_name} bash -c "cd ${pack_dir} && go build ." || { echo 'go build failed'; exit 1; };
      else
        echo "No Go files found in ${pack_dir}, skipping build."
        continue
      fi
    done
fi

case $agent in
      claude)
        # https://backgroundclaude.com/cli-reference
        
        # we need to add the env var IS_SANDBOX to avoid getting an error
        # https://code.claude.com/docs/en/permission-modes#skip-all-checks-with-bypasspermissions-mode
        # https://github.com/anthropics/claude-code/issues/3490
        # CLAUDE_CODE_MAX_OUTPUT_TOKENS=128000 \
        my_exports=" \
          ANTHROPIC_TIMEOUT_MS=600000 \
          CLAUDE_CODE_AUTO_COMPACT_WINDOW=${llm_context} \
          IS_SANDBOX=1 \
          CLAUDE_CODE_DISABLE_MOUSE=1 \
          CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN=1 \
          CLAUDE_CONFIG_DIR=\"${mac_path}/.claude\" \
          "
          if [ "$wrapped" = "n" ]; then
            my_exports=" ${my_exports} \
              ANTHROPIC_BASE_URL=http://host.docker.internal:${provider_port} \
              ANTHROPIC_AUTH_TOKEN=\"$provider\" \
              "
            # Claude defaults to injecting hundreds of specialized system prompt instructions and dynamic tags on every single turn,
            # destroying your local model's Key-Value (KV) cache.
            # Adding the --bare flag strip-mines unnecessary telemetry and forces a leaner, faster context loop
            # https://medium.com/@vito.rallo/running-claude-code-with-local-llms-all-lies-until-now-3e9a0084dfe1
            add_options="--bare --strict-mcp-config" # and --tools
          else
            my_exports=" ${my_exports} \
            OLLAMA_API_BASE_URL=http://host.docker.internal:${provider_port} \
            OLLAMA_HOST=http://host.docker.internal:${provider_port} \
            ANTHROPIC_AUTH_TOKEN=\"$provider\" \
            "
          fi
          add_commands="claude update"
          acp_agent="claude-agent-acp"
                    
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
                        \"tools\": true,
                        \"limit\": { \
                          \"context\": ${llm_context}, \
                          \"output\": 8192 \
                        } \
                }")
        done

        prov_models_list=$(echo $(IFS=,;printf  "%s" "${prov_models_list[*]}"))

        if [ "$wrapped" = "n" ]; then
          :
        else
          my_exports=" ${my_exports} \
            OLLAMA_API_BASE_URL=http://host.docker.internal:${provider_port} \
            OLLAMA_HOST=http://host.docker.internal:${provider_port} \
            "
        fi

        cat << EOF > "${conf_dir}"/opencode.json 
{
  "\$schema": "https://opencode.ai/config.json",
  "provider": {
    "${provider}": {
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
  "model": "${provider}/${model_realname}",
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
        if [ "$wrapped" = "n" ]; then
          echo "codex does not play well without ollama, use wrapped mode"
          exit 1
          my_exports=" ${my_exports} \
            OPENAI_API_BASE=\"http://host.docker.internal:${provider_port}\" \
            OPENAI_API_KEY=\"${provider}\" \
            "
            add_options="--profile ${provider}_id $add_options"
        else
          if [ "$provider" = "lmstudio" ]; then
            echo "codex does not play well with ollama talking to lmstudio, use wrapped and ollama"
            exit 1
          fi
          my_exports=" ${my_exports} \
            OLLAMA_API_BASE_URL=http://host.docker.internal:${provider_port} \
            OLLAMA_HOST=http://host.docker.internal:${provider_port} \
            OPENAI_API_KEY=\"${provider}\" \
            "
        fi
# Codex is transitioning to a new way to have profiles
# and the config here under does not work anymore
# https://developers.openai.com/codex/config-advanced#profiles

#         cat << EOF > "${conf_dir}"/config.toml
# oss_provider = "${provider}"
# model = "${model_realname}"
# model_reasoning_effort = "high"
# model_provider = "${provider}_id"
# [model_providers.${provider}_id]
# name = "${provider}"
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
        # Remove maxTokens as it generates "Error: Model stopped because it reached the maximum output token limit."
        # Apparently pi defaults to the provider's default if no maxTokens is set in config, and if no maxTokens to 16384.
        # It then sends to the API the minimun between:
        # model.maxTokens and (available context window minus safety tokens (4096) and estimated context size)
        # 
        # prov_models_list=$(curl http://localhost:${provider_port}/v1/models 2>/dev/null | jq -r --argjson ctx "${llm_context}" '.data[] | "{\"id\" : \"\(.id)\",\"contextWindow\" : \($ctx), \"maxTokens\" : 8192},"')
        prov_models_list=$(curl http://localhost:${provider_port}/v1/models 2>/dev/null | jq -r --argjson ctx "${llm_context}" '.data[] | "{\"id\" : \"\(.id)\",\"contextWindow\" : \($ctx)},"')
        prov_models_list=$(echo ${prov_models_list::-1})
        # prov_models_list=$(curl http://localhost:${provider_port}/api/v0/models 2>/dev/null | jq -r '.data[] | select(.loaded_context_length != null) | "{\"id\" : \"\(.id)\",\"contextWindow\" : \(.loaded_context_length)},"')

        if [ "$wrapped" = "n" ]; then
          :
        else
          my_exports=" ${my_exports} \
            OLLAMA_API_BASE_URL=http://host.docker.internal:${provider_port} \
            OLLAMA_HOST=http://host.docker.internal:${provider_port} \
            "
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

        add_commands="pi update && pi install git:github.com/DietrichGebert/ponytail && pi update --extensions"
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

agent_script="${mac_path}/.${agent}/run_${agent}.sh"

echo -e "#!/bin/bash\n" > ${agent_script}
echo -e "source ~/.bashrc\n" >> ${agent_script}
echo -e "export ${my_exports}\n" >> ${agent_script}
echo -e "${add_commands}\n" >> ${agent_script}

# exit 0
# Launch the Agent
echo "Container is UP. Launching ${agent} Agent with provider ${provider}"
if [ "${wrapped}" = "y" ]; then
  echo -e "ollama launch ${agent} --model ${model_realname} -- ${add_options}" >> ${agent_script}
else
  echo -e "if [ \"\$1\" == \"local\" ];then" >> ${agent_script}
	echo -e "\tANTHROPIC_BASE_URL=http://localhost:1234" >> ${agent_script}
  echo -e "fi" >> ${agent_script}
  echo -e "if [ \"\$2\" == \"acp\" ];then" >> ${agent_script}
  echo -e "\t${acp_agent} --model ${model_realname} ${add_options}" >> ${agent_script}
  echo -e "else" >> ${agent_script}
  echo -e "\t${agent} --model ${model_realname} ${add_options}" >> ${agent_script}
  echo -e "fi" >> ${agent_script}
fi

docker exec ${cont_name} chmod +x $agent_script
docker_cmd="docker exec -it ${cont_name} bash -c ${agent_script}"

if [ "${echo_command}" = "y" ]; then
  echo "${docker_cmd}"
else
  eval ${docker_cmd}
fi

