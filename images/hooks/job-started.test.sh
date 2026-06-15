#!/usr/bin/env bash
# Test harness for job-started.sh.
#
# The hook hard-codes work_root=/opt/actions-runner/_work, so we can't point it
# at a temp dir directly. Instead we copy the hook into a temp sandbox and patch
# only the work_root line + the path guard to the sandbox, leaving every other
# line of logic byte-identical to the shipped hook. This tests the REAL logic.
#
# Run: bash images/hooks/job-started.test.sh
set -uo pipefail

HOOK_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/job-started.sh"
pass=0
fail=0

ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=$((fail+1)); }

# Build a sandboxed copy of the hook whose work_root is $1.
make_hook() {
  local sandbox_work="$1" hookfile="$2"
  sed -E \
    -e "s#^work_root=.*#work_root=\"${sandbox_work}\"#" \
    -e "s#^\[\[ \"\\\$work_root\" == .* \]\] \|\| exit 0#[[ \"\$work_root\" == \"${sandbox_work}\" ]] || exit 0#" \
    "$HOOK_SRC" > "$hookfile"
}

# ---------------------------------------------------------------------------
# Test 1 (the production bug): a stale runner self-update dir _work/_update with
# an undeletable entry must NOT fail the hook. Repro of the verbatim error.
# ---------------------------------------------------------------------------
test_update_residue_nonfatal() {
  local root; root="$(mktemp -d)"
  local work="$root/_work"
  mkdir -p "$work/_update/externals/node20/include/node/openssl/archs"
  echo 'hdr' > "$work/_update/externals/node20/include/node/openssl/archs/opensslconf.h"
  # Make the openssl dir non-writable so its children can't be unlinked —
  # this is exactly what makes `find -delete` emit "Directory not empty".
  chmod a-w "$work/_update/externals/node20/include/node/openssl"

  local hook="$root/hook.sh"; make_hook "$work" "$hook"
  bash "$hook" >/dev/null 2>&1
  local rc=$?

  # cleanup (restore perms so mktemp dir is removable)
  chmod -R u+w "$work" 2>/dev/null
  rm -rf "$root"

  if [[ $rc -eq 0 ]]; then
    ok "stale _work/_update with undeletable entry -> hook exits 0 (job not failed)"
  else
    bad "stale _work/_update with undeletable entry -> hook exited $rc (would FAIL the job)"
  fi
}

# ---------------------------------------------------------------------------
# Test 2 (no regression): a real repo workdir must still be EMPTIED, while the
# directory entry itself is preserved (cwd must stay valid).
# ---------------------------------------------------------------------------
test_repo_workdir_emptied() {
  local root; root="$(mktemp -d)"
  local work="$root/_work"
  local inner="$work/podcast-curation/podcast-curation"
  mkdir -p "$inner/.git"
  echo 'corrupt-index' > "$inner/.git/index"
  echo 'stale' > "$inner/package.json"

  local hook="$root/hook.sh"; make_hook "$work" "$hook"
  bash "$hook" >/dev/null 2>&1
  local rc=$?

  local dir_exists=0 dir_empty=0
  [[ -d "$inner" ]] && dir_exists=1
  [[ -z "$(ls -A "$inner" 2>/dev/null)" ]] && dir_empty=1
  rm -rf "$root"

  if [[ $rc -eq 0 && $dir_exists -eq 1 && $dir_empty -eq 1 ]]; then
    ok "real repo workdir emptied, dir entry preserved, hook exits 0"
  else
    bad "repo workdir: rc=$rc exists=$dir_exists empty=$dir_empty (want rc=0 exists=1 empty=1)"
  fi
}

# ---------------------------------------------------------------------------
# Test 3 (defense-in-depth): an undeletable entry inside a LEGITIMATE repo
# workdir (e.g. a root-owned file left by a Docker job) must also not fail the
# hook — housekeeping failure is never fatal to the job.
# ---------------------------------------------------------------------------
test_undeletable_in_repo_workdir_nonfatal() {
  local root; root="$(mktemp -d)"
  local work="$root/_work"
  local inner="$work/somerepo/somerepo/build/locked"
  mkdir -p "$inner"
  echo 'x' > "$inner/artifact"
  chmod a-w "$work/somerepo/somerepo/build/locked"

  local hook="$root/hook.sh"; make_hook "$work" "$hook"
  bash "$hook" >/dev/null 2>&1
  local rc=$?

  chmod -R u+w "$work" 2>/dev/null
  rm -rf "$root"

  if [[ $rc -eq 0 ]]; then
    ok "undeletable entry inside real repo workdir -> hook exits 0"
  else
    bad "undeletable entry inside real repo workdir -> hook exited $rc (would FAIL the job)"
  fi
}

# ---------------------------------------------------------------------------
# Test 4 (no regression): cache dirs _actions/_tool and other runner-internal
# dirs are left untouched.
# ---------------------------------------------------------------------------
test_cache_dirs_preserved() {
  local root; root="$(mktemp -d)"
  local work="$root/_work"
  mkdir -p "$work/_actions/owner/repo/v4" "$work/_tool/node/20" "$work/_diag"
  echo 'cached' > "$work/_actions/owner/repo/v4/action.yml"
  echo 'tool'   > "$work/_tool/node/20/bin"

  local hook="$root/hook.sh"; make_hook "$work" "$hook"
  bash "$hook" >/dev/null 2>&1
  local rc=$?

  local a=0 t=0
  [[ -f "$work/_actions/owner/repo/v4/action.yml" ]] && a=1
  [[ -f "$work/_tool/node/20/bin" ]] && t=1
  rm -rf "$root"

  if [[ $rc -eq 0 && $a -eq 1 && $t -eq 1 ]]; then
    ok "_actions and _tool caches preserved, hook exits 0"
  else
    bad "cache dirs: rc=$rc _actions=$a _tool=$t (want all 1)"
  fi
}

echo "Testing $HOOK_SRC"
test_update_residue_nonfatal
test_repo_workdir_emptied
test_undeletable_in_repo_workdir_nonfatal
test_cache_dirs_preserved
echo "----"
echo "passed=$pass failed=$fail"
[[ $fail -eq 0 ]]
