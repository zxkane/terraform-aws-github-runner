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
#   _work/_actions/         cached action downloads  (runner internal)
#   _work/_temp/            per-job scratch          (runner internal)
#   _work/_tool/            tool cache               (runner internal)
#   _work/_PipelineMapping/ runner internal
#   _work/_update/          runner self-update staging (runner internal)
#   _work/_diag/ etc.       other runner internals
#
# Skip every `_`-prefixed entry: the runner agent prefixes ALL of its own
# `_work` helper dirs with `_` precisely so they never collide with per-repo
# workdirs (a repo workdir is named after the repo and never starts with `_`).
# Enumerating a fixed list missed `_update`, whose self-update residue
# (externals/node20/...) can't always be unlinked by `ubuntu`; the resulting
# `find -delete` failure used to abort the hook and fail the whole job.
#
# We empty the inner workdir but leave the directory entry intact. This:
#  - removes the corrupted .git/index from the cancellation race
#  - forces actions/checkout to take its full-clone path
#  - keeps the cwd path valid so Process.Start doesn't ENOENT
shopt -s nullglob dotglob
wiped=0
for outer in "$work_root"/*/; do
  base=$(basename "$outer")
  # Skip runner-internal dirs (all `_`-prefixed). Never a repo workdir.
  [[ "$base" == _* ]] && continue
  for inner in "${outer%/}"/*/; do
    [[ -d "$inner" && ! -L "${inner%/}" ]] || continue
    # Best-effort wipe. Housekeeping must NEVER fail the job: if an entry can't
    # be unlinked (e.g. a root-owned file left by a Docker step), log and move
    # on rather than letting `set -e` abort the hook. The next actions/checkout
    # still re-clones into whatever remains.
    if find "${inner%/}" -mindepth 1 -delete 2>/dev/null; then
      wiped=$((wiped + 1))
    else
      echo "[job-started-hook] warning: could not fully empty ${inner%/} (continuing)" >&2
    fi
  done
done
echo "[job-started-hook] emptied $wiped workdir(s) under $work_root"
