# Local AI

## Introduction

This repository contains a setup to run AI locally.

It is geared towards MacOS, but most parts should be reusable on other operating system.

The basis ideas of the code are:
1. Agents should run unsupervised (not continously asking for permissions to perform actions), but to limit the risks they should run in a sandbox
2. An agent is the combination of an agentic interface (such as Claude CLI, Opencode CLI) talking to a LLM. Given the agent performs the actions, it needs to run in the sandbox. The LLM can run where the OS can provide better performances (normally outside of the container).

Given this premise, the code in this repository runs the agent in a Docker environment, and points it to talk to an LLM that runs on the Mac (where the GPU can be used by the model).

There are two Docker enviromnent (two Docker files) in this repo, one for Python development and one for Go development.

There are two providers that can be used by the scripts (which need to be installed separately):
1. [Ollama](https://ollama.com/)
2. [LMStudio](https://lmstudio.ai/)

Both should run on Mac/Linux and Windows. Machine learning for the Mac usually lags behind but these providers also support MLX (Metal framework) so that should improve the performances when using a model in MLX format.

The supported agents in the container are (installation links in the container file):
1. Claude CLI
2. Opencode
3. Some skeleton code for Copilot and Codex, but not tested

# The files

- `PythonDockerfile` is the Docker file for Python development
- `GoDockerfile` is the Docker file for Go development
- `startDocker.sh` launches the container and sets up the selected agent to talk to the selected provider
- `comm_fun.sh` utility function to start DOcker
- `ollama_launcher.sh` is the launcher for local Ollama
- `lmstudio_launcher.sh` is the launcher for LMStudio

# Set Up

Both Ollama and LMStudio (the latter with a GUI) allow you to download models you want to use for your coding. You need to do this before you launch the agent as otherwise there is no LLM for the agent to talk to.

# How to run `startDocker.sh`

The launcher script expects at least:
- a language (`python` or `go`)
- a provider (`ollama`, `wrapped_ollama`, `lms`, or `wrapped_lms`)

General command:

```bash
./startDocker.sh -l <python|go> -a <claude|opencode> -p <provider> -m <model>
```

Useful options:
- `-a`: agent (`claude` by default)
- `-l`: language/environment (`python` or `go`)
- `-p`: provider mode (`ollama`, `wrapped_ollama`, `lms`, `wrapped_lms`)
- `-m`: model name (default is `qwen3-coder-next:latest`)
- `-d`: extra directory to mount read-only in the container (can be repeated)
- `-r`: resume checkpoint/session id for supported agents
- `-h`: help

Examples:

```bash
# Python + Claude + wrapped Ollama
./startDocker.sh -l python -a claude -p wrapped_ollama -m qwen3-coder-next:latest

# Go + Opencode + LM Studio
./startDocker.sh -l go -a opencode -p lms -m qwen3-coder-next:latest

# Add an extra read-only mount
./startDocker.sh -l python -a claude -p wrapped_ollama -d /Users/youruser/SomeProject
```

Notes:
- The script auto-selects `PythonDockerfile` for `-l python` and `GoDockerfile` for `-l go`.
- If you use `claude`, the script currently applies `--bare`, `--strict-mcp-config`, and `--dangerously-skip-permissions`.
- `copilot` and `codex` are installed in images but are not enabled in this launcher flow yet.

# How to run `ollama_launcher.sh`

General commands:

```bash
./ollama_launcher.sh start [-c <context_length>] [-k <16|8|4>] [-t]
./ollama_launcher.sh stop
./ollama_launcher.sh status
./ollama_launcher.sh restart
./ollama_launcher.sh tail
```

Examples:

```bash
# Start with defaults
./ollama_launcher.sh start

# Start with longer context and q8 KV cache
./ollama_launcher.sh start -c 48128 -k 8

# Check status
./ollama_launcher.sh status
```

# How to run `lmstudio_launcher.sh`

General commands:

```bash
./lmstudio_launcher.sh start [-c <context_length>] [-m <org/model>] [-t]
./lmstudio_launcher.sh stop
./lmstudio_launcher.sh status
./lmstudio_launcher.sh loaded
./lmstudio_launcher.sh restart
./lmstudio_launcher.sh tail
```

Examples:

```bash
# Start with defaults
./lmstudio_launcher.sh start

# Start specific model and context length
./lmstudio_launcher.sh start -m qwen/qwen3-coder-next -c 32768

# Show loaded models
./lmstudio_launcher.sh loaded
```


# Memory limitations

I am using models from the Qwnen family as they are considered to be good for coding. For your case, you need to see how much RAM your machine has, as I have 64GB unified memory and that is barely enough (or not enough) for some use cases (more later).

So have a look at how many parameters the model has, that gives you an indication about how much memory it will require.

Other factor that play a role in the memory consumption are:
- the quantisation level (guidelines seem to advice not to go under `q8_0`). Unfortunately the Mac lags behind when supporting new quantisation schemas
- the context length. This is very important and it determines how long the prompt that is sent to the LLM can be. The prompt is not only your question unfortunately, but also instructions for the agent (Claude is very verbose, that is why you will see the flag --bare in the script) and the past history of the conversation.

Gemma 4 could be a (worse) alternative to Qwen in case of limited RAM.

# Warnings

Local AI seems not to be that mature yet, as there are still quite some problems.

I will list here the ones that I have found, using some technical terms that you might look up if interested:
1. Ollama lags behind in supporting (at least for Metal/MLX) new models that use a different architecture, for example my current choice `qwen3-coder-next`. This is a Mixture of Experts (MoE) model, and Ollama does not get the KV-cache right, so it start reprocessing the prompt continuosly (printing the link to the relevant github issue) and the agent times out.
2. Ollama as a client can be used inside the container (I call this `wrapped_ollama` in the script) because some agents like Claude do not use the OpenAI way of communicating and need to have a translation layer before talking to the provider. Opencode seems not to need this, and Claude with the `--bare` options also not, but I am not 100% sure.
3. LMStudio loads `qwen3-coder-next` also with a context length greater than 32768, but then either the model gets unloaded (best case) or the Mac reboots (not so best case)
