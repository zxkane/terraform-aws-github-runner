# Plan: Migrate shared runner AMIs from Ubuntu 24.04 (Noble) to 26.04 LTS (Resolute)

**Status:** SHIPPED 2026-06-18 — both AMIs built, merged, and rolled to production
(SSM AMI-id params now point at Resolute; LTs resolve via `resolve:ssm:`).

## Context

A consumer repo reported a CI failure where `apt-get install <chrome>.deb` 404'd
fetching the dependency `libegl-mesa0_25.2.8-0ubuntu0.24.04.1_amd64.deb`. The
`24.04.1` in the version string confirms the host was already on Noble. The root
cause is a **stale apt index** (the workflow didn't `apt-get update` before
installing, so apt resolved the dependency to a cached version Ubuntu's archive
had already rotated out) — **not** the OS version.

That bug is fixed independently of this migration:
- **AMI side:** both Packer builds end with `apt-get clean && rm -rf
  /var/lib/apt/lists/*`, so the AMI never ships a stale index. (Committed first,
  on the noble images, so it stands alone from the OS migration.)
- **Consumer side (their repo):** run `sudo apt-get update` before any
  `apt-get install`, or pass `--fix-missing`.

This migration is a **separate modernization** (newer kernel/glibc, longer
support window on a fresh LTS) the user opted into.

## Pre-flight facts (verified 2026-06-18, us-east-1)

26.04 LTS "Resolute Raccoon" is GA. Canonical's pro-server AMIs exist for both
architectures owned by `099720109477`:

| Arch  | Base AMI name pattern | Verified image (newest) |
|-------|-----------------------|-------------------------|
| amd64 | `ubuntu-pro-server/images/hvm-ssd-gp3/ubuntu-resolute-26.04-amd64-pro-server-*` | `ubuntu-resolute-26.04-amd64-pro-server-20260503` |
| arm64 | `ubuntu-pro-server/images/hvm-ssd-gp3/ubuntu-resolute-26.04-arm64-pro-server-*` | `ubuntu-resolute-26.04-arm64-pro-server-20260503` |

The only base-AMI change vs. the old filter is the codename+version token:
`ubuntu-noble-24.04-{arch}` → `ubuntu-resolute-26.04-{arch}`.

## Consumer compatibility — no-break analysis (verified, then confirmed at apply)

Goal: ship 26.04 without breaking any existing consumer repo's CI.

- **`runs-on` labels are NOT coupled to the OS version.** Both fleets advertise
  exactly `[self-hosted, linux, arm64]` / `[self-hosted, linux, x64]` — no
  `ubuntu-2404` / `noble` / OS token. Labels derive purely from
  `runner_extra_labels` + `labelMatchers` (`modules/multi-runner` builds
  `sort(distinct(["self-hosted", runner_os, runner_architecture] + extra))`),
  never from the AMI name or `OS_Version` tag. `terraform apply` outputs
  re-confirmed `runners_label_*` unchanged. The CLAUDE.md `RUNNER_LABEL` array
  consumers select on has no OS token either → unaffected.
- **`ImageOS=ubuntu24`→`ubuntu26` is an outward hint only.** Nothing in this repo
  reads `ImageOS`; it exists for GitHub's `actions/*` cache-keying. Safe to change.

Residual risks were all **build-time / toolchain** — they fail loudly in staging
before any runner reaches a consumer. All cleared during the build (below).

## What shipped (changes)

### Commit 1 — apt index hardening (stands alone, the 404 fix)
`apt-get clean && rm -rf /var/lib/apt/lists/*` appended to both Packer builds.

### Commit 2 — the 26.04 migration
- Image dirs renamed `ubuntu-noble{,-arm64}` → `ubuntu-resolute{,-arm64}`.
- Both Packer files: base AMI filter, `ami_name` prefix, `OS_Version` tag,
  `ImageOS=ubuntu26`, **and** a cloud-init degraded-exit tolerance (below).
- `main.tf` AMI filters (`github-runner-ubuntu-resolute-{arch}-*`).
- `02-build-ami.sh` IMAGE_DIR map + echo.
- Docs: README / CLAUDE.md / RUNBOOK.md.
- `shared.pkrvars.hcl` needed NO change — all tool installs (nodesource, bun,
  gh apt repo, playwright install-deps) are codename-agnostic.

#### cloud-init degraded-exit fix (discovered during the build)
The first Packer provisioner started with `sudo cloud-init status --wait`, which
**exits 2 when cloud-init finishes in a degraded (recoverable) state** — common
on a fresh 26.04 first boot. Under Packer's per-line exit-0 requirement that
aborted the whole build (`Script exited with non-zero exit status: 2`), seen on
1 of 3 build attempts. Changed to `sudo cloud-init status --wait || [ $? -eq 2 ]`
— accept exit 2 (finished, degraded; box is ready), still fail on exit 1 (crash).

## Build + smoke-test results (both arches, on Resolute)

- Docker CE `5:29.5.3-1~ubuntu.26.04~resolute` installed clean (the #1 build risk,
  now confirmed present and working).
- Node.js v24.16.0, Bun, **Playwright `install-deps chromium` + Chromium download**
  (the #2 risk — system-lib package names did NOT break on Resolute), gh 2.95.0,
  AWS CLI v2 — all `=== Verification Complete ===`.
- AMIs: amd64 `ami-0fe3f141f015239c4`, arm64 `ami-04272e427faf3398b`, both
  `available` and matching the Terraform filters.

## Roll (executed)

1. Both AMIs built first (Terraform untouched).
2. `terraform plan` → **`0 to add, 2 to change, 0 to destroy`** (the two SSM AMI-id
   params), nothing else. `terraform apply` succeeded.
3. SSM params verified pointing at the Resolute AMIs; LTs resolve `ImageId` via
   `resolve:ssm:`. Fleet was at zero runners at roll time → no old 24.04 instances
   to recycle; next scale-up launches 26.04.

## Rollback

Reversible: revert the `main.tf` filter to `…ubuntu-noble-…`, `apply` (back to
`0 add / 2 change / 0 destroy`), and new runners launch on the last-good 24.04
AMI. The 24.04 AMIs are not deleted by this process.

## Out of scope

- Fleet sizing, instance types, spot strategy, webhook/Lambda stack — none depend
  on the OS version.
- The consumer-side `apt-get update` fix (their repo).
