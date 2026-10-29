#!/usr/bin/env bash
# Run a command inside the HDL tool container (Verilator 5, Icarus) with the
# repo mounted at /work.
#   scripts/docker_run.sh bash build/run_all.sh   (written by scripts/run_sims.py)
#   scripts/docker_run.sh verilator --version
set -euo pipefail
IMAGE="${HDL_IMAGE:-devtools:latest}"
cd "$(dirname "$0")/.."
exec docker run --rm --init --user "$(id -u):$(id -g)" -v "$PWD":/work -w /work "$IMAGE" "$@"
