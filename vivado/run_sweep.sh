#!/usr/bin/env bash
# run_sweep.sh - launch the generated Vivado builds in parallel batch jobs and
# merge the per-build summary rows.
#   python scripts/gen_configs.py && vivado/run_sweep.sh 4
# NOT RUN HERE (Vivado unavailable).
set -euo pipefail
JOBS=${1:-2}
cd "$(dirname "$0")/.."
mkdir -p vivado_runs
xargs -P "$JOBS" -I{} sh -c \
  'vivado -mode batch -nojournal -log vivado_runs/{}.log -source vivado/build.tcl -tclargs build/configs/{}.tcl > /dev/null || echo "FAILED {}"' \
  < build/configs/sweep.txt
head -n1 "$(ls vivado_runs/*/summary.csv | head -n1)" > vivado_runs/sweep_summary.csv
for f in vivado_runs/*/summary.csv; do tail -n +2 "$f"; done >> vivado_runs/sweep_summary.csv
echo "merged $(($(wc -l < vivado_runs/sweep_summary.csv) - 1)) summaries into vivado_runs/sweep_summary.csv"
