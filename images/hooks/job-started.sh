#!/bin/bash
# ACTIONS_RUNNER_HOOK_JOB_STARTED hook — runs before every job on this runner.
# Wipes the *contents* of per-repo workdirs under _work to defeat actions/checkout
# reused-workdir corruption left over from a SIGTERMed prior job (cancel-in-progress
# race). Preserves the directory entries themselves because the runner agent sets
# every subsequent step's cwd to /opt/actions-runner/_work/<repo>/<repo> BEFORE
# actions/checkout recreates it — removing the dir makes Process.Start fail with
# ENOENT on every job.
#
# Always runs; no opt-out by design.
#
# See docs/superpowers/specs/2026-05-25-job-started-hook-design.md
set -euo pipefail

work_root="/opt/actions-runner/_work"

# Defensive guards: bail rather than wiping the wrong place.
[[ -d "$work_root" ]] || exit 0
[[ "$work_root" == "/opt/actions-runner/_work" ]] || exit 0

# _work layout:
#   _work/<repo>/           per-repo container (managed by runner agent)
#   _work/<repo>/<repo>/    actual git workdir == GITHUB_WORKSPACE
#   _work/_actions/         cached action downloads  (preserve, cache)
#   _work/_temp/            per-job scratch          (preserve, runner-managed)
#   _work/_tool/            tool cache               (preserve, cache)
#   _work/_PipelineMapping/ runner internal          (preserve, runner-managed)
#
# We empty the inner workdir but leave the directory entry intact. This:
#  - removes the corrupted .git/index from the cancellation race
#  - forces actions/checkout to take its full-clone path
#  - keeps the cwd path valid so Process.Start doesn't ENOENT
shopt -s nullglob dotglob
wiped=0
for outer in "$work_root"/*/; do
  base=$(basename "$outer")
  case "$base" in
    _actions|_temp|_tool|_PipelineMapping) continue ;;
  esac
  for inner in "${outer%/}"/*/; do
    [[ -d "$inner" && ! -L "${inner%/}" ]] || continue
    find "${inner%/}" -mindepth 1 -delete
    wiped=$((wiped + 1))
  done
done
echo "[job-started-hook] emptied $wiped workdir(s) under $work_root"
