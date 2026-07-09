#!/bin/bash
set -euo pipefail

lms_cmd='"/Applications/LM Studio.app/Contents/Resources/app/.webpack/lms"'
lms_port=1234
# 1024=1K 262144=256K, 65536=64K, 48128=47K, 32768=32K, 16384=16K, 8192=8K
lms_def_context_length=$((24 * 1024))
model_identifier="qwen3-coder-next"
model="qwen/$model_identifier"

usage() {
  cat <<EOF
Usage: $0 <command> [options]
Commands:
  start      Start lms serve in the background
  stop       Stop the running lms serve process
  status     Show whether lms serve is running
  tail       Show live log output from lms server
  help       Show this help

Options for start:
  -c VALUE   Set lms_context_length (e.g. 131072 for long-context agents. Default: $lms_def_context_length)
  -m VALUE   Set model (e.g. qwen/qwen3-coder-next. Default: $model)
  -t         Start tailing the log in the background immediately after boot
  -h         Show start help
EOF
}

start_service() {
  # Establish robust defaults for long-context agent sandboxes
  # MEMORY LIMITS
  # sudo sysctl iogpu.wired_mem_breakpoint_cap=57344
  # 57344 translates to exactly 56 GB in Megabytes, leaving 8 GB for system tasks.
  local lms_context_length="$lms_def_context_length"
  local TAIL_LOG=0

  OPTIND=1
  while getopts "c:hm:t" opt; do
    case $opt in
      c)
        lms_context_length=$OPTARG
        ;;
      h)
        usage
        exit 0
        ;;
      m)
        IFS="/" read -r first second <<< "$OPTARG"
        model="$first/$second"
        model_identifier="$second"
        ;;
      t)
        TAIL_LOG=1
        ;;
      *)
        echo "Invalid start option: -$opt. Use '$0 help'."
        exit 1
        ;;
    esac
  done
  shift $((OPTIND - 1))

  # Export variables to environment for lms binary consumption

  echo "====================================================="
  echo "Launching lms Server with optimized variables:"
  echo "  - lms_context_length   = $lms_context_length"
  echo "  - lms_port             = $lms_port"
  echo "====================================================="
  echo ""

  status_service || eval $lms_cmd server start --bind 0.0.0.0 --port $lms_port
  loaded_model | grep "$model_identifier" >/dev/null || eval $lms_cmd load ${model} --context-length $lms_context_length --identifier "$model_identifier"

   # Wait for server to start
  
  if [ "$TAIL_LOG" -eq 1 ]; then
    tail_service_background
  fi
}

stop_service() {
  loaded_model | grep "$model_identifier" >/dev/null && eval $lms_cmd unload "$model_identifier"
  status_service >/dev/null && eval $lms_cmd server stop
}

status_service() {
  res=$(eval $lms_cmd server status 2>&1)
  echo "$res"
  if [[ "$res" == *"is running"* ]]; then
    return 0
  else
    return 1  
  fi
}

loaded_model() {
  res=$(eval $lms_cmd ps 2>&1)
  echo "$res"
}
tail_service_background() {
  eval $lms_cmd log stream &
}

tail_service() {
  eval $lms_cmd log stream
}

command=${1:-start}
shift || true
case "$command" in
  loaded)   loaded_model ;;
  start)   start_service "$@" ;;
  stop)    stop_service ;;
  status)  status_service ;;
  restart)
    stop_service 
    start_service
    ;;
  tail)    tail_service_background ;;
  help|-h) usage ;;
  *)
    echo "Error: Command variants not found: $command"
    usage
    exit 1
    ;;
esac