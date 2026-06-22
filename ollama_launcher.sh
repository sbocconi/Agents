#!/bin/bash
set -euo pipefail

OLLAMA_HOST=127.0.0.1:11434
OLLAMA_DIR=~/.ollama
PIDFILE="$OLLAMA_DIR/ollama.pid"
LOGFILE="$OLLAMA_DIR/logs/server.log"
TAILFILE="$OLLAMA_DIR/ollama_tail.pid"

# Establish robust defaults for long-context agent sandboxes
# MEMORY LIMITS
# sudo sysctl iogpu.wired_mem_breakpoint_cap=57344
# 57344 translates to exactly 56 GB in Megabytes, leaving 8 GB for system tasks.
lms_context_length=48128  # 262144 65536 48128 32768 16384 8192

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
  -c VALUE   Set OLLAMA_CONTEXT_LENGTH (e.g. 131072 for long-context agents. Default: 8192)
  -f         Set OLLAMA_FLASH_ATTENTION=1 (Enables Flash Attention, required for quantized KV cache)
  -k VALUE   Set OLLAMA_KV_CACHE_TYPE (Reduces VRAM constraints at massive contexts)
              16   - high precision (f16, default).
              8    - 8-bit quantization (q8_0, cuts memory usage by half, recommended).
              4    - 4-bit quantization (q4_0, cuts memory usage by 75%).
  -t         Start tailing the log in the background immediately after boot
  -h         Show start help
EOF
}

is_running() {
  local pid=$1
  kill -0 "$pid" >/dev/null 2>&1
}

start_service() {
  local OLLAMA_CONTEXT_LENGTH="$lms_context_length"
  local OLLAMA_FLASH_ATTENTION="1" # Explicitly defaulted to 1 to enable quantized KV caches
  local OLLAMA_KV_CACHE_TYPE="q8_0" # Safest, highly-performant VRAM saving default
  local OLLAMA_KEEP_ALIVE="10m"     # Prevent model unloading/re-allocations during slow generations
  local TAIL_LOG=1

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
  while getopts "c:fk:th" opt; do
    case $opt in
      c)
        OLLAMA_CONTEXT_LENGTH=$OPTARG
        ;;
      f)
        OLLAMA_FLASH_ATTENTION="1"
        ;;
      k)
        case $OPTARG in
          16) OLLAMA_KV_CACHE_TYPE="f16" ;;
          8)  OLLAMA_KV_CACHE_TYPE="q8_0" ;;
          4)  OLLAMA_KV_CACHE_TYPE="q4_0" ;;
          *)
            echo "Invalid value for -k: $OPTARG. Choose 16, 8, or 4."
            exit 1
            ;;
        esac
        ;;
      t)
        TAIL_LOG=1
        ;;
      h)
        usage
        exit 0
        ;;
      *)
        echo "Invalid start option: -$opt. Use '$0 help'."
        exit 1
        ;;
    esac
  done
  shift $((OPTIND - 1))

  # Export variables to environment for Ollama binary consumption
  export OLLAMA_CONTEXT_LENGTH
  export OLLAMA_FLASH_ATTENTION
  export OLLAMA_KV_CACHE_TYPE
  export OLLAMA_KEEP_ALIVE
  export OLLAMA_HOST

  echo "====================================================="
  echo "Launching Ollama Server with optimized variables:"
  echo "  - OLLAMA_CONTEXT_LENGTH   = $OLLAMA_CONTEXT_LENGTH"
  echo "  - OLLAMA_FLASH_ATTENTION  = $OLLAMA_FLASH_ATTENTION"
  echo "  - OLLAMA_KV_CACHE_TYPE    = $OLLAMA_KV_CACHE_TYPE"
  echo "  - OLLAMA_KEEP_ALIVE       = $OLLAMA_KEEP_ALIVE"
  echo "  - OLLAMA_HOST             = $OLLAMA_HOST"
  echo "====================================================="
  echo "Server logs redirecting to: $LOGFILE"
  echo ""

  ollama serve >>"$LOGFILE" 2>&1 &
  local pid=$!
  echo "$pid" > "$PIDFILE"
  echo "Ollama serve running in background (PID=$pid)."
  
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
  start)   start_service "$@" ;;
  stop)    stop_service "need to be running" ;;
  status)  status_service ;;
  restart)
    stop_service "can be ignored if not running"
    start_service "$@"
    ;;
  tail)    tail_service ;;
  help|-h) usage ;;
  *)
    echo "Error: Command variants not found: $command"
    usage
    exit 1
    ;;
esac