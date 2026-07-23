#!/bin/bash
set -euo pipefail

lms_cmd='"/Applications/LM Studio.app/Contents/Resources/app/.webpack/lms"'
lms_port=1234

ollama_port=11434
ollama_dir=~/.ollama
ollama_pid="$ollama_dir/ollama.pid"
ollama_log="$ollama_dir/logs/server.log"
tailpid_file="$ollama_dir/ollama_tail.pid"

mlx_serve_dir=~/.mlx-serve
mlx_serve_log="${mlx_serve_dir}/server.log"
mlx_serve_pid="${mlx_serve_dir}/mlx_serve.pid"
mlx_serve_port=1234

# 1024=1K 262144=256K, 65536=64K, 48128=47K, 32768=32K, 16384=16K, 8192=8K
context_lengthK=32
cache_type="q8_0"

model_identifier="qwen3.6"
# lms_model="qwen/$model_identifier"

keep_alive_min=20

usage() {
  cat <<EOF
Usage: $0 <command> [options]
Commands:
  start      Start LLM provider in the background
  stop       Stop the running LLM provider
  status     Show whether the LLM provider is running
  tail       Show live log output from the LLM provider
  help       Show this help

Options for start:
  -c VALUE   Set context_length (e.g. 128 for long-context agents (in K). Default: ${context_lengthK}K)
  -k VALUE   Set cache_type (Reduces VRAM constraints at massive contexts)
              16   - high precision (f16, default).
              8    - 8-bit quantization (q8_0, cuts memory usage by half, recommended).
              4    - 4-bit quantization (q4_0, cuts memory usage by 75%).
  -m VALUE   Set model (e.g. qwen3.6. Default: $model_identifier)
  -p VALUE   The provider to run (ollama, lms, mlx-serve)
  -t         Start tailing the log in the background immediately after boot
  -h         Show start help
EOF
}

start_service() {
  # Establish robust defaults for long-context agent sandboxes
  # MEMORY LIMITS
  # sudo sysctl iogpu.wired_mem_breakpoint_cap=57344
  # 57344 translates to exactly 56 GB in Megabytes, leaving 8 GB for system tasks.
  local tail_log=0
  local provider=""

  local existing_provider=""
  
  existing_provider=$(get_running_provider)

  while existing_provider=$(get_running_provider) && [ "$existing_provider" != "" ]; do
    stop_service $existing_provider
  done
  
  OPTIND=1
  while getopts "c:hk:m:p:t" opt; do
    case $opt in
      c)
        context_lengthK=$OPTARG
        ;;
      h)
        usage
        exit 0
        ;;
      k)
        case $OPTARG in
          16) cache_type="f16" ;;
          8)  cache_type="q8_0" ;;
          4)  cache_type="q4_0" ;;
          *)
            echo "Invalid value for -k: $OPTARG. Choose 16, 8, or 4."
            exit 1
          ;;
        esac
        ;;
      m)
        # IFS="/" read -r first second <<< "$OPTARG"
        # model="$first/$second"
        # model_identifier="$second"
        model_identifier="$OPTARG"
        ;;
      p)
        case $OPTARG in
          ollama)
            provider="ollama"
            port=$ollama_port
            ;;
          lms)
            provider="lms"
            port=$lms_port
            ;;
          mlx-serve)
            provider="mlx_serve"
            port=${mlx_serve_port}
            ;;
          *)
            echo "Invalid value for -p: $OPTARG. Choose ollama, lmstudio, or mlx-serve."
            exit 1
            ;;
        esac
        ;;
      t)
        tail_log=1
        ;;
      *)
        echo "Invalid start option: -$opt. Use '$0 help'."
        exit 1
        ;;
    esac
  done
  shift $((OPTIND - 1))
  if [ "$provider" = "" ]; then
    echo "You need to provide a provider"
    usage
    exit 1
  fi

  # Export variables to environment for lms binary consumption

  echo "====================================================="
  echo "Launching ${provider} Server with variables:"
  echo "  - context_length   = $context_lengthK"
  echo "  - port             = $port"
  echo "  - cache type       = $cache_type"
  echo "  - keep alive (min) = $keep_alive_min"
  echo "====================================================="
  echo ""
  
  local context_length=$(($context_lengthK * 1024))

  if [ "$provider" = "lms" ]; then
    eval $lms_cmd server start --bind 0.0.0.0 --port $lms_port
    lms_loaded_model | grep "$model_identifier" >/dev/null || \
    eval $lms_cmd load ${model_identifier} --ttl $(($keep_alive_min * 60 )) --gpu 1 --context-length $context_length --identifier "$model_identifier"
    echo "$model_identifier loaded"
    # Wait for server to start
  elif [ "$provider" = "ollama" ]; then
    # Export variables to environment for Ollama binary consumption
    export OLLAMA_CONTEXT_LENGTH=$context_length
    export OLLAMA_FLASH_ATTENTION=1
    export OLLAMA_KV_CACHE_TYPE=$cache_type
    export OLLAMA_KEEP_ALIVE="${keep_alive_min}m"
    export OLLAMA_HOST=127.0.0.1:$ollama_port

    ollama serve >>"$ollama_log" 2>&1 &
    local pid=$!
    echo "$pid" > "$ollama_pid"
    echo "Ollama running in background (PID=$pid)."  
  elif [ "$provider" = "mlx_serve" ]; then
    # --skip-mem-preflight \ 
    # --model ~/.lmstudio/models/lmstudio-community/Qwen3-Coder-Next-MLX-4bit/ \
    mlx-serve --serve \
    --model-dir ~/.lmstudio/models/lmstudio-community/ \
    --ctx-size $context_length \
    --port ${mlx_serve_port} \
    --log-level debug \
    --log-file "$mlx_serve_log" \
    2>&1 &
    local pid=$!
    echo "$pid" > "${mlx_serve_pid}"
    echo "Mlx-serve running in background (PID=$pid)."  
  else
    echo "Unknown provider: $provider"
    exit 1
  fi
  if [ "$tail_log" -eq 1 ]; then
    tail_service_background
  fi
}

stop_service() {
  local provider=$(get_running_provider)

  [ "$provider" = "" ] && { echo "No running provider"; return 1; }

  if [ "$provider" = "lms" ]; then
    lms_loaded_model | grep "$model_identifier" >/dev/null && eval $lms_cmd unload "$model_identifier"
    echo "$(status_service)"
    status_service >/dev/null && eval $lms_cmd server stop
  elif [ "$provider" = "ollama" ]; then
    if [ ! -f "$ollama_pid" ]; then
      echo "No PID file found; ollama does not appear to be running."
      stop_tail_pid
      return 1
    else
      local pid
      pid=$(<"$ollama_pid")
      rm -f "$ollama_pid"
      if ! is_pid_running "$pid"; then
        echo "No running process found for PID $pid."
        stop_tail_pid
        return 1
      else
        kill "$pid"
        echo "Stopped ollama (PID=$pid)."
      fi
    fi
    stop_tail_pid
  elif [ "$provider" = "mlx_serve" ]; then
    if [ ! -f "${mlx_serve_pid}" ]; then
      echo "No PID file found; mlx-serve does not appear to be running."
      stop_tail_pid
      return 1
    else
      local pid
      pid=$(<"${mlx_serve_pid}")
      rm -f "${mlx_serve_pid}"
      if ! is_pid_running "$pid"; then
        echo "No running process found for PID $pid."
        stop_tail_pid
        return 1
      else
        kill "$pid"
        echo "Stopped mlx-serve (PID=$pid)."
      fi
    fi
    stop_tail_pid
  else
    echo "Unknown provider: $provider"
    exit 1
  fi
}

status_service() {
  set +u
  local provider
  if [ "${1}" = "" ]; then
    provider=$(get_running_provider)
  else
    provider=${1}
  fi
  set -u
  [ "$provider" = "" ] && { echo "No running provider"; return 1; }

  if [ "$provider" = "lms" ]; then
    res=$(eval $lms_cmd server status 2>&1)
    echo "$res"
    lms_loaded_model

    if [[ "$res" == *"is running"* ]]; then
      return 0
    else
      return 1  
    fi
  elif [ "$provider" = "ollama" ]; then
    if [ -f "$ollama_pid" ]; then
      local pid
      pid=$(<"$ollama_pid")
      if is_pid_running "$pid"; then
        echo "Ollama is running (PID=$pid)."
        return 0
      fi
      echo "PID file exists but process $pid is not running."
      return 1
    fi
    echo "Ollama is not running."
    return 1
  elif [ "$provider" = "mlx_serve" ]; then
    if [ -f "$mlx_serve_pid" ]; then
      local pid
      pid=$(<"$mlx_serve_pid")
      if is_pid_running "$pid"; then
        echo "mlx-serve is running (PID=$pid)."
        return 0
      fi
      echo "PID file exists but process $pid is not running."
      return 1
    fi
    echo "mlx-serve is not running."
    return 1
  else
    echo "Unknown provider: $provider"
    exit 1
  fi
}

lms_loaded_model() {
  local res=$(eval $lms_cmd ps 2>&1)
  echo "$res"
}

is_pid_running() {
  local pid=$1
  kill -0 "$pid" >/dev/null 2>&1
}

get_running_provider() {
  local running_provider=""
  if [ -f "$mlx_serve_pid" ]; then
    running_provider="mlx_serve"
  elif [ -f "$ollama_pid" ]; then
    running_provider="ollama"
  elif status_service "lms" >/dev/null; then
    running_provider="lms"
  else
    :
  fi
  echo "$running_provider"
}

stop_tail_pid() {
  if [ -f "$tailpid_file" ]; then
    local tail_pid
    tail_pid=$(<"$tailpid_file")
    if is_pid_running "$tail_pid"; then
      kill "$tail_pid"
      echo "Stopped tailing log (PID=$tail_pid)."
    fi
    rm -f "$tailpid_file"
  fi
}

tail_service_background() {
  local provider=$(get_running_provider)
  [ "$provider" = "" ] && { echo "No running provider"; return 1; }
  
  if [ "$provider" = "lms" ]; then
    eval $lms_cmd log stream &
  elif [ "$provider" = "ollama" ]; then
    if [ ! -f "$ollama_log" ]; then
      echo "Log file does not exist yet: $ollama_log"
      return 1
    fi
    if [ -f "$tailpid_file" ]; then
      local existing_tail_pid
      existing_tail_pid=$(<"$tailpid_file")
      if is_pid_running "$existing_tail_pid"; then
        echo "Tail is already running in the background (PID=$existing_tail_pid)."
        return 0
      fi
      rm -f "$tailpid_file"
    fi

    tail -f "$ollama_log" &
    local tail_pid=$!
    echo "$tail_pid" > "$tailpid_file"
    echo "Tailing log in the background (PID=$tail_pid)."
    
  elif [ "$provider" = "mlx_serve" ]; then
    if [ ! -f "$mlx_serve_log" ]; then
      echo "Log file does not exist yet: $mlx_serve_log"
      return 1
    fi
    if [ -f "$tailpid_file" ]; then
      local existing_tail_pid
      existing_tail_pid=$(<"$tailpid_file")
      if is_pid_running "$existing_tail_pid"; then
        echo "Tail is already running in the background (PID=$existing_tail_pid)."
        return 0
      fi
      rm -f "$tailpid_file"
    fi

    tail -f "$mlx_serve_log" &
    local tail_pid=$!
    echo "$tail_pid" > "$tailpid_file"
    echo "Tailing log in the background (PID=$tail_pid)."

  else
    echo "Unknown provider: $provider"
    exit 1
  fi

  
}


command=${1:-start}
shift || true
case "$command" in
  start)   start_service "$@" ;;
  stop)    stop_service ;;
  status)  status_service ;;
  restart)
    stop_service
    start_service "$@"
    ;;
  tail)    tail_service_background ;;
  help|-h) usage ;;
  *)
    echo "Error: Command variants not found: $command"
    usage
    exit 1
    ;;
esac