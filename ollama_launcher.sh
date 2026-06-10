#!/bin/bash
set -euo pipefail

OLLAMA_HOST=127.0.0.1:11434
OLLAMA_DIR=~/.ollama
PIDFILE="$OLLAMA_DIR/ollama.pid"
LOGFILE="$OLLAMA_DIR/logs/server.log"
TAILFILE="$OLLAMA_DIR/ollama_tail.pid"

usage() {
  cat <<EOF
Usage: $0 <command> [options]
Commands:
  start      Start ollama serve in the background
  stop       Stop the running ollama serve process
  status     Show whether ollama serve is running
  tail       Show live log output from ollama serve
  help       Show this help

Options for start:
  -c VALUE   Set OLLAMA_CONTEXT_LENGTH
              The context length to use for the server (e.g. 8192).
  -f         Set OLLAMA_FLASH_ATTENTION
  -k VALUE   Set OLLAMA_KV_CACHE_TYPE
              f16 - high precision and memory usage (default).
              q8_0 - 8-bit quantization, uses approximately 1/2 the memory of f16 with a very small loss in precision, this usually has no noticeable impact on the model’s quality (recommended if not using f16).
              q4_0 - 4-bit quantization, uses approximately 1/4 the memory of f16 with a small-medium loss in precision that may be more noticeable at higher context sizes.
  -a         Set AGX_RELAX_CDM_CTXSTORE_TIMEOUT
  -t         Start tailing the log in the background after start
  -h         Show start help
EOF
}

is_running() {
  local pid=$1
  kill -0 "$pid" >/dev/null 2>&1
}

start_service() {
  local OLLAMA_FLASH_ATTENTION=""
  local OLLAMA_KV_CACHE_TYPE=""
  local AGX_RELAX_CDM_CTXSTORE_TIMEOUT=""
  local TAIL_LOG=0

  if [ -f "$PIDFILE" ]; then
    local existing_pid
    existing_pid=$(<"$PIDFILE")
    if is_running "$existing_pid"; then
      echo "Ollama serve is already running (PID=$existing_pid)."
      exit 1
    fi
    rm -f "$PIDFILE"
  fi

  OPTIND=1
  while getopts "c:fk:ath" opt; do
    case $opt in
      c)
        OLLAMA_CONTEXT_LENGTH=$OPTARG
        ;;
      f)
        OLLAMA_FLASH_ATTENTION=1
        ;;
      k)
        case $OPTARG in
          16)
            OLLAMA_KV_CACHE_TYPE="f16"
            ;;
          8)
            OLLAMA_KV_CACHE_TYPE="q8_0"
            ;;
          4)
            OLLAMA_KV_CACHE_TYPE="q4_0"
            ;;
          *)
            echo "Invalid value for -k: $OPTARG"
            echo "Valid values are: 16, 8, 4"
            exit 1
            ;;
        esac
        ;;
      a)
        AGX_RELAX_CDM_CTXSTORE_TIMEOUT=1
        ;;
      t)
        TAIL_LOG=1
        ;;
      h)
        usage
        exit 0
        ;;
      *)
        echo "Invalid start option: -$opt"
        echo "Use '$0 help' for usage."
        exit 1
        ;;
    esac
  done
  shift $((OPTIND - 1))

  [ -n "$OLLAMA_FLASH_ATTENTION" ] && export OLLAMA_FLASH_ATTENTION
  [ -n "$OLLAMA_KV_CACHE_TYPE" ] && export OLLAMA_KV_CACHE_TYPE
  [ -n "$AGX_RELAX_CDM_CTXSTORE_TIMEOUT" ] && export AGX_RELAX_CDM_CTXSTORE_TIMEOUT
  [ -n "$OLLAMA_HOST" ] && export OLLAMA_HOST

  echo "Starting Ollama serve with the following settings:"
  [ -n "$OLLAMA_FLASH_ATTENTION" ] && echo "OLLAMA_FLASH_ATTENTION=$OLLAMA_FLASH_ATTENTION"
  [ -n "$OLLAMA_KV_CACHE_TYPE" ] && echo "OLLAMA_KV_CACHE_TYPE=$OLLAMA_KV_CACHE_TYPE"
  [ -n "$AGX_RELAX_CDM_CTXSTORE_TIMEOUT" ] && echo "AGX_RELAX_CDM_CTXSTORE_TIMEOUT=$AGX_RELAX_CDM_CTXSTORE_TIMEOUT"
  [ -n "$OLLAMA_HOST" ] && echo "OLLAMA_HOST=$OLLAMA_HOST"
  if [ -z "$OLLAMA_FLASH_ATTENTION" ] && [ -z "$OLLAMA_KV_CACHE_TYPE" ] && [ -z "$AGX_RELAX_CDM_CTXSTORE_TIMEOUT" ] && [ -z "$OLLAMA_HOST" ]; then
    echo "No optimization variables set."
  fi
  echo "Output will also be saved to $LOGFILE"
  echo ""

  nohup ollama serve >>"$LOGFILE" 2>&1 &
  local pid=$!
  echo "$pid" > "$PIDFILE"
  echo "Ollama serve started in the background (PID=$pid)."
  
  if [ "$TAIL_LOG" -eq 1 ]; then
    tail_service_background
  fi
}

stop_tail() {
  if [ -f "$TAILFILE" ]; then
    local tail_pid
    tail_pid=$(<"$TAILFILE")
    if is_running "$tail_pid"; then
      kill "$tail_pid"
      echo "Stopped tailing log (PID=$tail_pid)."
    fi
    rm -f "$TAILFILE"
  fi
}

stop_service() {
  local ignore_if_not_running=$1
  if [ ! -f "$PIDFILE" ]; then
    echo "No PID file found; ollama serve does not appear to be running."
    stop_tail
    [ "$ignore_if_not_running" = "can be ignored if not running" ] || exit 1
  else

    local pid
    pid=$(<"$PIDFILE")
    rm -f "$PIDFILE"
    if ! is_running "$pid"; then
      echo "No running process found for PID $pid. Removing stale PID file."
      stop_tail
      [ "$ignore_if_not_running" = "can be ignored if not running" ] || exit 1
    else
      kill "$pid"
      echo "Stopped ollama serve (PID=$pid)."
    fi
  fi
  stop_tail
}

status_service() {
  if [ -f "$PIDFILE" ]; then
    local pid
    pid=$(<"$PIDFILE")
    if is_running "$pid"; then
      echo "Ollama serve is running (PID=$pid)."
      exit 0
    fi
    echo "PID file exists but process $pid is not running."
    exit 1
  fi
  echo "Ollama serve is not running."
  exit 1
}

tail_service_background() {
  if [ ! -f "$LOGFILE" ]; then
    echo "Log file does not exist yet: $LOGFILE"
    return 1
  fi

  if [ -f "$TAILFILE" ]; then
    local existing_tail_pid
    existing_tail_pid=$(<"$TAILFILE")
    if is_running "$existing_tail_pid"; then
      echo "Tail is already running in the background (PID=$existing_tail_pid)."
      return 0
    fi
    rm -f "$TAILFILE"
  fi

  tail -f "$LOGFILE" &
  local tail_pid=$!
  echo "$tail_pid" > "$TAILFILE"
  echo "Tailing log in the background (PID=$tail_pid)."
}

tail_service() {
  if [ ! -f "$LOGFILE" ]; then
    echo "Log file does not exist: $LOGFILE"
    exit 1
  fi
  tail -f "$LOGFILE"
}

command=${1:-start}
shift || true
case "$command" in
  start)
    start_service "$@"
    ;;
  stop)
    stop_service "need to be running"
    ;;
  status)
    status_service
    ;;
  restart)
    stop_service "can be ignored if not running"
    start_service "$@"
    ;;
  tail)
    tail_service
    ;;
  help|-h)
    usage
    ;;
  *)
    echo "Unknown command: $command"
    usage
    exit 1
    ;;
esac