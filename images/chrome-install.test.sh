#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATOR="$SCRIPT_DIR/../deployments/shared-runners/scripts/validate-ami-instance.sh"

commands_json() {
  local image_dir="$1"
  (
    cd "$image_dir"
    printf '%s\n' 'jsonencode(var.custom_shell_commands)' \
      | packer console -var-file=shared.pkrvars.hcl github_agent.ubuntu.pkr.hcl
  )
}

assert_any_contains() {
  local commands="$1"
  local expected="$2"
  local description="$3"

  if ! jq -e --arg expected "$expected" 'any(.[]; contains($expected))' <<<"$commands" >/dev/null; then
    echo "FAIL: $description" >&2
    return 1
  fi
}

assert_exact() {
  local commands="$1"
  local expected="$2"
  local description="$3"

  if ! jq -e --arg expected "$expected" 'index($expected) != null' <<<"$commands" >/dev/null; then
    echo "FAIL: $description" >&2
    return 1
  fi
}

amd64_commands="$(commands_json "$SCRIPT_DIR/ubuntu-resolute")"
arm64_commands="$(commands_json "$SCRIPT_DIR/ubuntu-resolute-arm64")"

assert_any_contains "$amd64_commands" \
  "https://dl.google.com/linux/linux_signing_key.pub" \
  "amd64 downloads Google's Linux package signing key"
assert_any_contains "$amd64_commands" \
  "EB4C1BFD4F042F6DDDCCEC917721F63BD38B4796" \
  "amd64 pins Google's published primary signing-key fingerprint"
assert_any_contains "$amd64_commands" \
  "arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg" \
  "amd64 restricts the signed Chrome repository to amd64"

apt_update="sudo timeout --signal=TERM --kill-after=30s 600s apt-get -o DPkg::Lock::Timeout=60 -o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 update"
chrome_install="sudo timeout --signal=TERM --kill-after=30s 600s env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=60 -o Acquire::Retries=3 -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 install -y --no-install-recommends google-chrome-stable"
chrome_cleanup="sudo rm -f /etc/apt/sources.list.d/google-chrome.list /etc/apt/sources.list.d/google-chrome.sources /usr/share/keyrings/google-chrome.gpg"
chrome_version="google-chrome --version"
chrome_smoke="timeout --signal=TERM --kill-after=5s 30s google-chrome --headless --disable-gpu --dump-dom about:blank > /dev/null"

assert_exact "$amd64_commands" "$apt_update" \
  "amd64 bounds the apt repository update"
assert_exact "$amd64_commands" "$chrome_install" \
  "amd64 installs the latest stable package with bounded waits"
assert_exact "$amd64_commands" "$chrome_cleanup" \
  "amd64 removes both Chrome repository formats and the keyring"
assert_exact "$amd64_commands" "$chrome_version" \
  "amd64 verifies the installed Chrome executable"
assert_exact "$amd64_commands" "$chrome_smoke" \
  "amd64 launches Chrome headlessly without sudo"

if ! jq -e \
  --arg update "$apt_update" \
  --arg install "$chrome_install" \
  --arg cleanup "$chrome_cleanup" \
  --arg version "$chrome_version" \
  --arg smoke "$chrome_smoke" \
  'index($update) < index($install)
    and index($install) < index($cleanup)
    and index($cleanup) < index($version)
    and index($version) < index($smoke)' \
  <<<"$amd64_commands" >/dev/null; then
  echo "FAIL: amd64 must update apt, install Chrome, remove its repository, then run unprivileged verification" >&2
  exit 1
fi

if jq -e 'any(.[]; contains("google-chrome-stable_current_amd64.deb"))' <<<"$amd64_commands" >/dev/null; then
  echo "FAIL: amd64 must install Chrome from the signed apt repository" >&2
  exit 1
fi

if jq -e 'any(.[]; contains("google-chrome"))' <<<"$arm64_commands" >/dev/null; then
  echo "FAIL: arm64 must not install the amd64-only Google Chrome package" >&2
  exit 1
fi

validator_chrome_command="$(
  sed -n \
    '/^  sudo -u ubuntu -H timeout --signal=TERM --kill-after=5s 30s \\$/,+1p' \
    "$VALIDATOR"
)"
expected_validator_chrome_command=$'  sudo -u ubuntu -H timeout --signal=TERM --kill-after=5s 30s \\\n    google-chrome --headless --disable-gpu --dump-dom about:blank >/dev/null ||'
if [[ "$validator_chrome_command" != "$expected_validator_chrome_command" ]]; then
  echo "FAIL: amd64 validator must launch Chrome as the runner user with its sandbox" >&2
  exit 1
fi
if grep -q -- '--no-sandbox' <<<"$validator_chrome_command"; then
  echo "FAIL: amd64 validator must exercise the Chrome sandbox used by runner jobs" >&2
  exit 1
fi

echo "PASS: Google Chrome AMI provisioning assertions"
