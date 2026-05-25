# Job-started hook to wipe `_work` between jobs

**Status:** Approved
**Date:** 2026-05-25
**Scope:** `images/ubuntu-noble-arm64/`, `images/ubuntu-noble/`, `CLAUDE.md`

## Problem

Persistent self-hosted runners on the shared pool can serve a job whose workdir has been corrupted by a SIGTERMed prior job. The corruption sequence:

1. A workflow with `concurrency.cancel-in-progress: true` is canceled mid-`actions/checkout` because a newer commit lands.
2. The cancel path skips `Post Checkout` cleanup. The previous job's `_work/<repo>/<repo>/` is left in a state where `.git/index` is internally consistent with an empty working tree (or the working tree is empty but `.git/index` was not rolled back).
3. The next job lands on the same persistent runner. `actions/checkout@v4` enters its reused-workdir branch:
   - `git clean -ffdx` — no-op against an empty tree
   - `git reset --hard HEAD` — index already "matches" the empty tree, no-op
   - `git checkout --force -B <branch> refs/remotes/origin/<branch>` — git thinks workdir matches index, does NOT re-write files
4. The action returns success. The first step that actually reads the workdir (e.g. `npm ci`) fails with `ENOENT: package.json`.

Observed in production on 2026-05-24 across two runner instances (`i-03de02c8035f5f3cf`, `i-0641b517c85d3aec3`) servicing a consumer repo's PR with three rapid pushes. Workflow diagnostic block confirmed `git ls-tree HEAD` listed the files but `ls package*.json` reported missing files. Short jobs that complete before reading the workdir succeed silently against an empty checkout — a more dangerous failure mode than a hard `ENOENT`.

## Approach

Bake an `ACTIONS_RUNNER_HOOK_JOB_STARTED` hook into both AMIs (arm64, amd64) that wipes per-repo subdirs under `/opt/actions-runner/_work` before every job. This forces `actions/checkout` to take its full-clone path on every job, sidestepping the reused-workdir corruption window entirely.

No Terraform changes, no SSM config, no per-repo workflow changes. Hook ships in the AMI; rollout follows the existing AMI rollout procedure.

## Design

### Hook script

New file `images/hooks/job-started.sh`, baked at `/opt/actions-runner/hooks/job-started.sh` on both AMIs. Owned by `ubuntu`, mode `0755`.

```bash
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
```

Design notes baked into the script:

- **Empty contents, preserve directory entry.** The runner agent sets every subsequent step's cwd to `_work/<repo>/<repo>/` before `actions/checkout` runs. Removing the directory makes the next step's `Process.Start` fail with ENOENT on every job (regression observed in production on the v1 hook on 2026-05-25; rolled back same day). `find -mindepth 1 -delete` empties the dir while keeping the dir entry valid as a cwd target.
- **Skip-list at the outer level.** `_actions` / `_temp` / `_tool` / `_PipelineMapping` are the runner agent's own helper dirs at the `_work` root, not per-repo workdirs. Preserving them keeps action download cache hits and avoids fighting the runner-managed temp lifecycles.
- **`! -L "${inner%/}"` symlink guard.** Defensive — if a future runner layout ever placed a symlink at the workdir position, the hook skips it rather than `find … -delete`-ing into the symlink's target.
- **`set -euo pipefail`.** If the wipe fails, fail the job loudly; a poisoned-workdir job is worse than a fail-fast.
- **Exact-path match on `work_root`.** A future runner layout change with a different `_work` location degrades to a no-op rather than nuking an unrelated tree.
- **`nullglob dotglob`.** Empty `_work` (first job on a fresh runner) and outer-dir-without-inner-workdir-yet are normal states and must not error.

### Packer wiring

Both `images/ubuntu-noble-arm64/github_agent.ubuntu.pkr.hcl` and `images/ubuntu-noble/github_agent.ubuntu.pkr.hcl` get two new provisioner blocks inside the existing `build` block, inserted immediately AFTER the post-runner-install `provisioner "shell"` block (the one that already writes `ImageOS=ubuntu24` to `.env`) and BEFORE the `provisioner "file"` that uploads `start-runner.sh`:

1. A new `provisioner "file"` that uploads `images/hooks/job-started.sh` to `/tmp/job-started.sh`. The source path is relative to the Packer working directory (`images/ubuntu-noble-arm64/` or `images/ubuntu-noble/`), so the literal path is `../hooks/job-started.sh` — same relative-path style as the existing `../install-runner.sh` reference.
2. A new `provisioner "shell"` that installs the hook into the AMI:
   - `sudo mkdir -p /opt/actions-runner/hooks`
   - `sudo mv /tmp/job-started.sh /opt/actions-runner/hooks/job-started.sh`
   - `sudo chown ubuntu:ubuntu /opt/actions-runner/hooks/job-started.sh`
   - `sudo chmod 0755 /opt/actions-runner/hooks/job-started.sh`
   - `echo ACTIONS_RUNNER_HOOK_JOB_STARTED=/opt/actions-runner/hooks/job-started.sh | sudo tee -a /opt/actions-runner/.env`

The `.env` line lives next to the existing `ImageOS=ubuntu24` line; the runner agent reads `.env` at service start and exports each `KEY=VALUE` into the job process environment.

### Documentation

Extend `CLAUDE.md` "AMI Build" section with a new subsection "Workspace hygiene hook" that captures:

- What the hook does and which file ships it.
- The cancel-in-progress race it fixes (one-paragraph summary, not a full re-derivation).
- The explicit no-opt-out decision and why (a future operator who finds the hook "slowing things down" needs to read this before stripping it).
- A pointer to this spec for the full background.

## Data flow

```
Job dispatched to runner
  → runner agent reads /opt/actions-runner/.env at service start
  → ACTIONS_RUNNER_HOOK_JOB_STARTED is in the job process env
  → before the job runs, runner exec's job-started.sh
  → hook empties the contents of every _work/<repo>/<repo>/ workdir
    (directory entries themselves preserved → cwd remains valid)
  → runner agent sets cwd=_work/<repo>/<repo>/ for actions/checkout step
  → checkout sees an empty (but extant) workdir → full-clone path
  → workdir is repopulated; job continues
```

## Testing

1. Build both AMIs:
   ```bash
   cd deployments/shared-runners
   ARCH=arm64 ./scripts/02-build-ami.sh
   ARCH=amd64 ./scripts/02-build-ami.sh
   ```
2. Roll out via the documented AMI rollout procedure (`terraform plan` → expect `Plan: 0 to add, 2 to change, 0 to destroy.` for the SSM params; `terraform apply tfplan`).
3. Verify SSM params point at new AMIs:
   ```bash
   aws ssm get-parameters --names \
     /github-action-runners/gh-runner/linux-arm64/runners/config/ami_id \
     /github-action-runners/gh-runner/linux-amd64/runners/config/ami_id
   ```
4. Force at least one runner per fleet onto the new AMI by terminating an idle (`busy=false`) instance. Don't terminate `busy=true` runners.
5. **No-regression check first.** Watch any consumer-repo workflow that's already running on the pool. The first job that lands on a new-AMI runner must succeed end-to-end. Specifically the `actions/checkout` step must not fail with `An error occurred trying to start process '... node ...' with working directory '...'. No such file or directory` — that's the regression mode the v1 hook hit on 2026-05-25. The new-AMI runner's job log should also include `[job-started-hook] emptied N workdir(s) under /opt/actions-runner/_work` near the top (in the "A job started hook has been configured" group), confirming the hook fired.
6. **Reproduce the original cancel-in-progress regression.** On a repo that's known to have the bug (workflow with `concurrency.cancel-in-progress: true`, push 3 commits in rapid succession). Pre-fix behavior: jobs after the cancellation fail with `ENOENT: package.json` because the workdir is in the corrupted-empty state. Post-fix behavior: all three pushes' jobs succeed. The hook output appears in every job log.
7. **Single-push case** (no cancellation): still succeeds and isn't measurably slower than baseline (re-cloning a small repo is sub-second).

## Trade-offs and non-goals

- **Cross-job per-repo cache is lost.** Every job re-clones the repo. For the consumer workflows on this pool (small/medium repos, `actions/checkout` defaults to shallow), the overhead is a few seconds; acceptable price for correctness. Action download cache (`_actions/`) and tool cache (`_tool/`) are preserved.
- **Stray processes from a canceled job are not cleaned up.** If a SIGTERMed `node` / `docker` left a runaway child process, this hook doesn't kill it. Out of scope — that is a separate class of bug, and ephemeral instance recycle handles it at a coarser grain.
- **The upstream `actions/checkout` reused-workdir bug is not fixed.** Filing an upstream issue is independent and out of scope here.
- **No opt-out.** Considered and rejected: the most likely future "I want to opt out for caching" case is exactly the case where the bug bites (long-lived persistent runner, multiple jobs per session). An env-var or label opt-out adds a foot-gun for marginal benefit.
