# Job-started Hook Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bake an `ACTIONS_RUNNER_HOOK_JOB_STARTED` hook into both shared-runner AMIs that wipes per-repo subdirs under `/opt/actions-runner/_work` before every job, defeating the `actions/checkout` reused-workdir corruption left by SIGTERMed cancel-in-progress jobs.

**Architecture:** New shell script `images/hooks/job-started.sh` is uploaded by Packer into both AMIs at `/opt/actions-runner/hooks/job-started.sh`. The Packer build appends `ACTIONS_RUNNER_HOOK_JOB_STARTED=...` to `/opt/actions-runner/.env` next to the existing `ImageOS=ubuntu24` line. No Terraform / SSM / workflow changes — rollout follows the existing AMI rollout procedure documented in CLAUDE.md.

**Tech Stack:** Bash, Packer (HCL2), Ubuntu 24.04 Pro AMIs (arm64 + amd64).

**Spec:** `docs/superpowers/specs/2026-05-25-job-started-hook-design.md`

---

## File Structure

| File | Disposition | Responsibility |
|------|-------------|----------------|
| `images/hooks/job-started.sh` | Create | The hook itself. Wipes per-repo subdirs under `/opt/actions-runner/_work`, preserves runner helper dirs (`_actions`, `_temp`, `_tool`, `_PipelineMapping`). |
| `images/ubuntu-noble-arm64/github_agent.ubuntu.pkr.hcl` | Modify | Add a `provisioner "file"` for the hook + extend an existing `provisioner "shell"` to install the hook and append the env var to `.env`. |
| `images/ubuntu-noble/github_agent.ubuntu.pkr.hcl` | Modify | Same change as the arm64 template. |
| `CLAUDE.md` | Modify | Add a "Workspace hygiene hook" subsection under "AMI Build" documenting the hook and the no-opt-out decision. |

No tests are added for the hook script. Hooks of this shape (~20 lines, no inputs other than the runner's directory layout) are validated end-to-end by reproducing the regression on a real runner; a unit harness would be more code than the hook and would mock out exactly what we care about (the on-disk `_work` layout). The `Testing` section below is the validation procedure — it lives in this plan rather than the codebase.

---

## Task 1: Create the hook script

**Files:**
- Create: `images/hooks/job-started.sh`

- [x] **Step 1: Create the directory and write the hook**

Create `images/hooks/job-started.sh` with exactly this content:

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

- [x] **Step 2: Make it executable**

Run: `chmod 0755 images/hooks/job-started.sh`

- [x] **Step 3: Sanity-syntax-check the script locally**

Run: `bash -n images/hooks/job-started.sh`
Expected: no output, exit code 0.

If `shellcheck` is available locally, also run: `shellcheck images/hooks/job-started.sh`
Expected: no warnings. (It's fine if shellcheck isn't installed; the `bash -n` check is the gate.)

- [x] **Step 4: Smoke-test the script in a sandbox**

Run, copy-paste the whole block:

```bash
tmp=$(mktemp -d)
mkdir -p "$tmp/work_root/myrepo/myrepo/.git/refs" \
         "$tmp/work_root/myrepo/myrepo/node_modules" \
         "$tmp/work_root/_actions/some-action" \
         "$tmp/work_root/_temp/junk" \
         "$tmp/work_root/_tool/node" \
         "$tmp/work_root/_PipelineMapping/x"
echo > "$tmp/work_root/myrepo/myrepo/package.json"
echo "fake-corrupted-index" > "$tmp/work_root/myrepo/myrepo/.git/index"

sed 's|/opt/actions-runner/_work|'"$tmp"'/work_root|g' images/hooks/job-started.sh \
  | bash -

# Three assertions:
echo "--- top-level _work entries (helper dirs + outer myrepo/ all survive) ---"
ls "$tmp/work_root"
echo "--- inner workdir directory entry (CRITICAL — must still exist) ---"
[[ -d "$tmp/work_root/myrepo/myrepo" ]] && echo "PASS: cwd remains valid for Process.Start" || echo "FAIL"
echo "--- inner workdir contents (must be empty — corruption gone) ---"
ls -A "$tmp/work_root/myrepo/myrepo" || true
echo "--- helper dir contents (must survive) ---"
ls "$tmp/work_root/_actions" "$tmp/work_root/_temp" "$tmp/work_root/_tool" "$tmp/work_root/_PipelineMapping"
rm -rf "$tmp"
```

Expected output:
```
[job-started-hook] emptied 1 workdir(s) under <tmp>/work_root
--- top-level _work entries (helper dirs + outer myrepo/ all survive) ---
_PipelineMapping
_actions
_temp
_tool
myrepo
--- inner workdir directory entry (CRITICAL — must still exist) ---
PASS: cwd remains valid for Process.Start
--- inner workdir contents (must be empty — corruption gone) ---
--- helper dir contents (must survive) ---
some-action
junk
node
x
```

The "PASS: cwd remains valid" line is the bug-catcher for the regression observed on 2026-05-25 — the original v1 hook removed the inner workdir entirely, causing every job's `actions/checkout` step to fail with `Process.Start ... No such file or directory`.

- [x] **Step 5: Commit**

```bash
git add images/hooks/job-started.sh
git commit -m "feat(ami): add job-started hook to wipe runner _work between jobs"
```

---

## Task 2: Wire the hook into the arm64 Packer template

**Files:**
- Modify: `images/ubuntu-noble-arm64/github_agent.ubuntu.pkr.hcl`

- [x] **Step 1: Read the current template to locate the insertion point**

Open `images/ubuntu-noble-arm64/github_agent.ubuntu.pkr.hcl`. The relevant section is the `build { ... }` block. The change has two parts: add a new `provisioner "file"` for the hook, and extend the existing post-runner-install `provisioner "shell"` (the one that already writes `ImageOS=ubuntu24` to `.env`) to install the hook and append the env var.

The existing post-runner-install shell block looks like this (around line 197):

```hcl
  provisioner "shell" {
    environment_vars = [
      "RUNNER_TARBALL_URL=https://github.com/actions/runner/releases/download/v${local.runner_version}/actions-runner-linux-arm64-${local.runner_version}.tar.gz"
    ]
    inline = [
      "sudo chmod +x /tmp/install-runner.sh",
      "echo ubuntu | tee -a /tmp/install-user.txt",
      "sudo RUNNER_ARCHITECTURE=arm64 RUNNER_TARBALL_URL=$RUNNER_TARBALL_URL /tmp/install-runner.sh",
      "echo ImageOS=ubuntu24 | tee -a /opt/actions-runner/.env"
    ]
  }
```

- [x] **Step 2: Add a file provisioner for the hook**

Insert this new `provisioner "file"` block immediately AFTER the post-runner-install `provisioner "shell"` block from Step 1 (i.e. between that block and the `provisioner "file"` that uploads `start-runner.sh`):

```hcl
  provisioner "file" {
    source      = "../hooks/job-started.sh"
    destination = "/tmp/job-started.sh"
  }
```

The path `../hooks/job-started.sh` resolves relative to Packer's working directory. `scripts/02-build-ami.sh` runs `cd "$IMAGE_DIR"` before `packer build .`, so the cwd is `images/ubuntu-noble-arm64/` and `../hooks/...` resolves to `images/hooks/...` — same convention as the existing `../install-runner.sh` and `../start-runner.sh` references.

- [x] **Step 3: Add a shell provisioner that installs the hook**

Insert this new `provisioner "shell"` block immediately AFTER the file provisioner from Step 2:

```hcl
  provisioner "shell" {
    inline = [
      "sudo mkdir -p /opt/actions-runner/hooks",
      "sudo mv /tmp/job-started.sh /opt/actions-runner/hooks/job-started.sh",
      "sudo chown ubuntu:ubuntu /opt/actions-runner/hooks/job-started.sh",
      "sudo chmod 0755 /opt/actions-runner/hooks/job-started.sh",
      "echo ACTIONS_RUNNER_HOOK_JOB_STARTED=/opt/actions-runner/hooks/job-started.sh | sudo tee -a /opt/actions-runner/.env",
    ]
  }
```

The placement matters: it must come AFTER the runner is installed (the runner-install shell block creates `/opt/actions-runner/`) and AFTER the `ImageOS=ubuntu24` line is appended to `.env` (so the two `.env` lines stack in a stable order).

- [x] **Step 4: Validate the template syntax**

Run from the repo root:

```bash
cd images/ubuntu-noble-arm64
packer init .
packer validate -var-file=shared.pkrvars.hcl -var "runner_version=2.320.0" .
cd ../..
```

(The `runner_version` value is just for validation; any non-empty version string works.)

Expected: `The configuration is valid.`

If `packer` is not available locally, skip this step — CI / next AMI build will catch any HCL errors. Note in the commit message that local validation was skipped.

- [x] **Step 5: Commit**

```bash
git add images/ubuntu-noble-arm64/github_agent.ubuntu.pkr.hcl
git commit -m "feat(ami): wire job-started hook into arm64 Packer template"
```

---

## Task 3: Wire the hook into the amd64 Packer template

**Files:**
- Modify: `images/ubuntu-noble/github_agent.ubuntu.pkr.hcl`

This task mirrors Task 2 against the amd64 template. The structure is identical; only the architecture string in the runner tarball URL differs.

- [x] **Step 1: Add a file provisioner for the hook**

Open `images/ubuntu-noble/github_agent.ubuntu.pkr.hcl`. The post-runner-install `provisioner "shell"` block is at the same logical position as in the arm64 template; its `RUNNER_TARBALL_URL` ends in `actions-runner-linux-x64-${local.runner_version}.tar.gz` instead of `-arm64-`.

Insert this new `provisioner "file"` block immediately AFTER that post-runner-install `provisioner "shell"`:

```hcl
  provisioner "file" {
    source      = "../hooks/job-started.sh"
    destination = "/tmp/job-started.sh"
  }
```

- [x] **Step 2: Add a shell provisioner that installs the hook**

Insert this new `provisioner "shell"` block immediately AFTER the file provisioner from Step 1:

```hcl
  provisioner "shell" {
    inline = [
      "sudo mkdir -p /opt/actions-runner/hooks",
      "sudo mv /tmp/job-started.sh /opt/actions-runner/hooks/job-started.sh",
      "sudo chown ubuntu:ubuntu /opt/actions-runner/hooks/job-started.sh",
      "sudo chmod 0755 /opt/actions-runner/hooks/job-started.sh",
      "echo ACTIONS_RUNNER_HOOK_JOB_STARTED=/opt/actions-runner/hooks/job-started.sh | sudo tee -a /opt/actions-runner/.env",
    ]
  }
```

- [x] **Step 3: Validate the template syntax**

Run from the repo root:

```bash
cd images/ubuntu-noble
packer init .
packer validate -var-file=shared.pkrvars.hcl -var "runner_version=2.320.0" .
cd ../..
```

Expected: `The configuration is valid.`

(Same caveat as Task 2 Step 4: skip if Packer isn't available locally.)

- [x] **Step 4: Diff the two templates to confirm parity**

Run: `diff <(grep -A 10 'job-started' images/ubuntu-noble-arm64/github_agent.ubuntu.pkr.hcl) <(grep -A 10 'job-started' images/ubuntu-noble/github_agent.ubuntu.pkr.hcl)`
Expected: no output (the hook-related lines are identical across both templates).

- [x] **Step 5: Commit**

```bash
git add images/ubuntu-noble/github_agent.ubuntu.pkr.hcl
git commit -m "feat(ami): wire job-started hook into amd64 Packer template"
```

---

## Task 4: Document the hook in CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [x] **Step 1: Add a "Workspace hygiene hook" subsection**

Find the `## AMI Build` section in `CLAUDE.md`. The section currently ends with the `### Rolling out a new AMI` subsection. Add a new subsection AFTER the `### Rolling out a new AMI` subsection (and BEFORE the `## Other Notes` section that follows it).

Insert this content:

```markdown
### Workspace hygiene hook

Both AMIs ship a job-started hook at `/opt/actions-runner/hooks/job-started.sh` (source: `images/hooks/job-started.sh`). It's wired in via `ACTIONS_RUNNER_HOOK_JOB_STARTED` in `/opt/actions-runner/.env`, so the runner agent runs it before every job.

What it does: wipes per-repo subdirs under `/opt/actions-runner/_work` (preserves `_actions`, `_temp`, `_tool`, `_PipelineMapping` to keep action download cache hits). This forces `actions/checkout@v4` to take its full-clone path on every job.

Why: when a workflow with `concurrency.cancel-in-progress: true` SIGTERMs an in-flight `actions/checkout` step, the leftover `_work/<repo>/<repo>/` can be in a state where `.git/index` is "consistent" with an empty working tree. The next job on the same persistent runner sees a workdir that `git clean -ffdx && git reset --hard HEAD && git checkout --force -B <branch>` all treat as already-clean — checkout returns success but the workdir stays empty. The first step that actually reads files (typically `npm ci`) fails with `ENOENT`. Short jobs that don't read the workdir succeed silently against an empty checkout, which is more dangerous than the loud failure.

**No opt-out by design.** A future operator who finds the hook "slowing things down" because every job re-clones should not strip it without re-reading `docs/superpowers/specs/2026-05-25-job-started-hook-design.md`. The most likely "I want to opt out for caching" case is exactly the case where the bug bites (long-lived persistent runner serving multiple jobs).
```

- [x] **Step 2: Verify the section renders cleanly**

Run: `grep -n "Workspace hygiene hook" CLAUDE.md`
Expected: one match, in the `## AMI Build` section (between `### Rolling out a new AMI` content and `## Other Notes`).

Run: `grep -nE 'cancel-in-progress|hooks/job-started\.sh' CLAUDE.md`
Expected: at least the new subsection's references; the file should still parse as valid markdown (no broken section headings).

- [x] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(ami): document the job-started workspace hygiene hook"
```

---

## Task 5: End-to-end validation against a real runner

This task only runs after Tasks 1–4 are merged to the deployment branch. It is the real test of the hook — the script-level smoke test in Task 1 covers the wipe logic, but only a real AMI build + rollout proves the runner agent actually invokes the hook.

**Files:** None modified. This task produces evidence (CloudWatch log lines, GitHub Actions run results) but no commits.

- [ ] **Step 1: Build both AMIs**

```bash
cd deployments/shared-runners
ARCH=arm64 ./scripts/02-build-ami.sh
ARCH=amd64 ./scripts/02-build-ami.sh
```

Expected: each build prints `AMI built successfully!` and a non-empty AMI ID from `manifest.json`. Note both AMI IDs.

- [ ] **Step 2: Roll out via Terraform**

Follow the documented rollout procedure in CLAUDE.md `### Rolling out a new AMI`. Recap:

```bash
# Terraform variables block — pull the GitHub App key from state, then plan.
# (The full extraction snippet lives in CLAUDE.md "Passing Terraform Variables".)
terraform plan ... -out=tfplan
```

Expected plan output: `Plan: 0 to add, 2 to change, 0 to destroy.` — one SSM parameter per fleet, with changes only to `value` and the `ghr:ami_name` / `ghr:ami_creation_date` tags. **Stop and investigate if the plan shows anything else** (LT / SQS / Lambda / IAM should all be untouched).

```bash
terraform apply tfplan && rm tfplan
```

- [ ] **Step 3: Verify SSM parameters point at the new AMIs**

```bash
aws ssm get-parameters --names \
  /github-action-runners/gh-runner/linux-arm64/runners/config/ami_id \
  /github-action-runners/gh-runner/linux-amd64/runners/config/ami_id
```

Expected: both `Value` fields match the AMI IDs noted in Step 1.

- [ ] **Step 4: Recycle one idle runner per fleet onto the new AMI**

For each fleet (arm64, amd64), find an idle runner and terminate it. **Do not terminate `busy=true` runners** — that kills the in-flight job. The dispatcher pattern for checking `busy` per runner via the GitHub App JWT is referenced in CLAUDE.md `### Rolling out a new AMI`.

After termination, the next scale-up event will launch a replacement on the new AMI.

- [ ] **Step 5: Reproduce the regression scenario on a test repo**

Pick a consumer repo whose workflow uses `concurrency.cancel-in-progress: true` and routes to the shared pool (arm64 first; repeat on an amd64-routed repo if one exists). Push three commits in rapid succession (no waiting between pushes):

```bash
git commit --allow-empty -m "ping 1" && git push
git commit --allow-empty -m "ping 2" && git push
git commit --allow-empty -m "ping 3" && git push
```

Expected: all three pushes' jobs succeed (previously the second/third pushes saw `ENOENT: package.json` failures on jobs that landed on a runner that had just had a job cancel-in-progress'd).

- [ ] **Step 6: Confirm the hook fired**

Query the runner's CloudWatch log group (the runner instance's user-data + runner agent logs flow into a stream named after the instance). Look for the marker line:

```bash
# Replace <log-group> with the runner log group; the exact name is in the
# runners module's cloudwatch_log_group resource.
aws logs filter-log-events \
  --log-group-name <log-group> \
  --filter-pattern '"[job-started-hook]"' \
  --start-time $(date -d '1 hour ago' +%s)000 \
  | jq -r '.events[] | "\(.timestamp) \(.message)"' | head
```

Expected: at least one `[job-started-hook] wiped repo subdirs under /opt/actions-runner/_work` event per job that ran after the rollout.

- [ ] **Step 7: Confirm no measurable slowdown for the single-push case**

On the same test repo, do a single push (no rapid-fire follow-up). Confirm the job's `actions/checkout` step takes about the same wall-clock time as it did pre-rollout (the re-clone of a small/medium repo should be sub-second; a meaningful regression here would be seconds, not milliseconds).

If validation passes, the rollout is done. Already-running spot instances will pick up the new AMI as scale-down recycles them after `minimum_running_time_in_minutes` (15 min idle).

---

## Self-Review Notes

**Spec coverage:**
- Hook script content (spec "Hook script") → Task 1.
- Packer wiring on both AMIs (spec "Packer wiring") → Tasks 2, 3.
- CLAUDE.md docs subsection (spec "Documentation") → Task 4.
- Testing procedure (spec "Testing") → Task 5.
- All four spec trade-offs / non-goals are either embedded in the hook's comment or the CLAUDE.md text.

**Type / signature consistency:** The hook path `/opt/actions-runner/hooks/job-started.sh` and the env var name `ACTIONS_RUNNER_HOOK_JOB_STARTED` appear identically in Tasks 1–4 and in CLAUDE.md. The skip-list (`_actions|_temp|_tool|_PipelineMapping`) appears identically in the hook script and in the CLAUDE.md description.

**Placeholder scan:** No TBDs / TODOs. Every step has either complete code or an exact command and expected output.
